module Main (main) where

import Control.Monad (unless)
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.IORef
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Panblack.Config
import Panblack.Diff (unifiedDiff)
import Panblack.Discover (compileExclude, excluded, relativeTo)
import Panblack.Guard
import Panblack.Markdown (markdownProfile)
import Panblack.Normalize
import Panblack.Target.Html (htmlCheck)
import System.Exit (exitFailure)
import Text.Pandoc.Options (WrapOption (..), WriterOptions (..), def)
import Text.Pandoc.Readers.Markdown (readMarkdown)
import Text.Pandoc.Writers.Markdown (writeMarkdown)

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let check name ok = unless ok $ do
        putStrLn ("FAIL: " <> name)
        modifyIORef failures (+ 1)
      base = either (error . show) id (markdownProfile "markdown" "markdown" def def)
      md = base {profileChecks = [sourceCheck base, htmlCheck]}
      markdown = Profile (readMarkdown def) (writeMarkdown def) []
      withChecks p cs = p {profileChecks = cs}
      constCheck = Check "const" (const (pure ""))
      dropping = markdown {profileWrite = const (pure "")}
      drifting = markdown {profileWrite = fmap (<> " x") . writeMarkdown def}

  check "formatted input is unchanged" $
    textOf (format md "# Title\n\nSome *text*.\n") == Just "# Title\n\nSome *text*.\n"
  check "style is normalized, AST-equal" $
    format md "Title\n=====\n\n_a_\n" `eq` Right (Formatted "# Title\n\n*a*\n" AstEqual)
  check "title block becomes YAML, as with the pandoc CLI" $
    textOf (format md "% T\n\nx\n") == Just "---\ntitle: T\n---\n\nx\n"
  check "writer that drops content fails the html check" $
    failedChecks (format (withChecks dropping [htmlCheck]) "a\n") == ["html"]
  check "no checks accepts anything, as in 0.x" $
    format dropping "a\n" `eq` Right (Formatted "" (ChecksPassed []))
  check "AST change with passing checks is accepted" $
    format (withChecks markdown {profileWrite = const (pure "b\n")} [constCheck]) "a\n"
      `eq` Right (Formatted "b\n" (ChecksPassed ["const"]))
  check "drifting writer fails the source check" $
    failedChecks (format (withChecks drifting [sourceCheck drifting]) "a\n") == ["source"]

  -- Normalizations: each case is rejected without it and accepted with it
  -- (settings as in the recommended defaults).
  let preserve = def {writerWrapText = WrapPreserve}
      recommended ns =
        let p =
              normalizing ns . either (error . show) id $
                markdownProfile "markdown-simple_tables-multiline_tables" "markdown-simple_tables-multiline_tables" def preserve
         in p {profileChecks = [sourceCheck p, htmlCheck]}
      normalized n src out = do
        check (T.unpack (normalizationName n) <> ": rejected without") $
          not (null (failedChecks (format (recommended []) src)))
        check (T.unpack (normalizationName n) <> ": accepted with") $
          textOf (format (recommended [n]) src) == Just out
      wrappedCell = "+------+-------------+\n| Name | Description |\n+======+=============+\n| a    | wrapped     |\n|      | text        |\n+------+-------------+\n"
  normalized CodeBlockBlankLines "```\ncode\n\n```\n" "    code\n"
  normalized DivBareText "<div>text</div>\n" "::: {}\ntext\n:::\n"
  normalized EmptyComments "- a\n\n```\ncode\n```\n" "- a\n\n<!-- -->\n\n    code\n"
  check "table-widths: grid table becomes pipe table" $
    textOf (format (recommended [TableWidths]) "+---+---+\n| a | b |\n+===+===+\n| x | y |\n+---+---+\n")
      == Just "| a   | b   |\n|-----|-----|\n| x   | y   |\n"
  check "table-cell-breaks: wrapped cell rejected with widths reset alone" $
    failedChecks (format (recommended [TableWidths]) wrappedCell) == ["source", "html"]
  check "table-cell-breaks: accepted with both" $
    textOf (format (recommended [TableWidths, TableCellBreaks]) wrappedCell)
      == Just "| Name | Description  |\n|------|--------------|\n| a    | wrapped text |\n"
  check "normalization names round-trip" $
    all (\x -> normalizationByName (normalizationName x) == Just x) [minBound .. maxBound]

  -- Config
  let parsed = parseConfig
  check "config: defaults as 0.x" $
    fmap (map (\p -> (pcExts p, pcCheck p, pcNormalize p))) (parsed "- paths: [a]\n")
      == Right [(["md", "markdown"], ["source"], [])]
  check "config: normalize and pandoc keys" $
    fmap (map (\p -> (pcNormalize p, KM.size (pcPandoc p)))) (parsed "- paths: [a]\n  normalize: [table-widths]\n  pandoc: {wrap: preserve, columns: 80}\n")
      == Right [([TableWidths], 2)]
  check "config: unknown profile key" $ isLeft (parsed "- paths: [a]\n  normalise: []\n")
  check "config: rejected pandoc key" $ isLeft (parsed "- paths: [a]\n  pandoc: {filters: [x.lua]}\n")
  check "config: unknown normalization" $ isLeft (parsed "- paths: [a]\n  normalize: [tables]\n")
  check "config: not a list" $ isLeft (parsed "paths: [a]\n")
  check "starter config parses" $
    fmap (map pcNormalize) (parsed (encodeUtf8' starterConfig)) == Right [[minBound .. maxBound]]

  -- Excludes
  let ex = either error id . traverse compileExclude
  check "exclude: name at any depth" $ excluded (ex ["node_modules"]) True ["a", "node_modules"]
  check "exclude: trailing slash is directories only" $
    not (excluded (ex ["build/"]) False ["build"]) && excluded (ex ["build/"]) True ["a", "build"]
  check "exclude: slash anchors at the root" $
    excluded (ex ["docs/*.md"]) False ["docs", "x.md"] && not (excluded (ex ["docs/*.md"]) False ["a", "docs", "x.md"])
  check "exclude: glob on names" $ excluded (ex ["*.draft.md"]) False ["a", "x.draft.md"]
  check "relativeTo" $
    relativeTo "/a/b" "/a/c/d" == "../c/d" && relativeTo "/a" "/a/b" == "b" && relativeTo "/a" "/a" == "."

  -- Diff
  check "diff: equal is empty" $ unifiedDiff "a" "b" "x\n" "x\n" == ""
  check "diff: unified" $
    unifiedDiff "a" "b" "1\n2\n3\n" "1\nX\n3\n" == "--- a\n+++ b\n@@ -1,3 +1,3 @@\n 1\n-2\n+X\n 3\n"

  n <- readIORef failures
  if n == 0 then putStrLn "all passed" else exitFailure
 where
  eq :: Either GuardFailure Formatted -> Either GuardFailure Formatted -> Bool
  eq (Right a) (Right b) = a == b
  eq _ _ = False
  textOf = either (const Nothing) (Just . formattedText)
  encodeUtf8' = TE.encodeUtf8
  failedChecks = \case
    Left (ChecksFailed _ _ ds) -> map diffCheck ds
    _ -> []
