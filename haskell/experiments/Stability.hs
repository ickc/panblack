-- | How formatting behaves when repeated, per document.
--
-- For each markdown file in a directory and each column width, iterate the
-- formatter (f0 = source, f(i+1) = write (read fi)) and print one CSV row:
--
-- * html1: html (read f0) == html (read f1), the output check;
-- * round1: f1 == f2, one-round stability (the `source` check);
-- * round2: f2 == f3, two-round stability;
-- * fixed: the first i with fi == f(i+1), up to 'maxRounds';
-- * html_fixed: html (read f0) == html (read f_fixed), so repeated
--   formatting didn't drift from the original's meaning.
--
-- Build as for Tables.hs, then (from the repository root):
--   stability DIR FROM TO WRAP COLUMNS[,COLUMNS...] RESET(yes|no)
--
-- The corpus used in docs/design.md is these tables, the design doc, and
-- pandoc's own markdown test files and MANUAL.txt sections with tables, taken
-- from the pinned pandoc source (cabal get pandoc-3.10.2).
module Main (main) where

import Data.List (isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Panblack.Guard
import Panblack.Markdown (markdownProfile)
import Panblack.Target.Html (htmlCheck)
import System.Directory (listDirectory)
import System.Environment (getArgs)
import Text.Pandoc.Class (PandocPure, runPure)
import Text.Pandoc.Definition
import Text.Pandoc.Options
import Text.Pandoc.Walk (query, walk)

maxRounds :: Int
maxRounds = 8

main :: IO ()
main = do
  [dir, from, to, wrap, cols, reset] <- getArgs
  files <- sort . filter (".md" `isSuffixOf`) <$> listDirectory dir
  putStrLn "file,columns,tables,html1,round1,round2,fixed,html_fixed"
  sequence_
    [ TIO.readFile (dir <> "/" <> file) >>= run file (T.pack from) (T.pack to) (wrapOpt wrap) c (reset == "yes")
    | file <- files
    , c <- map read (splitOn ',' cols)
    ]
 where
  splitOn ch s = case break (== ch) s of
    (a, []) -> [a]
    (a, _ : rest) -> a : splitOn ch rest
  wrapOpt = \case
    "auto" -> WrapAuto
    "none" -> WrapNone
    "preserve" -> WrapPreserve
    w -> error ("bad wrap: " <> w)

run :: FilePath -> Text -> Text -> WrapOption -> Int -> Bool -> Text -> IO ()
run file from to wrap cols reset src =
  TIO.putStrLn . T.intercalate "," $
    [T.pack file, tshow cols] <> either (\e -> ["error: " <> T.replace "," ";" (tshow e)]) id (runPure row)
 where
  wopts = def {writerWrapText = wrap, writerColumns = cols}
  base = either (error . show) id (markdownProfile from to def wopts)
  readDoc :: Text -> PandocPure Pandoc
  readDoc
    | reset = fmap (walk resetWidths) . profileRead base
    | otherwise = profileRead base
  fmt t = readDoc t >>= profileWrite base
  html t = T.strip <$> (readDoc t >>= checkRender htmlCheck)
  row = do
    doc <- readDoc src
    fs <- iterateM (maxRounds + 1) fmt src
    let texts = src : fs
        fixed = [i | (i, (a, b)) <- zip [0 :: Int ..] (zip texts (drop 1 texts)), i >= 1, a == b]
        fixedAt = case fixed of
          i : _ -> Just i
          [] -> Nothing
    h0 <- html src
    h1 <- html (texts !! 1)
    hk <- maybe (pure Nothing) (fmap Just . html . (texts !!)) fixedAt
    pure
      [ tshow (length (query isTable doc))
      , yesNo (h0 == h1)
      , yesNo (texts !! 1 == texts !! 2)
      , yesNo (texts !! 2 == texts !! 3)
      , maybe (">" <> tshow maxRounds) tshow fixedAt
      , maybe "" (yesNo . (== h0)) hk
      ]
  isTable = \case Table {} -> [()]; _ -> []
  yesNo b = if b then "yes" else "no"

iterateM :: Monad m => Int -> (a -> m a) -> a -> m [a]
iterateM 0 _ _ = pure []
iterateM n f x = do
  y <- f x
  (y :) <$> iterateM (n - 1) f y

resetWidths :: Block -> Block
resetWidths (Table a c specs h b f) = Table a c [(al, ColWidthDefault) | (al, _) <- specs] h b f
resetWidths x = x

tshow :: Show a => a -> Text
tshow = T.pack . show
