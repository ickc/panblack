-- | Markdown flavours as a 'Profile'.
--
-- Readers and writers are imported directly rather than through pandoc's
-- registries, so a build that only needs markdown can drop the other formats
-- at link time.
module Panblack.Markdown
  ( markdownProfile
  , markdownFlavours
  , compileTemplateText
  ) where

import Control.Monad (unless)
import Control.Monad.Except (throwError)
import Data.Functor.Identity (runIdentity)
import Data.Text (Text)
import Data.Text qualified as T
import Panblack.Guard (Profile (..))
import Text.DocTemplates (Template, compileTemplate)
import Text.Pandoc.Class (PandocPure, runPure)
import Text.Pandoc.Definition (Pandoc)
import Text.Pandoc.Error (PandocError (..))
import Text.Pandoc.Format (FlavoredFormat (..), applyExtensionsDiff, getExtensionsConfig, parseFlavoredFormat)
import Text.Pandoc.Options (ReaderOptions (..), WriterOptions (..))
import Text.Pandoc.Readers.CommonMark (readCommonMark)
import Text.Pandoc.Readers.Markdown (readMarkdown)
import Text.Pandoc.Writers.Markdown (writeCommonMark, writeMarkdown)

type Reader = ReaderOptions -> Text -> PandocPure Pandoc

type Writer = WriterOptions -> Pandoc -> PandocPure Text

-- | Supported format names, mirroring pandoc's reader and writer tables.
markdownFlavours :: [(Text, (Reader, Writer))]
markdownFlavours =
  [ (name, (readMarkdown, writeMarkdown))
  | name <- ["markdown", "markdown_strict", "markdown_phpextra", "markdown_github", "markdown_mmd"]
  ]
    ++ [ (name, (readCommonMark, writeCommonMark))
       | name <- ["commonmark", "commonmark_x", "gfm"]
       ]

-- | The same shape as 0.x's template: keep the title block, drop the rest of
-- pandoc's standalone markdown template (e.g. a generated table of contents).
markdownTemplate :: Text
markdownTemplate = "$if(titleblock)$\n$titleblock$\n\n$endif$\n$body$\n"

compileTemplateText :: Text -> Template Text
compileTemplateText t =
  either (error . ("panblack: bad built-in template: " <>)) id . runIdentity $
    compileTemplate "" t

-- | Build a profile from pandoc format specs for reading and writing, such
-- as @markdown-raw_attribute+east_asian_line_breaks@. Both must be the same
-- markdown flavour; the extensions may differ (e.g. to write only pipe
-- tables while still reading every table syntax). The specs' extensions
-- replace those in the given options, and the reader's columns follow the
-- writer's, as with the pandoc CLI's @--columns@ (the reader uses them to
-- decide relative table column widths). The profile has no checks; add them
-- with 'profileChecks'.
markdownProfile :: Text -> Text -> ReaderOptions -> WriterOptions -> Either PandocError Profile
markdownProfile from to ropts wopts = runPure $ do
  fromFlavored <- parseFlavoredFormat from
  toFlavored <- parseFlavoredFormat to
  let name = formatName fromFlavored
  unless (formatName toFlavored == name) $
    throwError . PandocAppError $
      "reader and writer must be the same flavour: " <> from <> " vs " <> to
  (reader, writer) <-
    maybe (unknown name) pure $ lookup name markdownFlavours
  readExts <- applyExtensionsDiff (getExtensionsConfig name) fromFlavored
  writeExts <- applyExtensionsDiff (getExtensionsConfig name) toFlavored
  let ropts' = ropts {readerExtensions = readExts, readerColumns = writerColumns wopts}
      wopts' =
        wopts
          { writerExtensions = writeExts
          , writerTemplate = Just (compileTemplateText markdownTemplate)
          }
  pure
    Profile
      { profileRead = reader ropts'
      , profileWrite = writer wopts'
      , profileChecks = []
      }
 where
  unknown name =
    throwError . PandocAppError $
      "unsupported format " <> name <> "; expected one of "
        <> T.intercalate ", " (map fst markdownFlavours)
