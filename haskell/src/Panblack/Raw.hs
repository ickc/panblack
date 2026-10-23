-- | How raw content is spelled when a source is written back (see
-- docs/guide/markdown.md, "Raw content").
--
-- pandoc markdown has two syntaxes for raw content: native (inline HTML,
-- TeX) and the raw attribute (@`...`{=format}@, @```{=format}@ blocks).
-- The reader understands both, but the AST doesn't record which was used,
-- and pandoc's writer picks one per kind of element. Wrapping a profile's
-- writer with 'rawWriting' lets panblack pick per element instead: an
-- element to be written in the attribute form becomes a raw @markdown@
-- element holding that syntax, which the writer copies out verbatim.
module Panblack.Raw
  ( RawSyntax (..)
  , rawSyntaxName
  , rawSyntaxByName
  , rawWriting
  ) where

import Control.Monad.State.Strict (evalState, state)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Panblack.Guard (Profile (..))
import Text.Pandoc.Class (runPure)
import Text.Pandoc.Definition
import Text.Pandoc.Error (PandocError)
import Text.Pandoc.Extensions (Extension (..), extensionEnabled)
import Text.Pandoc.Format (FlavoredFormat (..), applyExtensionsDiff, getExtensionsConfig, parseFlavoredFormat)
import Text.Pandoc.Walk (query, walkM)

data RawSyntax
  = -- | HTML and TeX as the writer writes them natively; other formats, and
    -- TeX whose environments don't balance (and, for CommonMark, HTML blocks
    -- holding a blank line), in the attribute form.
    RawNative
  | -- | Every raw element in the attribute form.
    RawAttribute
  | -- | As 'RawNative', then read the result back, and write each element
    -- that didn't read back the same in the attribute form instead.
    RawAuto
  | -- | As pandoc's writer chooses, from the @to@ extensions alone: 0.x's
    -- behaviour.
    RawPandoc
  deriving stock (Eq, Ord, Show, Enum, Bounded)

rawSyntaxName :: RawSyntax -> Text
rawSyntaxName = \case
  RawNative -> "native"
  RawAttribute -> "attribute"
  RawAuto -> "auto"
  RawPandoc -> "pandoc"

rawSyntaxByName :: Text -> Maybe RawSyntax
rawSyntaxByName name = lookup name [(rawSyntaxName r, r) | r <- [minBound .. maxBound]]

-- | 'RawAuto' fixes at most this many elements one at a time, each costing
-- a write and a read of the whole file, then falls back to the attribute
-- form for every raw block, then for everything.
autoLimit :: Int
autoLimit = 8

-- | Spell raw content when the profile writes, given its reading and writing
-- format specs (as for 'Panblack.Markdown.markdownProfile'). Apply it after
-- 'Panblack.Normalize.normalizing', so that 'RawAuto' reads back as the
-- guard does. Without @raw_attribute@ in the reader there is no attribute
-- form to choose, and the profile is unchanged.
rawWriting :: RawSyntax -> Text -> Text -> Profile -> Either PandocError Profile
rawWriting syntax from to profile = runPure $ do
  fromF <- parseFlavoredFormat from
  toF <- parseFlavoredFormat to
  let name = formatName fromF
  readExts <- applyExtensionsDiff (getExtensionsConfig name) fromF
  writeExts <- applyExtensionsDiff (getExtensionsConfig name) toF
  let commonmark = name `elem` ["commonmark", "commonmark_x", "gfm"]
      on e = extensionEnabled e writeExts
      native f
        | isHtml f = on Ext_raw_html
        | isTex f = not commonmark && on Ext_raw_tex
        | otherwise = False
      -- Elements written in the attribute form whatever the policy: those
      -- the writer can't write natively, or that would read back as more
      -- or less than themselves; and @latex@ ones, which can only have been
      -- typed that way (native TeX reads as @tex@).
      mustAttribute = \case
        Left (RawBlock f t) -> keep f t || (commonmark && isHtml f && "\n\n" `T.isInfixOf` T.strip t)
        Right (RawInline f t) -> keep f t
        _ -> False
      keep f t = not (native f) || f == Format "latex" || unbalancedTex f t
      write = profileWrite profile
      spell pick = write . attributeWhere pick
      auto doc
        | null originals = write doc
        | otherwise = go Set.empty
       where
        originals = raws doc
        go ks = do
          out <- spell (\k e -> mustAttribute e || k `Set.member` ks) doc
          back <- raws <$> profileRead profile out
          let firstDiff = [k | (k, a, b) <- zip3 [0 ..] originals (map Just back ++ repeat Nothing), Just a /= b, k `Set.notMember` ks]
          case firstDiff of
            [] -> pure out
            k : _
              | Set.size ks < autoLimit -> go (Set.insert k ks)
              | otherwise -> fallback
        fallback = do
          out <- spell (\_ e -> mustAttribute e || isBlock e) doc
          back <- raws <$> profileRead profile out
          if back == originals then pure out else spell (\_ _ -> True) doc
  pure $
    if syntax == RawPandoc || not (extensionEnabled Ext_raw_attribute readExts)
      then profile
      else profile {profileWrite = case syntax of
        RawNative -> spell (const mustAttribute)
        RawAttribute -> spell (\_ _ -> True)
        RawAuto -> auto
        RawPandoc -> write}
 where
  isBlock = either (const True) (const False)

-- | The raw elements of a document, blocks first, in document order, each
-- with its format name as pandoc's writers treat it (native TeX reads back
-- as @tex@, @{=latex}@ as @latex@).
raws :: Pandoc -> [(Bool, Text, Text)]
raws doc = query block doc <> query inline doc
 where
  block (RawBlock f t) = [(True, alias f, t)]
  block _ = []
  inline (RawInline f t) = [(False, alias f, t)]
  inline _ = []
  alias f
    | isTex f = "tex"
    | isHtml f = "html"
    | otherwise = let Format n = f in n

-- | Write the raw elements chosen by index (as numbered by 'raws') in the
-- attribute form.
attributeWhere :: (Int -> Either Block Inline -> Bool) -> Pandoc -> Pandoc
attributeWhere pick doc = flip evalState 0 . walkM inline $ flip evalState 0 (walkM block doc)
 where
  nBlocks = length [() | RawBlock _ _ <- query (: []) doc]
  block b@(RawBlock f t) = state $ \k -> (if pick k (Left b) then RawBlock "markdown" (fencedBlock f t) else b, k + 1)
  block b = pure b
  inline i@(RawInline f t) = state $ \k -> (if pick (nBlocks + k) (Right i) then RawInline "markdown" (attributeInline f t) else i, k + 1)
  inline i = pure i

attributeInline :: Format -> Text -> Text
attributeInline (Format f) t = fence <> t <> fence <> "{=" <> f <> "}"
 where
  fence = T.replicate (1 + longestRun '`' t) "`"

-- | A fenced raw block, followed by a blank line: the writer puts none after
-- raw blocks, and two fences in a row would read as one.
fencedBlock :: Format -> Text -> Text
fencedBlock (Format f) t = fence <> "{=" <> f <> "}\n" <> T.dropWhileEnd (== '\n') t <> "\n" <> fence <> "\n\n"
 where
  fence = T.replicate (max 3 (1 + longestRun '`' t)) "`"

longestRun :: Char -> Text -> Int
longestRun c = maximum . (0 :) . map T.length . filter (T.any (== c)) . T.group

isHtml, isTex :: Format -> Bool
isHtml f = f `elem` ["html", "html4", "html5"]
isTex f = f `elem` ["latex", "tex"]

-- | Whether some @\\begin{x}@ lacks its @\\end{x}@, or the reverse. Written
-- natively, such a fragment reads back as part of a larger TeX block.
unbalancedTex :: Format -> Text -> Bool
unbalancedTex f t = isTex f && not (go [] (map snd (T.breakOnAll "\\" t)))
 where
  go stack [] = null stack
  go stack (rest : more)
    | Just e <- env "\\begin{" rest = go (e : stack) more
    | Just e <- env "\\end{" rest = case stack of
        top : stack' | top == e -> go stack' more
        _ -> False
    | otherwise = go stack more
  env prefix = fmap (T.takeWhile (/= '}')) . T.stripPrefix prefix
