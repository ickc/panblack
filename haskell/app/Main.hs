-- | Prototype driver: format stdin to stdout. The real CLI (profiles, file
-- discovery, --check/--diff) comes in plan step 2.
module Main (main) where

import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Panblack.Guard
import Panblack.Markdown (markdownProfile)
import Panblack.Target.Registry (targetByName)
import System.Console.GetOpt
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import Text.Pandoc.Error (renderError)
import Text.Pandoc.Options

data Opts = Opts
  { optFrom :: T.Text
  , optTo :: Maybe T.Text
  , optChecks :: [T.Text]
  , optWriter :: WriterOptions
  }

options :: [OptDescr (Opts -> Either String Opts)]
options =
  [ Option "f" ["from"] (ReqArg (\s o -> Right o {optFrom = T.pack s}) "FORMAT") "reader format (default: markdown)"
  , Option "t" ["to"] (ReqArg (\s o -> Right o {optTo = Just (T.pack s)}) "FORMAT") "writer format (default: same as --from)"
  , Option "" ["check"] (ReqArg (\s o -> Right o {optChecks = optChecks o ++ [T.pack s]}) "TARGET") "source (stability) or a target format; repeatable (default: source)"
  , Option "" ["columns"] (ReqArg (\s o -> (\n -> o {optWriter = (optWriter o) {writerColumns = n}}) <$> readE s) "N") "line length"
  , Option "" ["wrap"] (ReqArg (\s o -> (\w -> o {optWriter = (optWriter o) {writerWrapText = w}}) <$> wrap s) "auto|none|preserve") "wrapping"
  , Option "" ["reference-location"] (ReqArg (\s o -> (\r -> o {optWriter = (optWriter o) {writerReferenceLocation = r}}) <$> refLoc s) "block|section|document") "footnote placement"
  ]
 where
  readE s = case reads s of
    [(n, "")] -> Right n
    _ -> Left ("not a number: " <> s)
  wrap = \case
    "auto" -> Right WrapAuto
    "none" -> Right WrapNone
    "preserve" -> Right WrapPreserve
    s -> Left ("bad --wrap: " <> s)
  refLoc = \case
    "block" -> Right EndOfBlock
    "section" -> Right EndOfSection
    "document" -> Right EndOfDocument
    s -> Left ("bad --reference-location: " <> s)

die' :: Int -> String -> IO a
die' code msg = hPutStrLn stderr ("panblack: " <> msg) >> exitWith (ExitFailure code)

main :: IO ()
main = do
  args <- getArgs
  opts <- case getOpt Permute options args of
    (fs, [], []) -> either (die' 3) pure $ foldl (>>=) (Right (Opts "markdown" Nothing [] def)) fs
    (_, _, errs) -> die' 3 (concat errs <> usageInfo "usage: panblack [OPTION...] < in > out" options)
  base <-
    either (die' 3 . T.unpack . renderError) pure $
      markdownProfile (optFrom opts) (fromMaybe (optFrom opts) (optTo opts)) def (optWriter opts)
  let toCheck = \case
        "source" -> Right (sourceCheck base)
        name -> targetByName name
      names = if null (optChecks opts) then ["source"] else optChecks opts
  checks <- either (die' 3 . T.unpack . renderError) pure $ traverse toCheck names
  let profile = base {profileChecks = checks}
  src <- TIO.getContents
  case format profile src of
    Right f -> do
      TIO.putStr (formattedText f)
      case formattedBy f of
        AstEqual -> pure ()
        ChecksPassed cs -> hPutStrLn stderr ("panblack: AST changed; accepted by checks: " <> T.unpack (T.intercalate ", " cs))
    Left (PandocFailed e) -> die' 3 (T.unpack (renderError e))
    Left (ChecksFailed _ _ diffs) -> do
      hPutStrLn stderr "panblack: rejected: the formatted source renders differently"
      for_ diffs $ \d -> hPutStrLn stderr ("  failed check: " <> T.unpack (diffCheck d))
      exitWith (ExitFailure 2)
