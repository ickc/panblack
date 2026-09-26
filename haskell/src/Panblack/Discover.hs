-- | Which files a profile formats.
--
-- A profile's @paths@ are relative to the config directory (the root). A
-- listed file is always included, as in 0.x; a listed directory contributes
-- the files below it with one of the profile's extensions, except those
-- matching an exclude.
--
-- Excludes are gitignore-style globs (see docs/design.md, "Config"): a
-- trailing @/@ matches directories only; a pattern with any other @/@ is
-- anchored at the root; any other pattern matches a name at any depth.
--
-- In a git repository, git decides which files a directory has: tracked
-- files and untracked ones that aren't ignored (@.gitignore@,
-- @.git/info/exclude@, the global excludes file). The excludes then apply on
-- top. Without git, or outside a repository, the directory is walked.
module Panblack.Discover
  ( Exclude
  , compileExclude
  , excluded
  , discover
  , matches
  , isUnder
  , relativeTo
  ) where

import Control.Exception (IOException, try)
import Control.Monad (filterM, forM)
import Data.ByteString qualified as B
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink)
import System.Exit (ExitCode (..))
import System.FilePath (joinPath, makeRelative, normalise, splitDirectories, takeDirectory, takeExtension, (</>))
import System.FilePath.Glob (Pattern, compDefault, match, tryCompileWith)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)

data Exclude = Exclude
  { exDirOnly :: Bool
  , exAnchored :: Bool
  , exPattern :: Pattern
  }

compileExclude :: Text -> Either String Exclude
compileExclude t = do
  let s = T.unpack t
      dirOnly = "/" `T.isSuffixOf` t
      body = T.unpack . T.dropWhile (== '/') . T.dropWhileEnd (== '/') $ t
  pat <- either (\e -> Left ("bad exclude " <> show s <> ": " <> e)) Right (tryCompileWith compDefault body)
  pure (Exclude dirOnly ('/' `elem` body) pat)

-- | Whether an entry, given as its path components relative to the root,
-- is excluded.
excluded :: [Exclude] -> Bool -> [FilePath] -> Bool
excluded exs isDir parts = any hit exs
 where
  hit ex
    | exDirOnly ex && not isDir = False
    | exAnchored ex = match (exPattern ex) (joinPath parts)
    | otherwise = not (null parts) && match (exPattern ex) (last parts)

hasExt :: [Text] -> FilePath -> Bool
hasExt exts f = case takeExtension f of
  '.' : e -> T.pack e `elem` exts
  _ -> False

-- | All files of a profile, as canonical paths. The root must be canonical.
-- A path that doesn't exist is an error.
discover :: FilePath -> [FilePath] -> [Text] -> [Exclude] -> IO (Either String [FilePath])
discover root paths exts exs = fmap concat . sequence <$> mapM one paths
 where
  one p = do
    full <- canonicalizePath (root </> p)
    isFile <- doesFileExist full
    isDir <- doesDirectoryExist full
    if
      | isFile -> pure (Right [full])
      | isDir -> Right <$> (gitFiles full >>= maybe (walk full) (filterM keep))
      | otherwise -> pure (Left (full <> ": no such file or directory"))
  -- git lists deleted files that are still in the index, and submodules.
  keep f
    | hasExt exts f && not (excludedOnTheWay exs (relParts f)) = doesFileExist f
    | otherwise = pure False
  walk dir = do
    entries <- map (dir </>) . sort <$> listDirectory dir
    fmap concat . forM entries $ \e -> do
      isDir <- doesDirectoryExist e
      link <- pathIsSymbolicLink e
      let parts = relParts e
      if
        | excluded exs isDir parts -> pure []
        | isDir -> if link then pure [] else walk e
        | hasExt exts e -> pure [e]
        | otherwise -> pure []
  relParts = splitDirectories . makeRelative (normalise root)

-- | Whether a profile covers a file that may not have been discovered, such
-- as one named on the command line or @--stdin-filename@. The root and the
-- file must be canonical.
matches :: FilePath -> [FilePath] -> [Text] -> [Exclude] -> FilePath -> IO Bool
matches root paths exts exs file = do
  fulls <- mapM (canonicalizePath . (root </>)) paths
  if
    | file `elem` fulls -> pure True
    | not (hasExt exts file) -> pure False
    | otherwise -> do
        dirs <- filterM doesDirectoryExist [p | p <- fulls, file `isUnder` p]
        if null dirs || excludedOnTheWay exs (splitDirectories (makeRelative root file))
          then pure False
          else not <$> gitIgnored file

-- | Whether any directory on the way to a file, or the file itself, is
-- excluded.
excludedOnTheWay :: [Exclude] -> [FilePath] -> Bool
excludedOnTheWay exs parts =
  or [excluded exs True (take n parts) | n <- [1 .. length parts - 1]]
    || excluded exs False parts

-- | The files git lists below a directory: tracked, or untracked and not
-- ignored. Nothing if git is missing or the directory isn't in a
-- repository.
gitFiles :: FilePath -> IO (Maybe [FilePath])
gitFiles dir = do
  r <- git ["-C", dir, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
  pure $ case r of
    Just (ExitSuccess, out) -> Just (sort [dir </> T.unpack (TE.decodeUtf8Lenient p) | p <- B.split 0 out, not (B.null p)])
    _ -> Nothing

-- | Whether git ignores a file (never when it's tracked). False if git is
-- missing or the file isn't in a repository.
gitIgnored :: FilePath -> IO Bool
gitIgnored file = do
  r <- git ["-C", takeDirectory file, "check-ignore", "-q", "--", file]
  pure $ case r of
    Just (ExitSuccess, _) -> True
    _ -> False

-- | Run git, returning its exit code and stdout; Nothing if it can't run.
git :: [String] -> IO (Maybe (ExitCode, B.ByteString))
git args = either (\(_ :: IOException) -> Nothing) Just <$> try run
 where
  run = withCreateProcess (proc "git" args) {std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe} $ \_ out err p -> do
    bytes <- maybe (pure B.empty) B.hGetContents out
    _ <- maybe (pure B.empty) B.hGetContents err
    (,bytes) <$> waitForProcess p

-- | Whether a path is the given directory or below it (both canonical).
isUnder :: FilePath -> FilePath -> Bool
isUnder file dir = splitDirectories dir `isPrefixOf` splitDirectories file

-- | A path relative to a directory, going up with @..@ if needed (both
-- canonical).
relativeTo :: FilePath -> FilePath -> FilePath
relativeTo dir path = case replicate (length d - common) ".." ++ drop common p of
  [] -> "."
  parts -> joinPath parts
 where
  d = splitDirectories dir
  p = splitDirectories path
  common = length (takeWhile id (zipWith (==) d p))
