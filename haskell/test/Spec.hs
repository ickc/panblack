module Main (main) where

import Control.Monad (unless)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as B
import Data.Either (isLeft)
import Data.IORef
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Panblack.Cache
import Panblack.Config
import Panblack.Diff (unifiedDiff)
import Panblack.Discover (compileExclude, excluded, relativeTo)
import Panblack.Guard
import Panblack.Jupytext (pairedPaths, pairedWithMarkdown)
import Panblack.Notebook
import Panblack.Markdown (markdownProfile)
import Panblack.Normalize
import Panblack.Target.Html (htmlCheck)
import System.Directory (getTemporaryDirectory)
import System.Environment (setEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
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
  check "config: defaults as 0.x, with every normalization" $
    fmap (map (\p -> (pcExts p, pcCheck p, pcNormalize p))) (parsed "- paths: [a]\n")
      == Right [(["md", "markdown"], ["source"], [minBound .. maxBound])]
  check "config: normalize: [] turns them off" $
    fmap (map pcNormalize) (parsed "- paths: [a]\n  normalize: []\n") == Right [[]]
  check "config: normalize and pandoc keys" $
    fmap (map (\p -> (pcNormalize p, KM.size (pcPandoc p)))) (parsed "- paths: [a]\n  normalize: [table-widths]\n  pandoc: {wrap: preserve, columns: 80}\n")
      == Right [([TableWidths], 2)]
  check "config: unknown profile key" $ isLeft (parsed "- paths: [a]\n  normalise: []\n")
  check "config: rejected pandoc key" $ isLeft (parsed "- paths: [a]\n  pandoc: {filters: [x.lua]}\n")
  check "config: unknown normalization" $ isLeft (parsed "- paths: [a]\n  normalize: [tables]\n")
  check "config: not a list" $ isLeft (parsed "paths: [a]\n")
  check "config: ipynb and hooks" $
    fmap (map (\p -> (pcCellFormat p, pcHooks p))) (parsed "- paths: [a]\n  ipynb: {cell-format: gfm}\n  hooks: [[jupytext, --sync, '{path}']]\n")
      == Right [("gfm", [["jupytext", "--sync", "{path}"]])]
  check "config: ipynb defaults" $
    fmap (map (\p -> (pcCellFormat p, pcHooks p))) (parsed "- paths: [a]\n") == Right [("gfm-tex_math_gfm", [])]
  check "config: unknown ipynb key" $ isLeft (parsed "- paths: [a]\n  ipynb: {format: gfm}\n")
  check "config: drop-jupytext-encoding is gone" $ isLeft (parsed "- paths: [a]\n  ipynb: {drop-jupytext-encoding: true}\n")
  check "config: empty hook" $ isLeft (parsed "- paths: [a]\n  hooks: [[]]\n")
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
  check "exclude: a wildcard matches a leading dot" $ excluded (ex ["*checkpoints/"]) True ["a", ".ipynb_checkpoints"]
  check "relativeTo" $
    relativeTo "/a/b" "/a/c/d" == "../c/d" && relativeTo "/a" "/a/b" == "b" && relativeTo "/a" "/a" == "."

  -- Diff
  check "diff: equal is empty" $ unifiedDiff "a" "b" "x\n" "x\n" == ""
  check "diff: unified" $
    unifiedDiff "a" "b" "1\n2\n3\n" "1\nX\n3\n" == "--- a\n+++ b\n@@ -1,3 +1,3 @@\n 1\n-2\n+X\n 3\n"

  -- Notebooks
  let nbProfile = let p = either (error . show) id (markdownProfile "gfm-tex_math_gfm" "gfm-tex_math_gfm" def def) in p {profileChecks = [sourceCheck p, htmlCheck]}
      formatNb whole bs = formatNotebook (NotebookOptions whole) nbProfile (either (error . T.unpack) id (readNotebook bs))
      fmtNb bs = either (Left . failWhere) (Right . resultBytes) (formatNb True bs)
      nb cells meta = "{\n \"cells\": [" <> B.intercalate "," cells <> "\n ],\n \"metadata\": " <> meta <> ",\n \"nbformat\": 4,\n \"nbformat_minor\": 5\n}\n"
      mdCell src = "\n  {\n   \"cell_type\": \"markdown\",\n   \"metadata\": {},\n   \"source\": " <> src <> "\n  }"
      code = "\n  {\n   \"cell_type\": \"code\",\n   \"execution_count\": 1.50,\n   \"metadata\": {},\n   \"outputs\": [],\n   \"source\": [\n    \"x  =  _a_\"\n   ]\n  }"
  check "notebook: a list keeps its layout, other bytes are kept" $
    fmtNb (nb [mdCell "[\n    \"Title\\n\",\n    \"=====\\n\",\n    \"\\n\",\n    \"_a_\"\n   ]", code] "{\"x\": 3}")
      == Right (nb [mdCell "[\n    \"# Title\\n\",\n    \"\\n\",\n    \"*a*\"\n   ]", code] "{\"x\": 3}")
  check "notebook: a string stays a string, with its final newline" $
    fmtNb (nb [mdCell "\"_a_\\n\\n* b\\n\""] "{}") == Right (nb [mdCell "\"*a*\\n\\n- b\\n\""] "{}")
  check "notebook: formatted cells are unchanged" $
    let x = nb [mdCell (TE.encodeUtf8 "[\"# T\\n\", \"\\n\", \"é \\\"q\\\"\"]"), code] "{}" in fmtNb x == Right x
  check "notebook: non-ASCII written as the file does" $
    fmtNb (nb [mdCell "\"_\\u00e9_\""] "{}") == Right (nb [mdCell "\"*\\u00e9*\""] "{}")
      && fmtNb (nb [mdCell (TE.encodeUtf8 "\"_é_\"")] "{}") == Right (nb [mdCell (TE.encodeUtf8 "\"*é*\"")] "{}")
  check "notebook: a reference defined in another cell fails the whole-notebook check" $
    fmtNb (nb [mdCell "\"[a]\"", mdCell "\"[a]: http://x\""] "{}") == Left "all markdown cells"
  check "notebook: cells are independent without the whole-notebook check" $
    fmap resultBytes (either (Left . failWhere) Right (formatNb False (nb [mdCell "\"[a]\"", mdCell "\"[a]: http://x\""] "{}")))
      -- The definition is unused in its own cell, so the writer drops it.
      == Right (nb [mdCell "\"\\\\[a\\\\]\"", mdCell "\"\""] "{}")
  -- The gfm writer drops the parentheses in @\\(a\\)@ (pandoc 3.10.2).
  let rejectedCell = mdCell "\"x (\\\\\\\\(a\\\\\\\\)) y\""
  check "notebook: a rejected cell is kept, the others formatted" $
    case formatNb True (nb [mdCell "\"_a_\"", code, rejectedCell] "{}") of
      Right r -> resultBytes r == nb [mdCell "\"*a*\"", code, rejectedCell] "{}" && map failWhere (resultKept r) == ["cell 3"]
      Left _ -> False
  check "notebook: not JSON" $ isLeft (readNotebook "{\"cells\": [}")

  -- Pairs, as jupytext's paired_paths resolves them
  let paired f formats = pairedPaths f (KM.fromList [("jupytext", A.object [("formats", A.String formats)]), ("language_info", A.object [("file_extension", ".py")])])
  check "pairs: extension" $ paired "/a/b/nb.ipynb" "ipynb,md" == ["/a/b/nb.md"]
  check "pairs: format name and suffix" $
    paired "/a/b/nb.ipynb" "ipynb,py:percent" == ["/a/b/nb.py"] && paired "/a/b/nb.ipynb" "ipynb,.pct.py:percent" == ["/a/b/nb.pct.py"]
  check "pairs: directory prefix" $ paired "/a/notebooks/nb.ipynb" "notebooks//ipynb,scripts//py:percent" == ["/a/scripts/nb.py"]
  check "pairs: file name prefix" $ paired "/a/b/nb.ipynb" "ipynb,md/md" == ["/a/b/mdnb.md"]
  check "pairs: common names and auto" $ paired "/a/b/nb.ipynb" "notebook,markdown,auto:light" == ["/a/b/nb.md", "/a/b/nb.py"]
  check "pairs: prefix roots are not resolved" $ null (paired "/a/notebooks/x/nb.ipynb" "notebooks///ipynb,scripts///py:percent")
  check "pairs: inconsistent path" $ null (paired "/a/b/nb.ipynb" "notebooks//ipynb,scripts//py")
  check "pairs: unpaired" $ null (pairedPaths "/a/nb.ipynb" KM.empty)
  let withFormats f = KM.fromList [("jupytext", A.object [("formats", A.String f)])]
  check "pairs: with markdown" $
    pairedWithMarkdown (withFormats "ipynb,md") && pairedWithMarkdown (withFormats "notebooks///ipynb,md///md:myst")
      && not (pairedWithMarkdown (withFormats "ipynb,py:percent")) && not (pairedWithMarkdown KM.empty)

  tmp <- getTemporaryDirectory
  setEnv "XDG_CACHE_HOME" (tmp </> "panblack-spec-cache")
  let key = cacheKey "spec"
  c0 <- loadCache key
  saveCache c0 [("/a.md", Record (digest "a")), ("/b.md", Record (digest "b"))]
  c1 <- loadCache key
  check "cache: recorded digests hit" $ isCached c1 "/a.md" "a" && isCached c1 "/b.md" "b"
  check "cache: other content misses" $ not (isCached c1 "/a.md" "a2") && not (isCached c1 "/c.md" "c")
  saveCache c1 [("/a.md", Forget), ("/b.md", Keep)]
  c2 <- loadCache key
  check "cache: forget and keep" $ not (isCached c2 "/a.md" "a") && isCached c2 "/b.md" "b"
  check "cache: off" $ not (isCached noCache "/b.md" "b")
  saveCache c2 [("/b.md", Forget)]

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
