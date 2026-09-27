-- | Jupyter notebooks, formatted cell by cell (see docs/design.md, "ipynb").
--
-- Only the markdown cells' sources go through the markdown pipeline. They
-- are spliced back into the original bytes, so every other byte of the file
-- is kept: metadata, outputs, cell ids, number formatting and indentation.
-- A cell's new source keeps the shape of the old one (a JSON string, or a
-- list of lines laid out as before).
--
-- The guard runs per cell. A cell it rejects is kept as it was, and the
-- others are still formatted. For a notebook whose cells are also read as
-- one document (the markdown side of a jupytext pair), the guard then runs
-- on all markdown cells joined, which catches what spans cells, such as a
-- reference link whose definition is in another cell.
module Panblack.Notebook
  ( Notebook
  , readNotebook
  , notebookMetadata
  , NotebookOptions (..)
  , NotebookFailure (..)
  , NotebookResult (..)
  , formatNotebook
  ) where

import Control.Monad (guard, when)
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.Char (ord)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Numeric (showHex)
import Panblack.Guard

-- | A JSON value and where it is in the file: from its first byte to just
-- after its last.
data J = J
  { jStart :: !Int
  , jEnd :: !Int
  , jNode :: Node
  }

data Node = Obj [Member] | Arr [J] | Leaf

data Member = Member
  { mKey :: Text
  , mValue :: J
  }

data Notebook = Notebook
  { nbBytes :: ByteString
  , nbValue :: Value
  , nbJson :: J
  }

-- | Parse a notebook. The bytes must be valid JSON with a @cells@ list.
readNotebook :: ByteString -> Either Text Notebook
readNotebook bs = do
  v <- either (Left . ("not valid JSON: " <>) . T.pack) Right (A.eitherDecodeStrict bs)
  j <- maybe (Left "not valid JSON") Right (scan bs)
  case member "cells" j of
    Just J {jNode = Arr _} -> Right (Notebook bs v j)
    _ -> Left "not a notebook: no cells list"

-- | The notebook's top-level @metadata@.
notebookMetadata :: Notebook -> A.Object
notebookMetadata nb = case nbValue nb of
  Object o | Just (Object m) <- KM.lookup "metadata" o -> m
  _ -> KM.empty

data NotebookOptions = NotebookOptions
  { nbWholeNotebookCheck :: Bool
  -- ^ Also check all markdown cells joined into one document.
  }

data NotebookFailure = NotebookFailure
  { failWhere :: Text
  -- ^ @cell N@ (counting all cells from 1), or @all markdown cells@.
  , failGuard :: GuardFailure
  }

data NotebookResult = NotebookResult
  { resultBytes :: ByteString
  -- ^ May be the same as the old.
  , resultAccepted :: Accepted
  , resultKept :: [NotebookFailure]
  -- ^ The cells kept as they were, because the guard rejected them.
  }

-- | Format a notebook's markdown cells with a markdown profile. Fails if
-- pandoc fails on a cell, or if the whole-notebook check fails; then
-- nothing is written.
formatNotebook :: NotebookOptions -> Profile -> Notebook -> Either NotebookFailure NotebookResult
formatNotebook opts profile nb = do
  results <- traverse formatCell cells
  let outs = [either (const (cellSource c)) fst r | (c, r) <- zip cells results]
      changed = [(c, new) | (c, new) <- zip cells outs, new /= cellSource c]
      accepted = case [a | Right (_, a@(ChecksPassed _)) <- results] of
        a : _ -> a
        [] -> AstEqual
  -- With a single cell, the per-cell check already covers the notebook.
  when (nbWholeNotebookCheck opts && length cells > 1 && not (null changed)) $ do
    let joined = T.intercalate "\n\n" . map (T.filter (/= '\r'))
    () <$ failingAt "all markdown cells" (compareSources profile (joined (map cellSource cells)) (joined outs))
  pure
    NotebookResult
      { resultBytes = splice bytes (sourceEdits changed)
      , resultAccepted = accepted
      , resultKept = [f | Left f <- results]
      }
 where
  bytes = nbBytes nb
  cells = markdownCells nb
  failingAt w = either (Left . NotebookFailure w) Right
  -- Right (Left _): rejected, kept as it was.
  formatCell c = do
    let src = cellSource c
        name = "cell " <> T.pack (show (cellNumber c))
    case format profile (T.filter (/= '\r') src) of
      Left e@(PandocFailed _) -> Left (NotebookFailure name e)
      Left e@ChecksFailed {} -> Right (Left (NotebookFailure name e))
      Right f -> do
        -- A cell's source usually has no final newline; keep what it had.
        let out = formattedText f
            out'
              | "\n" `T.isSuffixOf` src = out
              | otherwise = fromMaybe out (T.stripSuffix "\n" out)
        Right (Right (out', formattedBy f))
  asciiOnly = B.all (< 0x80) bytes
  sourceEdits changed = [(jStart j, jEnd j, encodeSource asciiOnly bytes j new) | (c, new) <- changed, let j = cellJson c]

data Cell = Cell
  { cellNumber :: Int
  , cellSource :: Text
  , cellJson :: J
  -- ^ The @source@ value.
  }

markdownCells :: Notebook -> [Cell]
markdownCells nb = case (member "cells" (nbJson nb), nbValue nb) of
  (Just J {jNode = Arr js}, Object o)
    | Just (Array vs) <- KM.lookup "cells" o ->
        [ Cell i src j
        | (i, cj, Object c) <- zip3 [1 ..] js (toList vs)
        , KM.lookup "cell_type" c == Just (String "markdown")
        , Just src <- [KM.lookup "source" c >>= sourceText]
        , Just j <- [member "source" cj]
        ]
  _ -> []
 where
  sourceText = \case
    String t -> Just t
    Array xs -> mconcat <$> traverse (\case String t -> Just t; _ -> Nothing) (toList xs)
    _ -> Nothing

-- | A new source in the shape of the old: a string, or a list of lines laid
-- out as the old list was.
encodeSource :: Bool -> ByteString -> J -> Text -> ByteString
encodeSource asciiOnly bytes j new = case jNode j of
  Arr es ->
    let slice a b = B.take (b - a) (B.drop a bytes)
        (lead, sep, trail) = case es of
          [] -> ("", ",", "")
          [e] -> (slice (jStart j + 1) (jStart e), "," <> slice (jStart j + 1) (jStart e), slice (jEnd e) (jEnd j - 1))
          e1 : e2 : _ -> (slice (jStart j + 1) (jStart e1), slice (jEnd e1) (jStart e2), slice (maximum (map jEnd es)) (jEnd j - 1))
     in case map (jsonString asciiOnly) (linesKeepingEnds new) of
          [] -> "[]"
          ls -> "[" <> lead <> B.intercalate sep ls <> trail <> "]"
  _ -> jsonString asciiOnly new

-- | Split after each newline, as Python's @splitlines(keepends=True)@ does
-- for @\n@.
linesKeepingEnds :: Text -> [Text]
linesKeepingEnds t = case T.breakOn "\n" t of
  ("", "") -> []
  (l, "") -> [l]
  (l, rest) -> (l <> "\n") : linesKeepingEnds (T.drop 1 rest)

-- | A JSON string as Python's @json.dumps@ writes it (as Jupyter does), with
-- @ensure_ascii@ as given.
jsonString :: Bool -> Text -> ByteString
jsonString asciiOnly t = BL.toStrict . BB.toLazyByteString $ BB.char7 '"' <> T.foldr (\c b -> esc c <> b) mempty t <> BB.char7 '"'
 where
  esc = \case
    '"' -> "\\\""
    '\\' -> "\\\\"
    '\n' -> "\\n"
    '\r' -> "\\r"
    '\t' -> "\\t"
    '\b' -> "\\b"
    '\f' -> "\\f"
    c
      | c < ' ' -> u (ord c)
      | asciiOnly && c > '~' ->
          if ord c >= 0x10000
            then let n = ord c - 0x10000 in u (0xD800 + n `div` 0x400) <> u (0xDC00 + n `mod` 0x400)
            else u (ord c)
      | otherwise -> BB.byteString (TE.encodeUtf8 (T.singleton c))
  u n = let h = showHex n "" in BB.string7 ("\\u" <> replicate (4 - length h) '0' <> h)

-- | Replace byte ranges, which must not overlap.
splice :: ByteString -> [(Int, Int, ByteString)] -> ByteString
splice bs edits = BL.toStrict . BB.toLazyByteString $ go 0 (sortOn (\(a, _, _) -> a) edits)
 where
  go i = \case
    [] -> BB.byteString (B.drop i bs)
    (a, b, new) : rest -> BB.byteString (B.take (a - i) (B.drop i bs)) <> BB.byteString new <> go b rest

member :: Text -> J -> Maybe J
member k J {jNode = Obj ms} = case [mValue m | m <- ms, mKey m == k] of
  v : _ -> Just v
  [] -> Nothing
member _ _ = Nothing

-- | Where each value is. The input has already been validated by aeson, so
-- this only has to find the boundaries.
scan :: ByteString -> Maybe J
scan bs = do
  j <- value (ws 0)
  guard (ws (jEnd j) == n)
  pure j
 where
  n = B.length bs
  at i = if i < n then B.index bs i else 0
  ws i
    | i < n, at i `elem` [0x20, 0x09, 0x0A, 0x0D] = ws (i + 1)
    | otherwise = i
  value i = case at i of
    0x7B -> container i 0x7D Obj (jEnd . mValue) memberAt
    0x5B -> container i 0x5D Arr jEnd value
    0x22 -> Just (J i (stringEnd (i + 1)) Leaf)
    _ -> let e = scalarEnd i in if e == i then Nothing else Just (J i e Leaf)
  stringEnd i
    | i >= n = n
    | otherwise = case at i of
        0x5C -> stringEnd (i + 2)
        0x22 -> i + 1
        _ -> stringEnd (i + 1)
  scalarEnd i
    | i < n, at i `notElem` [0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D] = scalarEnd (i + 1)
    | otherwise = i
  memberAt i = do
    guard (at i == 0x22)
    let ke = stringEnd (i + 1)
    key <- A.decodeStrict (B.take (ke - i) (B.drop i bs))
    let colon = ws ke
    guard (at colon == 0x3A)
    v <- value (ws (colon + 1))
    pure (Member key v)
  container :: Int -> Word8 -> ([a] -> Node) -> (a -> Int) -> (Int -> Maybe a) -> Maybe J
  container s close mk endOf item = go (ws (s + 1)) []
   where
    go i acc
      | null acc && at i == close = Just (J s (i + 1) (mk []))
      | otherwise = do
          x <- item i
          let j = ws (endOf x)
          if
            | at j == 0x2C -> go (ws (j + 1)) (x : acc)
            | at j == close -> Just (J s (j + 1) (mk (reverse (x : acc))))
            | otherwise -> Nothing
