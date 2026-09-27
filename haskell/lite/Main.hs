-- | panblack-lite: format stdin to stdout with one profile given by
-- options, for editors and other hosts where size matters (see
-- docs/design.md, "panblack-lite"). The markdown flavours and the source and
-- html checks only; the CLI's config file, paths, cache, notebooks and hooks
-- are left out.
--
-- A profile here means what it does in @.panblack.yaml@, parsed by the same
-- code: @--check@ and @--normalize@ as the profile keys, and pandoc's options
-- as its @pandoc:@ keys. So the same settings format the same way as the CLI.
-- Nothing here may call 'Panblack.Target.Registry.targetByName': the linker
-- would then keep every pandoc writer.
module Main (main) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Version (showVersion)
import Data.Yaml qualified as Y
import Panblack.Config
import Panblack.Guard
import Panblack.Normalize (Normalization, normalizationByName, normalizationName)
import Panblack.Target.Html (htmlCheck)
import Paths_panblack (version)
import System.Console.GetOpt
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import Text.Pandoc.Error (PandocError (..), renderError)
import Text.Pandoc.Version (pandocVersionText)

data Opts = Opts
  { optChecks :: [Text]
  , optNormalize :: [Normalization]
  , optPandoc :: KM.KeyMap Value
  , optVersion :: Bool
  , optHelp :: Bool
  }

options :: [OptDescr (Opts -> Either String Opts)]
options =
  [ Option "" ["check"] (ReqArg (\s o -> Right o {optChecks = list s}) "LIST") "checks that must pass, of source and html (default: source); empty for none"
  , Option "" ["normalize"] (ReqArg (\s o -> (\ns -> o {optNormalize = ns}) <$> traverse normalization (list s)) "LIST") ("normalizations, of " <> T.unpack (T.intercalate ", " allNames) <> " (default: all); empty for none")
  ]
    ++ [ Option "" [T.unpack k] (OptArg (\s o -> (\v -> o {optPandoc = KM.insert (K.fromText k) v (optPandoc o)}) <$> pandocValue k s) "VALUE") ("pandoc's " <> T.unpack k)
       | k <- pandocKeys
       ]
    ++ [ Option "" ["version"] (NoArg (\o -> Right o {optVersion = True})) "print the version and the bundled pandoc version"
       , Option "h" ["help"] (NoArg (\o -> Right o {optHelp = True})) "print this help"
       ]
 where
  list = filter (not . T.null) . T.splitOn "," . T.pack
  allNames = map normalizationName [minBound .. maxBound]
  normalization n = maybe (Left ("--normalize: unknown normalization " <> T.unpack n)) Right (normalizationByName n)

-- | An option's value as its @pandoc:@ key would have it: YAML, so numbers
-- and booleans keep their types; a flag alone is @true@; comma-separated
-- for the one list.
pandocValue :: Text -> Maybe String -> Either String Value
pandocValue k = \case
  Nothing -> Right (Bool True)
  Just s
    | k == "indented-code-classes" -> Right (Array (foldMap (pure . String) (filter (not . T.null) (T.splitOn "," (T.pack s)))))
    | otherwise -> either (const (Right (String (T.pack s)))) Right (Y.decodeEither' (TE.encodeUtf8 (T.pack s)))

usage :: String
usage =
  usageInfo
    ( unlines
        [ "usage: panblack-lite [OPTION...]   format stdin to stdout"
        , ""
        , "The options are a panblack profile's: pandoc's as under its pandoc: key,"
        , "e.g. --wrap=preserve --columns=72."
        , ""
        , "Exit codes: 0 ok, 2 rejected by its checks, 3 usage, config or pandoc error."
        , "The input is passed through unless it was formatted."
        ]
    )
    options

die' :: String -> IO a
die' msg = hPutStrLn stderr ("panblack-lite: " <> msg) >> exitWith (ExitFailure 3)

main :: IO ()
main = do
  args <- getArgs
  opts <- case getOpt Permute options args of
    (fs, [], []) -> either (die' . (<> "\n" <> usage)) pure $ foldl' (>>=) (Right defaults) fs
    (_, extra, []) -> die' ("unexpected arguments: " <> unwords extra <> "\n" <> usage)
    (_, _, errs) -> die' (concat errs <> usage)
  if
    | optHelp opts -> putStr usage
    | optVersion opts -> putStrLn ("panblack-lite " <> showVersion version <> " (pandoc " <> T.unpack pandocVersionText <> ")")
    | otherwise -> run opts
 where
  d = defaultProfileConfig
  defaults = Opts (pcCheck d) (pcNormalize d) KM.empty False False

run :: Opts -> IO ()
run opts = do
  let pc = defaultProfileConfig {pcCheck = optChecks opts, pcNormalize = optNormalize opts, pcPandoc = optPandoc opts}
  settings <- loadSettings "." pc >>= either (die' . T.unpack) pure
  profile <- either (die' . T.unpack . renderError) pure $ buildProfileWith target settings (pcCheck pc) (pcNormalize pc)
  bytes <- B.getContents
  raw <- either (const (die' "stdin: not valid UTF-8")) pure (TE.decodeUtf8' bytes)
  case format profile (sourceText raw) of
    Right f -> TIO.putStr (withLineEnding (setEol settings) (formattedText f))
    Left (ChecksFailed _ _ ds) -> do
      hPutStrLn stderr ("rejected: pandoc renders it differently after formatting (failed checks: " <> T.unpack (T.intercalate ", " (map diffCheck ds)) <> ")")
      TIO.putStr raw
      exitWith (ExitFailure 2)
    Left (PandocFailed e) -> do
      hPutStrLn stderr ("panblack-lite: " <> T.unpack (renderError e))
      TIO.putStr raw
      exitWith (ExitFailure 3)
 where
  target = \case
    "html" -> Right htmlCheck
    c -> Left (PandocAppError ("unsupported check " <> c <> "; panblack-lite has source and html"))
