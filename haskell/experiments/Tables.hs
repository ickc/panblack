-- | Plan step 1b: how pandoc's markdown tables survive formatting.
--
-- For every table in experiments/tables, every combination of disabled
-- table extensions and a range of column widths, format with checks
-- [source, html] and print one CSV row. The extensions are disabled either
-- for reading and writing (@from@) or for writing only (@to@, reading with
-- plain markdown).
--
-- Build and run from the repository root:
--   cabal build all
--   cabal exec -- ghc -O1 -package panblack -package directory -XGHC2021 -XLambdaCase \
--     -XOverloadedStrings -outputdir /tmp/tables-build -o /tmp/tables haskell/experiments/Tables.hs
--   /tmp/tables > tables.csv
module Main (main) where

import Data.List (isSuffixOf, sort, subsequences)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Panblack.Guard
import Panblack.Markdown (markdownProfile)
import Panblack.Target.Html (htmlCheck)
import System.Directory (listDirectory)
import Text.Pandoc.Class (runPure)
import Text.Pandoc.Definition
import Text.Pandoc.Options
import Text.Pandoc.Walk (query, walk)

dir :: FilePath
dir = "haskell/experiments/tables"

tableExts :: [Text]
tableExts = ["simple_tables", "multiline_tables", "grid_tables", "pipe_tables"]

columnsList :: [Int]
columnsList = [40, 72, 100, 120, 200]

main :: IO ()
main = do
  files <- sort . filter (".md" `isSuffixOf`) <$> listDirectory dir
  putStrLn "file,disabled_in,disabled,columns,reset_widths,tables_read,result,failed,written_as"
  sequence_
    [ run file src side disabled cols reset
    | file <- files
    , let src = TIO.readFile (dir <> "/" <> file)
    , side <- ["from", "to"]
    , disabled <- subsequences tableExts
    , length disabled < length tableExts
    , cols <- columnsList
    , reset <- [False, True]
    ]

run :: FilePath -> IO Text -> Text -> [Text] -> Int -> Bool -> IO ()
run file getSrc side disabled cols reset = do
  src <- getSrc
  let spec = T.concat ("markdown" : map ("-" <>) disabled)
      wopts = def {writerWrapText = WrapPreserve, writerColumns = cols}
      (from, to) = if side == "from" then (spec, spec) else ("markdown", spec)
      base = either (error . show) id (markdownProfile from to def wopts)
      -- The width-reset variant treats widths as meaningless on both sides,
      -- which is outside the pandoc-relative guarantee; recorded as data only.
      base'
        | reset = base {profileRead = fmap (walk resetWidths) . profileRead base}
        | otherwise = base
      profile = base' {profileChecks = [sourceCheck base', htmlCheck]}
      (result, failed, out) = case format profile src of
        Right (Formatted o AstEqual) -> ("ast-equal", "", o)
        Right (Formatted o (ChecksPassed _)) -> ("checks-passed", "", o)
        Left (ChecksFailed {failDiffs = ds}) -> ("rejected", T.intercalate "+" (map diffCheck ds), "")
        Left (PandocFailed e) -> ("error", T.pack (show e), "")
      nTables = either (const 0) (length . query isTable) . runPure $ profileRead profile src
  TIO.putStrLn . T.intercalate "," $
    [ T.pack file
    , side
    , T.intercalate "+" disabled
    , T.pack (show cols)
    , T.pack (show reset)
    , T.pack (show nTables)
    , result
    , failed
    , if T.null out then "" else syntaxOf out
    ]
 where
  isTable = \case Table {} -> [()]; _ -> []

resetWidths :: Block -> Block
resetWidths (Table a c specs h b f) = Table a c [(al, ColWidthDefault) | (al, _) <- specs] h b f
resetWidths x = x

-- | Guess which table syntax the writer used.
syntaxOf :: Text -> Text
syntaxOf out
  | any ("+-" `T.isPrefixOf`) ls = "grid"
  | any (\l -> "|" `T.isPrefixOf` l) ls = "pipe"
  | any isDashes ls && length (filter isDashes ls) >= 2 && any T.null (drop 1 (dropWhile (not . isDashes) ls)) = "multiline"
  | any isDashGroups ls = "simple"
  | otherwise = "none"
 where
  ls = T.lines out
  isDashes l = not (T.null l) && T.all (== '-') l
  isDashGroups l = not (T.null l) && T.all (`elem` ("- " :: String)) l && T.any (== '-') l
