-- | The panblack CLI (see docs/design.md, "CLI").
module Main (main) where

import Control.Concurrent (forkIO, setNumCapabilities)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (SomeException, bracket_, displayException, evaluate, try)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString qualified as B
import Data.List (intercalate)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Version (showVersion)
import GHC.Conc (getNumProcessors)
import Panblack.Config
import Panblack.Diff (unifiedDiff)
import Panblack.Discover
import Panblack.Guard
import Panblack.Jupytext (pairedPaths, pairedWithMarkdown)
import Panblack.Notebook
import Paths_panblack (version)
import System.Console.GetOpt
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.Process (cwd, proc, readCreateProcessWithExitCode)
import System.IO (hPutStrLn, nativeNewline, stderr)
import System.IO qualified as IO
import System.IO.Error (isDoesNotExistError)
import Text.Pandoc.App (LineEnding (..))
import Text.Pandoc.Error (renderError)
import Text.Pandoc.Version (pandocVersionText)

data Opts = Opts
  { optCheck :: Bool
  , optDiff :: Bool
  , optConfig :: Maybe FilePath
  , optJobs :: Maybe Int
  , optVerbose :: Bool
  , optStdinFilename :: Maybe FilePath
  , optVersion :: Bool
  , optHelp :: Bool
  }

defaultOpts' :: Opts
defaultOpts' = Opts False False Nothing Nothing False Nothing False False

options :: [OptDescr (Opts -> Either String Opts)]
options =
  [ Option "" ["check"] (NoArg (\o -> Right o {optCheck = True})) "write nothing; exit 1 if any file would change"
  , Option "" ["diff"] (NoArg (\o -> Right o {optDiff = True})) "write nothing; print a unified diff of the changes"
  , Option "" ["config"] (ReqArg (\s o -> Right o {optConfig = Just s}) "FILE") "config file (default: .panblack.yaml, searched upwards to the repository root)"
  , Option "j" ["jobs"] (ReqArg (\s o -> (\n -> o {optJobs = Just n}) <$> positive s) "N") "files formatted in parallel (default: number of CPUs)"
  , Option "" ["stdin-filename"] (ReqArg (\s o -> Right o {optStdinFilename = Just s}) "PATH") "with -, choose the profile as if formatting PATH"
  , Option "v" ["verbose"] (NoArg (\o -> Right o {optVerbose = True})) "report unchanged files, and show why a file was rejected"
  , Option "" ["version"] (NoArg (\o -> Right o {optVersion = True})) "print the version and the bundled pandoc version"
  , Option "h" ["help"] (NoArg (\o -> Right o {optHelp = True})) "print this help"
  ]
 where
  positive s = case reads s of
    [(n, "")] | n > 0 -> Right n
    _ -> Left ("-j: expected a positive number: " <> s)

usage :: String
usage =
  usageInfo
    ( unlines
        [ "usage: panblack [OPTION...] [PATH...]   format in place, using the config's profiles"
        , "       panblack [OPTION...] -           format stdin to stdout"
        , "       panblack init                    print a starter .panblack.yaml"
        , ""
        , "Exit codes: 0 ok, 1 --check found changes, 2 a file was rejected by its checks,"
        , "3 usage, config or IO error."
        ]
    )
    options

configName :: FilePath
configName = ".panblack.yaml"

die' :: String -> IO a
die' msg = hPutStrLn stderr ("panblack: " <> msg) >> exitWith (ExitFailure 3)

-- | A profile ready to use.
data Loaded = Loaded
  { lName :: String
  , lRoot :: FilePath
  , lConfig :: ProfileConfig
  , lExcludes :: [Exclude]
  , lProfile :: Profile
  , lCellProfile :: Profile
  -- ^ For notebook cells.
  , lEol :: LineEnding
  }

data Outcome
  = Unchanged
  | Changed Text Text Accepted
  -- ^ The original and the formatted source.
  | Rejected [CheckDiff]
  | PartlyChanged Text Text [CheckDiff]
  -- ^ Some notebook cells were formatted; those that failed their checks
  -- were kept as they were.
  | Failed Text

-- | What happened to one file.
data Result = Result
  { rOutcome :: Outcome
  , rWarnings :: [String]
  , rHookError :: Maybe Text
  }

main :: IO ()
main =
  getArgs >>= \case
    ["init"] -> TIO.putStr starterConfig
    "init" : _ -> die' "init takes no arguments"
    args -> case getOpt Permute options args of
      (fs, paths, []) -> either (die' . (<> "\n" <> usage)) (run paths) $ foldl' (>>=) (Right defaultOpts') fs
      (_, _, errs) -> die' (concat errs <> usage)

run :: [FilePath] -> Opts -> IO ()
run paths opts
  | optHelp opts = putStr usage
  | optVersion opts = putStrLn ("panblack " <> showVersion version <> " (pandoc " <> T.unpack pandocVersionText <> ")")
  | otherwise = do
      cwd <- getCurrentDirectory >>= canonicalizePath
      configFile <- case optConfig opts of
        Just f -> do
          exists <- doesFileExist f
          unless exists $ die' (f <> ": no such file")
          Just <$> canonicalizePath f
        Nothing -> findConfig cwd
      stdinMode <- case paths of
        ["-"] -> pure True
        _ | "-" `elem` paths -> die' "- can't be combined with other paths"
        _ -> pure False
      (root, configs) <- case configFile of
        Just f -> do
          bs <- B.readFile f
          either (die' . ((relativeTo cwd f <> ": ") <>) . T.unpack) (pure . (takeDirectory f,)) (parseConfig bs)
        Nothing
          | null paths -> die' ("no " <> configName <> " found and no paths given; see panblack init")
          | otherwise -> pure (cwd, [defaultProfileConfig {pcPaths = if stdinMode then [] else paths}])
      let source = maybe "defaults" (relativeTo cwd) configFile
      loaded <- forM (zip [1 :: Int ..] configs) $ \(i, pc) -> do
        let name = source <> ", profile " <> show i
            orDie = either (die' . ((name <> ": ") <>)) pure
        excludes <- orDie (traverse compileExclude (pcExcludes pc))
        settings <- loadSettings root pc >>= orDie . either (Left . T.unpack) Right
        let build s = orDie . either (Left . T.unpack . renderError) Right $ buildProfile s (pcCheck pc) (pcNormalize pc)
            cf = pcCellFormat pc
        profile <- build settings
        cellProfile <- build settings {setFrom = cf, setTo = cf}
        pure (Loaded name root pc excludes profile cellProfile (setEol settings))
      jobs <- maybe getNumProcessors pure (optJobs opts)
      setNumCapabilities jobs
      if stdinMode
        then formatStdin opts (isNothing configFile) cwd loaded
        else formatFiles opts cwd (if isNothing configFile then [] else paths) loaded jobs

-- | Look for the config from the directory upwards, stopping at the
-- repository root (a directory containing @.git@).
findConfig :: FilePath -> IO (Maybe FilePath)
findConfig dir = do
  let f = dir </> configName
  found <- doesFileExist f
  atRoot <- (||) <$> doesDirectoryExist (dir </> ".git") <*> doesFileExist (dir </> ".git")
  let parent = takeDirectory dir
  if
    | found -> pure (Just f)
    | atRoot || parent == dir -> pure Nothing
    | otherwise -> findConfig parent

formatFiles :: Opts -> FilePath -> [FilePath] -> [Loaded] -> Int -> IO ()
formatFiles opts cwd only loaded jobs = do
  perProfile <- forM loaded $ \l -> do
    let pc = lConfig l
    found <- discover (lRoot l) (pcPaths pc) (pcExts pc) (lExcludes l)
    either (die' . ((lName l <> ": ") <>)) (pure . map (,l)) found
  let byFile = M.fromListWith (flip (++)) [(f, [l]) | (f, l) <- concat perProfile]
  files <- forM (M.toList byFile) $ \case
    (f, [l]) -> pure (f, l)
    (f, ls) -> die' (relativeTo cwd f <> ": matched by more than one profile: " <> intercalate ", " (map lName ls))
  -- Paths on the command line select among the configured files.
  selected <-
    if null only
      then pure files
      else do
        onlyAbs <- mapM canonicalizePath only
        forM_ (zip only onlyAbs) $ \(p, a) -> do
          isFile <- doesFileExist a
          isDir <- doesDirectoryExist a
          if
            | not (isFile || isDir) -> die' (p <> ": no such file or directory")
            | isFile && M.notMember a byFile -> hPutStrLn stderr ("panblack: " <> p <> ": no profile matches; skipped")
            | otherwise -> pure ()
        pure [(f, l) | (f, l) <- files, any (f `isUnder`) onlyAbs]
  let covered = M.keysSet byFile
  results <- parMapIO jobs (\(f, l) -> (f,) <$> formatFile opts cwd covered l f) selected
  codes <- forM results $ \(f, r) -> do
    let shown = relativeTo cwd f
        outcome = rOutcome r
    forM_ (rWarnings r) $ \w -> hPutStrLn stderr ("warning: " <> shown <> ": " <> w)
    report opts shown outcome
    forM_ (rHookError r) $ \e -> hPutStrLn stderr ("error: " <> shown <> ": " <> T.unpack e)
    case rewritten outcome of
      Just (old, out) | optDiff opts -> TIO.putStr (unifiedDiff (T.pack shown) (T.pack shown) old out)
      _ -> pure ()
    pure (max (exitCodeOf opts outcome) (maybe 0 (const 3) (rHookError r)))
  summary opts (map (rOutcome . snd) results) (length [() | (_, Result {rHookError = Just _}) <- results])
  exitWith' (maximum (0 : codes))

-- | Format a file in place, then run the profile's hooks if it was
-- accepted. The covered files are those of every profile, to warn when
-- both sides of a jupytext pair are formatted.
formatFile :: Opts -> FilePath -> S.Set FilePath -> Loaded -> FilePath -> IO Result
formatFile opts cwd covered l f = do
  r <- try $ do
    bytes <- B.readFile f
    case TE.decodeUtf8' bytes of
      Left _ -> pure (Result (Failed "not valid UTF-8") [] Nothing)
      Right raw -> do
        (outcome, warnings) <-
          if isNotebook f
            then do
              (outcome, meta) <- formatNotebookSource l raw
              pairs <- forM (pairedPaths f meta) $ \p -> do
                exists <- doesFileExist p
                if exists then Just <$> canonicalizePath p else pure Nothing
              pure
                ( outcome
                , [ "paired by jupytext with " <> relativeTo cwd p <> ", which is also formatted; format one side of a pair only"
                  | Just p <- pairs
                  , p `S.member` covered
                  ]
                )
            else (,[]) <$> formatSource l raw
        let dry = optCheck opts || optDiff opts
        case rewritten outcome of
          Just (_, out) | not dry -> B.writeFile f (TE.encodeUtf8 out)
          _ -> pure ()
        -- As 0.x ran jupytext after every accepted file, changed or not.
        hookError <- case outcome of
          _ | dry -> pure Nothing
          Unchanged -> runHooks l f
          Changed {} -> runHooks l f
          PartlyChanged {} -> runHooks l f
          _ -> pure Nothing
        pure (Result outcome warnings hookError)
  pure $ either (\e -> Result (Failed (T.pack (displayException (e :: SomeException)))) [] Nothing) id r

-- | The original and the text to write, if there is one.
rewritten :: Outcome -> Maybe (Text, Text)
rewritten = \case
  Changed old out _ -> Just (old, out)
  PartlyChanged old out _ -> Just (old, out)
  _ -> Nothing

isNotebook :: FilePath -> Bool
isNotebook f = takeExtension f == ".ipynb"

-- | Run a profile's hooks in order, in the config directory, stopping at the
-- first that fails.
runHooks :: Loaded -> FilePath -> IO (Maybe Text)
runHooks l f = go (pcHooks (lConfig l))
 where
  path = T.pack (relativeTo (lRoot l) f)
  go = \case
    [] -> pure Nothing
    cmd : rest -> do
      let argv = map (T.unpack . T.replace "{path}" path) cmd
          exe = concat (take 1 argv)
          shown = T.pack (unwords argv)
      r <- try (readCreateProcessWithExitCode (proc exe (drop 1 argv)) {cwd = Just (lRoot l)} "")
      case r of
        Left e
          | isDoesNotExistError e -> pure (Just ("hook failed: " <> T.pack exe <> ": command not found"))
          | otherwise -> pure (Just ("hook failed: " <> shown <> ": " <> T.pack (displayException e)))
        Right (ExitSuccess, _, _) -> go rest
        Right (ExitFailure n, out, err) ->
          pure . Just $
            "hook failed with exit code " <> T.pack (show n) <> ": " <> shown
              <> T.pack (concatMap ("\n  " <>) (lines (out <> err)))

formatStdin :: Opts -> Bool -> FilePath -> [Loaded] -> IO ()
formatStdin opts noConfig cwd loaded = do
  l <- case (optStdinFilename opts, loaded) of
    (_, one : _) | noConfig -> pure one
    (Nothing, [one]) -> pure one
    (Nothing, _) -> die' "the config has several profiles; choose one with --stdin-filename"
    (Just name, _) -> do
      file <- canonicalizePath name
      hits <- flip filterMIO loaded $ \x ->
        let pc = lConfig x in matches (lRoot x) (pcPaths pc) (pcExts pc) (lExcludes x) file
      case hits of
        [one] -> pure one
        [] -> die' (relativeTo cwd file <> ": no profile matches")
        _ -> die' (relativeTo cwd file <> ": matched by more than one profile")
  bytes <- B.getContents
  raw <- either (const (die' "stdin: not valid UTF-8")) pure (TE.decodeUtf8' bytes)
  outcome <-
    if maybe False isNotebook (optStdinFilename opts)
      then fst <$> formatNotebookSource l raw
      else formatSource l raw
  let name = fromMaybe "-" (optStdinFilename opts)
      quiet = optCheck opts || optDiff opts
  report opts {optVerbose = optVerbose opts && quiet} name outcome
  case rewritten outcome of
    Just (_, out)
      | optDiff opts -> TIO.putStr (unifiedDiff (T.pack name) (T.pack name) raw out)
      | not quiet -> TIO.putStr out
    -- Pass the input through, so a pipe never loses the document.
    _ | not quiet -> TIO.putStr raw
    _ -> pure ()
  exitWith' (exitCodeOf opts outcome)
 where
  filterMIO p = fmap concat . mapM (\x -> (\b -> [x | b]) <$> p x)

-- | Format a source, forcing the result so that it's computed in the
-- calling thread.
formatSource :: Loaded -> Text -> IO Outcome
formatSource l raw =
  forceOutcome $ case format (lProfile l) src of
    Left (PandocFailed e) -> Failed (renderError e)
    Left (ChecksFailed _ _ ds) -> Rejected ds
    Right f
      | out == raw -> Unchanged
      | otherwise -> Changed raw out (formattedBy f)
     where
      out = withEol (formattedText f)
 where
  -- As pandoc's CLI does when reading.
  src = T.filter (/= '\r') (fromMaybe raw (T.stripPrefix "\xFEFF" raw))
  withEol = case lEol l of
    CRLF -> crlf
    Native | nativeNewline == IO.CRLF -> crlf
    _ -> id
  crlf = T.replace "\n" "\r\n"

-- | Format a notebook's markdown cells; also returns its metadata.
formatNotebookSource :: Loaded -> Text -> IO (Outcome, KM.KeyMap A.Value)
formatNotebookSource l raw = case readNotebook (TE.encodeUtf8 raw) of
  Left e -> pure (Failed e, KM.empty)
  Right nb -> fmap (,notebookMetadata nb) . forceOutcome $
    case formatNotebook opts (lCellProfile l) nb of
      Left (NotebookFailure w (PandocFailed e)) -> Failed (w <> ": " <> renderError e)
      Left f -> Rejected (named f)
      Right r
        | not (null kept) -> if out == raw then Rejected kept else PartlyChanged raw out kept
        | out == raw -> Unchanged
        | otherwise -> Changed raw out (resultAccepted r)
       where
        out = TE.decodeUtf8Lenient (resultBytes r)
        kept = concatMap named (resultKept r)
   where
    opts =
      NotebookOptions
        { nbWholeNotebookCheck = pairedWithMarkdown (notebookMetadata nb)
        }
 where
  named = \case
    NotebookFailure w (ChecksFailed _ _ ds) -> [d {diffCheck = w <> ": " <> diffCheck d} | d <- ds]
    NotebookFailure _ (PandocFailed _) -> []

forceOutcome :: Outcome -> IO Outcome
forceOutcome o = do
  outcome <- evaluate o
  case outcome of
    Rejected ds -> forceDiffs ds
    PartlyChanged _ out ds -> evaluate (T.length out) >> forceDiffs ds
    _ -> pure ()
  pure outcome
 where
  forceDiffs ds = forM_ ds $ \d -> evaluate (T.length (diffCheck d) + T.length (diffBefore d) + T.length (diffAfter d))

report :: Opts -> String -> Outcome -> IO ()
report opts name = \case
  Unchanged -> when (optVerbose opts) $ say ("unchanged " <> name)
  Changed _ _ by -> do
    say ((if optCheck opts || optDiff opts then "would reformat " else "reformatted ") <> name)
    case by of
      ChecksPassed cs
        | optVerbose opts ->
            say ("  pandoc reads it differently, but the checks render it the same: " <> T.unpack (T.intercalate ", " cs))
      _ -> pure ()
  Rejected ds -> do
    say ("rejected " <> name <> ": pandoc renders it differently after formatting (failed checks: " <> failed ds <> ")")
    diffs ds
  PartlyChanged _ _ ds -> do
    say
      ( (if optCheck opts || optDiff opts then "would partly reformat " else "partly reformatted ") <> name
          <> ": kept the cells that pandoc renders differently after formatting (failed checks: " <> failed ds <> ")"
      )
    diffs ds
  Failed e -> say ("error: " <> name <> ": " <> T.unpack e)
 where
  say = hPutStrLn stderr
  failed = T.unpack . T.intercalate ", " . map diffCheck
  diffs ds = when (optVerbose opts) $ forM_ ds $ \d ->
    TIO.hPutStr stderr $
      unifiedDiff ("check " <> diffCheck d <> ": original") ("check " <> diffCheck d <> ": formatted") (diffBefore d) (diffAfter d)

summary :: Opts -> [Outcome] -> Int -> IO ()
summary opts outcomes hookFailures =
  hPutStrLn stderr . T.unpack . T.intercalate ", " $
    [count n (if dry then "would be reformatted" else "reformatted") | let n = length [() | Changed {} <- outcomes], n > 0]
      ++ [count n (if dry then "would be left unchanged" else "left unchanged") | let n = length [() | Unchanged <- outcomes], n > 0]
      ++ [count n (if dry then "would be partly reformatted" else "partly reformatted") | let n = length [() | PartlyChanged {} <- outcomes], n > 0]
      ++ [count n "rejected" | let n = length [() | Rejected {} <- outcomes], n > 0]
      ++ [count n "failed" | let n = length [() | Failed {} <- outcomes], n > 0]
      ++ [count hookFailures "failed a hook" | hookFailures > 0]
      ++ ["no files to format" | null outcomes]
 where
  dry = optCheck opts || optDiff opts
  count n what = T.pack (show n) <> (if n == 1 then " file " else " files ") <> what

exitCodeOf :: Opts -> Outcome -> Int
exitCodeOf opts = \case
  Unchanged -> 0
  Changed {} -> if optCheck opts then 1 else 0
  Rejected {} -> 2
  PartlyChanged {} -> 2
  Failed {} -> 3

exitWith' :: Int -> IO ()
exitWith' 0 = pure ()
exitWith' n = exitWith (ExitFailure n)

-- | Map with at most @n@ actions running at once, keeping the order. The
-- action must not throw.
parMapIO :: Int -> (a -> IO b) -> [a] -> IO [b]
parMapIO n f xs = do
  sem <- newQSem n
  vars <- forM xs $ \x -> do
    v <- newEmptyMVar
    _ <- forkIO $ bracket_ (waitQSem sem) (signalQSem sem) (f x >>= putMVar v)
    pure v
  mapM takeMVar vars
