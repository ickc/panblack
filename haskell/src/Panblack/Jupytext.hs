-- | The files jupytext pairs with a notebook (see docs/design.md, "ipynb"),
-- so that panblack can warn when it formats both sides of a pair.
--
-- Mirrors jupytext's @paired_paths@ for the @jupytext.formats@ metadata of
-- the notebook: extensions, suffixes (@.pct.py@), and prefixes naming a
-- directory or a file name prefix (@scripts//py@, @../md/md@). Prefix roots
-- (@notebooks///ipynb@) and formats set in a jupytext config file are not
-- resolved; the notebook then has no known pairs.
module Panblack.Jupytext
  ( pairedPaths
  , pairedWithMarkdown
  ) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (dropExtension, joinPath, normalise, splitDirectories, takeDirectory, takeExtension, takeFileName, (</>))

data Format = Format
  { fPrefix :: String
  , fSuffix :: String
  , fExt :: String
  }

-- | The other files of the pair, from the notebook's path and metadata.
-- Empty if the notebook isn't paired, or the pairing can't be resolved.
pairedPaths :: FilePath -> KM.KeyMap Value -> [FilePath]
pairedPaths path meta = fromMaybe [] $ do
  formats <- pairedFormats meta
  if any (("//" `isInfixOf`) . fPrefix) formats
    then Nothing
    else do
      own : _ <- Just [f | f <- formats, fExt f == takeExtension path]
      base <- basePath path own
      Just [normalise (fullPath base f) | f <- formats, fExt f /= fExt own || fSuffix f /= fSuffix own || fPrefix f /= fPrefix own]

-- | Whether the notebook is paired with a markdown file, whose cells a
-- markdown reader then reads as one document.
pairedWithMarkdown :: KM.KeyMap Value -> Bool
pairedWithMarkdown meta =
  any ((`elem` [".md", ".markdown", ".Rmd", ".qmd", ".myst", ".mystnb", ".mnb"]) . fExt) (fromMaybe [] (pairedFormats meta))

-- | The formats in the notebook's @jupytext.formats@.
pairedFormats :: KM.KeyMap Value -> Maybe [Format]
pairedFormats meta = do
  Object jt <- KM.lookup "jupytext" meta
  specs <- case KM.lookup "formats" jt of
    Just (String s) -> Just (filter (not . T.null) (T.splitOn "," s))
    Just (Array xs) -> traverse (\case String s -> Just s; _ -> Nothing) (toList xs)
    _ -> Nothing
  traverse (parseFormat autoExt) specs
 where
  autoExt = case KM.lookup "language_info" meta of
    Just (Object li) | Just (String e) <- KM.lookup "file_extension" li -> Just (T.unpack e)
    _ -> Nothing

-- | As jupytext's @long_form_one_format@: @[prefix/][suffix].ext[:format]@.
parseFormat :: Maybe String -> Text -> Maybe Format
parseFormat autoExt spec0 = do
  let spec = T.unpack (fromMaybe spec0 (lookup (T.toLower spec0) commonNames))
      (prefix, rest) = case breakLast '/' spec of
        Just (p, r) | not (null p) -> (p, r)
        _ -> ("", spec)
      extPart = maybe rest fst (breakLast ':' rest)
  if null extPart && ':' `elem` rest
    then Nothing -- a format name alone
    else do
      let (suffix, ext0) = case breakLast '.' extPart of
            Just (s, e) | not (null s) -> (s, '.' : e)
            _ -> ("", if "." `isPrefixOf` extPart then extPart else '.' : extPart)
      ext <- if ext0 == ".auto" then autoExt else Just ext0
      Just (Format prefix suffix ext)
 where
  commonNames = [("notebook", "ipynb"), ("rmarkdown", "Rmd"), ("quarto", "qmd"), ("markdown", "md"), ("myst", "md:myst"), ("pandoc", "md:pandoc"), ("c++", "cpp")]

-- | The notebook's path without its own format's prefix, suffix and
-- extension.
basePath :: FilePath -> Format -> Maybe FilePath
basePath path f = do
  let base = dropExtension path
  unless' (fSuffix f `isSuffixOf` base)
  let base' = take (length base - length (fSuffix f)) base
      (pdir, pfile) = splitPrefix (fPrefix f)
      name = takeFileName base'
  unless' (pfile `isPrefixOf` name)
  let dirs = splitDirectories (takeDirectory base')
      expected = if null pdir then [] else splitDirectories pdir
  unless' (".." `notElem` expected && expected `isSuffixOf` dirs)
  Just (joinPath (take (length dirs - length expected) dirs) </> drop (length pfile) name)
 where
  unless' b = if b then Just () else Nothing

fullPath :: FilePath -> Format -> FilePath
fullPath base f = dir </> (pfile <> takeFileName base <> fSuffix f <> fExt f)
 where
  (pdir, pfile) = splitPrefix (fPrefix f)
  dir = if null pdir then takeDirectory base else takeDirectory base </> pdir

-- | A prefix's directory and file name prefix: @scripts/@ is a directory,
-- @md@ a file name prefix, @../md/pre@ both.
splitPrefix :: String -> (String, String)
splitPrefix p = fromMaybe ("", p) (breakLast '/' p)

breakLast :: Char -> String -> Maybe (String, String)
breakLast c s = case break (== c) (reverse s) of
  (_, []) -> Nothing
  (r, _ : l) -> Just (reverse l, reverse r)
