-- | A cache of accepted files, as black has (see docs/design.md, "Cache").
--
-- Each profile has its own cache file, named by a key that covers
-- everything a run depends on besides the file's content: the panblack and
-- pandoc versions and the profile's resolved settings. The file maps each
-- path to the SHA-256 of its content when it was last accepted, with its
-- hooks run. A file whose content still has that digest is skipped.
--
-- The cache is only an optimization, so reading or writing it never fails
-- a run: a cache that can't be read is empty, and one that can't be written
-- is left as it was.
module Panblack.Cache
  ( Cache
  , cacheKey
  , loadCache
  , noCache
  , isCached
  , Entry (..)
  , saveCache
  , digest
  ) where

import Control.Exception (SomeException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (XdgDirectory (..), createDirectoryIfMissing, getXdgDirectory, removeFile, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, openBinaryTempFile)

data Cache = Cache
  { cacheFile :: Maybe FilePath
  -- ^ Nothing: caching is off.
  , cacheEntries :: M.Map FilePath Text
  }

-- | What to do with a file's entry after a run.
data Entry
  = Keep
  | Record Text
  -- ^ Accepted with this digest.
  | Forget

-- | The SHA-256 of some bytes, in hex.
digest :: ByteString -> Text
digest bs = T.pack (show (hash bs :: Digest SHA256))

-- | A cache key: the digest of a description of everything, besides a
-- file's content, that the result depends on.
cacheKey :: String -> Text
cacheKey = digest . TE.encodeUtf8 . T.pack

noCache :: Cache
noCache = Cache Nothing M.empty

-- | The cache for a key, in @$XDG_CACHE_HOME/panblack@.
loadCache :: Text -> IO Cache
loadCache key = do
  r <- try $ do
    dir <- getXdgDirectory XdgCache "panblack"
    let f = dir </> T.unpack key <> ".json"
    bytes <- try @SomeException (B.readFile f)
    pure (Cache (Just f) (either (const M.empty) (fromMaybe M.empty . A.decodeStrict) bytes))
  pure (either (\(_ :: SomeException) -> noCache) id r)

isCached :: Cache -> FilePath -> ByteString -> Bool
isCached c f bytes = case M.lookup f (cacheEntries c) of
  Just d -> isJust (cacheFile c) && d == digest bytes
  Nothing -> False

-- | Apply the entries of a run and write the cache back, atomically, if
-- anything changed.
saveCache :: Cache -> [(FilePath, Entry)] -> IO ()
saveCache c updates = case cacheFile c of
  Nothing -> pure ()
  Just f | new /= cacheEntries c -> do
    _ <- try @SomeException $ do
      let dir = takeDirectory f
      createDirectoryIfMissing True dir
      (tmp, h) <- openBinaryTempFile dir "cache.json"
      r <- try @SomeException (B.hPut h (B.toStrict (A.encode new)) >> hClose h >> renameFile tmp f)
      either (\_ -> hClose h >> removeFile tmp) pure r
    pure ()
  Just _ -> pure ()
 where
  new = foldl' apply (cacheEntries c) updates
  apply m (p, e) = case e of
    Keep -> m
    Record d -> M.insert p d m
    Forget -> M.delete p m
