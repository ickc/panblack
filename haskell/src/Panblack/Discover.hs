-- | Which files a profile formats.
--
-- A profile's @paths@ are relative to the config directory (the root). A
-- listed file is always included, as in 0.x; a listed directory contributes
-- the files below it with one of the profile's extensions, except those
-- matching an exclude.
--
-- Excludes are gitignore-style globs (see docs/design.md, "Open questions"):
-- a trailing @/@ matches directories only; a pattern with any other @/@ is
-- anchored at the root; any other pattern matches a name at any depth.
-- @.gitignore@ files are not read yet.
module Panblack.Discover
  ( Exclude
  , compileExclude
  , excluded
  , discover
  , matches
  , isUnder
  , relativeTo
  ) where

import Control.Monad (filterM, forM)
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink)
import System.FilePath (joinPath, makeRelative, normalise, splitDirectories, takeExtension, (</>))
import System.FilePath.Glob (Pattern, compDefault, match, tryCompileWith)

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
      | isDir -> Right <$> walk full
      | otherwise -> pure (Left (full <> ": no such file or directory"))
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
        pure $ not (null dirs) && not (excludedOnTheWay (splitDirectories (makeRelative root file)))
 where
  -- Every directory on the way to the file, then the file itself.
  excludedOnTheWay parts =
    or [excluded exs True (take n parts) | n <- [1 .. length parts - 1]]
      || excluded exs False parts

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
