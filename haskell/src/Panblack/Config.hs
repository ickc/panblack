-- | The @.panblack.yaml@ config: a list of profiles (see docs/design.md,
-- "Config").
--
-- A profile's @pandoc:@ key is an inline pandoc defaults file and is parsed
-- by pandoc itself, after checking that it only uses options that make sense
-- for a formatter (docs/design.md, "Formatter options").
module Panblack.Config
  ( ProfileConfig (..)
  , defaultProfileConfig
  , parseConfig
  , Settings (..)
  , loadSettings
  , buildProfile
  , buildProfileWith
  , sourceText
  , withLineEnding
  , pandocKeys
  , starterConfig
  ) where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Aeson (Object, Value (..), (.!=), (.:?))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Y
import Panblack.Guard (Check, Profile (..), sourceCheck)
import Panblack.Markdown (markdownProfile)
import Panblack.Normalize (Normalization, normalizationByName, normalizationName, normalizing)
import Panblack.Target.Registry (targetByName)
import System.FilePath ((</>))
import System.IO qualified as IO
import Text.Pandoc.App (LineEnding (..), Opt (..), defaultOpts)
import Text.Pandoc.Class (runIO)
import Text.Pandoc.Data (readDataFile)
import Text.Pandoc.Error (PandocError, renderError)
import Text.Pandoc.Options (ReaderOptions (..), WriterOptions (..), def)

data ProfileConfig = ProfileConfig
  { pcPaths :: [FilePath]
  , pcExts :: [Text]
  , pcExcludes :: [Text]
  , pcCheck :: [Text]
  -- ^ All must pass; empty accepts anything (0.x's @require_idempotence_format@).
  , pcNormalize :: [Normalization]
  , pcDefaults :: Maybe FilePath
  -- ^ A pandoc defaults file, relative to the config file. The inline
  -- 'pcPandoc' keys override it.
  , pcPandoc :: Object
  , pcCellFormat :: Text
  -- ^ The markdown flavour of notebook cells; @pandoc.from@ and @to@ are
  -- for the other files.
  , pcHooks :: [[Text]]
  -- ^ Commands run on each accepted file, @{path}@ substituted.
  }
  deriving stock (Eq, Show)

-- | The defaults: 0.x's, plus every normalization. Also used when there is
-- no config file.
defaultProfileConfig :: ProfileConfig
defaultProfileConfig =
  ProfileConfig
    { pcPaths = []
    , pcExts = ["md", "markdown"]
    , pcExcludes = [".git/", ".pytest_cache/"]
    , pcCheck = ["source"]
    , pcNormalize = [minBound .. maxBound]
    , pcDefaults = Nothing
    , pcPandoc = KM.empty
    , pcCellFormat = "gfm-tex_math_gfm"
    , pcHooks = []
    }

-- | Parse a config file's contents. Unknown keys are errors.
parseConfig :: ByteString -> Either Text [ProfileConfig]
parseConfig bs = do
  v <- first (T.pack . Y.prettyPrintParseException) (Y.decodeEither' bs)
  first aesonError $ parseEither parseProfiles v
 where
  parseProfiles = A.withArray "list of profiles" $ \arr ->
    traverse (uncurry parseProfile) (zip [1 :: Int ..] (foldr (:) [] arr))
  d = defaultProfileConfig
  parseProfile i = A.withObject ("profile " <> show i) $ \o -> do
    let where' = "profile " <> show i <> ": "
    unknownKeys where' profileKeys o
    paths <- o .:? "paths" .!= []
    normalize <- o .:? "normalize" >>= maybe (pure (pcNormalize d)) (traverse (normalizationNamed where'))
    pandoc <- o .:? "pandoc" .!= KM.empty
    unknownKeys (where' <> "pandoc: ") pandocKeys pandoc
    ipynb <- o .:? "ipynb" .!= KM.empty
    unknownKeys (where' <> "ipynb: ") ["cell-format"] ipynb
    hooks <- o .:? "hooks" .!= []
    when (any null hooks) $ fail (where' <> "hooks: a command can't be empty")
    ProfileConfig paths
      <$> o .:? "exts" .!= pcExts d
      <*> o .:? "excludes" .!= pcExcludes d
      <*> o .:? "check" .!= pcCheck d
      <*> pure normalize
      <*> o .:? "defaults"
      <*> pure pandoc
      <*> ipynb .:? "cell-format" .!= pcCellFormat d
      <*> pure hooks
  normalizationNamed where' name =
    maybe
      ( fail $
          where' <> "unknown normalization " <> show name <> "; expected one of "
            <> T.unpack (T.intercalate ", " (map normalizationName [minBound .. maxBound]))
      )
      pure
      (normalizationByName name)

profileKeys :: [Text]
profileKeys = ["paths", "exts", "excludes", "check", "normalize", "defaults", "pandoc", "ipynb", "hooks"]

-- | The pandoc options a profile may set: those that change how the source
-- is read, or how the writer spells the document. Anything else (output
-- files, filters, templates, ...) is rejected.
pandocKeys :: [Text]
pandocKeys =
  [ -- reading
    "from"
  , "reader"
  , "columns"
  , "tab-stop"
  , "indented-code-classes"
  , "abbreviations"
  , -- writing
    "to"
  , "writer"
  , "wrap"
  , "markdown-headings"
  , "reference-links"
  , "reference-location"
  , "ascii"
  , "eol"
  ]

-- | aeson's errors, without the JSON path: ours say where they are.
aesonError :: String -> Text
aesonError e = let t = T.pack e in fromMaybe t (T.stripPrefix "Error in $: " t)

unknownKeys :: String -> [Text] -> Object -> Parser ()
unknownKeys where' allowed o =
  case [K.toText k | k <- KM.keys o, K.toText k `notElem` allowed] of
    [] -> pure ()
    ks ->
      fail $
        where' <> "unsupported key(s) " <> T.unpack (T.intercalate ", " ks)
          <> "; expected one of " <> T.unpack (T.intercalate ", " allowed)

-- | Everything needed to build a 'Profile', resolved from pandoc's options.
data Settings = Settings
  { setFrom :: Text
  , setTo :: Text
  , setReader :: ReaderOptions
  , setWriter :: WriterOptions
  , setEol :: LineEnding
  }
  deriving stock (Show)

-- | Resolve a profile's pandoc options: read its defaults file, if any, and
-- the abbreviations file, if any, both relative to the config directory.
loadSettings :: FilePath -> ProfileConfig -> IO (Either Text Settings)
loadSettings root pc = do
  fromFile <- case pcDefaults pc of
    Nothing -> pure (Right KM.empty)
    Just path -> do
      r <- readFileE (root </> path)
      pure $ do
        bs <- r
        v <- first (T.pack . Y.prettyPrintParseException) (Y.decodeEither' bs)
        first aesonError $ flip parseEither v $ A.withObject "pandoc defaults file" $ \o ->
          o <$ unknownKeys (path <> ": ") pandocKeys o
  case fromFile >>= optsFrom . (pcPandoc pc `KM.union`) of
    Left e -> pure (Left e)
    Right opt -> do
      -- Like pandoc's CLI: its @abbreviations@ data file (longer than the
      -- reader's built-in default list), unless a file is given.
      abbrevs <-
        fmap (Set.fromList . filter (not . T.null) . T.lines . TE.decodeUtf8Lenient) <$> case optAbbreviations opt of
          Nothing -> first renderError <$> runIO (readDataFile "abbreviations")
          Just path -> readFileE (root </> path)
      pure $ settings opt <$> abbrevs
 where
  optsFrom o = first aesonError $ ($ defaultOpts) <$> parseEither A.parseJSON (Object o)
  readFileE path = first (\e -> T.pack (show (e :: IOException))) <$> try (B.readFile path)
  settings opt abbrevs =
    let from = fromMaybe "markdown" (optFrom opt)
     in Settings
          { setFrom = from
          , setTo = fromMaybe from (optTo opt)
          , setReader =
              def
                { readerTabStop = optTabStop opt
                , readerIndentedCodeClasses = optIndentedCodeClasses opt
                , readerAbbreviations = abbrevs
                }
          , setWriter =
              def
                { writerWrapText = optWrap opt
                , writerColumns = optColumns opt
                , writerTabStop = optTabStop opt
                , writerSetextHeaders = optSetextHeaders opt
                , writerReferenceLinks = optReferenceLinks opt
                , writerReferenceLocation = optReferenceLocation opt
                , writerPreferAscii = optAscii opt
                }
          , setEol = optEol opt
          }

-- | The profile to format with: reader and writer, normalizations, checks.
buildProfile :: Settings -> [Text] -> [Normalization] -> Either PandocError Profile
buildProfile = buildProfileWith targetByName

-- | 'buildProfile' with the given lookup for the checks other than
-- @source@. A build that doesn't call 'targetByName' leaves pandoc's writer
-- registry out.
buildProfileWith :: (Text -> Either PandocError Check) -> Settings -> [Text] -> [Normalization] -> Either PandocError Profile
buildProfileWith target s checks ns = do
  base <- normalizing ns <$> markdownProfile (setFrom s) (setTo s) (setReader s) (setWriter s)
  cs <- traverse (\c -> if c == "source" then Right (sourceCheck base) else target c) checks
  pure base {profileChecks = cs}

-- | The source to format, as pandoc's CLI reads it: without a byte order
-- mark or carriage returns.
sourceText :: Text -> Text
sourceText raw = T.filter (/= '\r') (fromMaybe raw (T.stripPrefix "\xFEFF" raw))

-- | Formatted text with the profile's line endings.
withLineEnding :: LineEnding -> Text -> Text
withLineEnding = \case
  CRLF -> crlf
  Native | IO.nativeNewline == IO.CRLF -> crlf
  _ -> id
 where
  crlf = T.replace "\n" "\r\n"

-- | What @panblack init@ prints: the recommended defaults for markdown.
starterConfig :: Text
starterConfig =
  T.unlines
    [ "# panblack config: a list of profiles; each file is formatted by the one"
    , "# profile whose paths, exts and excludes match it."
    , "- paths: [.]"
    , "  exts: [md, markdown]"
    , "  excludes: [.git/]"
    , "  # A file is written only if pandoc renders it the same before and after"
    , "  # for every check. `source` means a second run changes nothing."
    , "  check: [source, html]"
    , "  # Normalizations each accept one kind of change to your own pandoc output."
    , "  # All are on by default; list the ones you want, or [] for none:"
    , "  # normalize: [" <> T.intercalate ", " (map normalizationName [minBound .. maxBound]) <> "]"
    , "  # An inline pandoc defaults file. Reading options must match how you run"
    , "  # pandoc, except smart and latex_macros: formatting without them keeps your"
    , "  # text and macros as typed. Without raw_attribute, the writer keeps raw TeX"
    , "  # and HTML as typed rather than wrapping them in `...`{=tex}."
    , "  pandoc:"
    , "    from: markdown-simple_tables-multiline_tables-smart-latex_macros"
    , "    to: markdown-simple_tables-multiline_tables-smart-latex_macros-raw_attribute"
    , "    wrap: preserve"
    , "    columns: 72"
    ]

