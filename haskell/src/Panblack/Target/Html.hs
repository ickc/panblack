-- | The HTML check, imported directly so the editor build doesn't pull in
-- pandoc's writer registry.
module Panblack.Target.Html
  ( htmlCheck
  , targetOptions
  ) where

import Data.Text (Text)
import Panblack.Guard (Check (..))
import Panblack.Markdown (compileTemplateText)
import Text.Pandoc.Extensions (getDefaultExtensions)
import Text.Pandoc.Options (WrapOption (..), WriterOptions (..), def)
import Text.Pandoc.Writers.HTML (writeHtml5String)

htmlCheck :: Check
htmlCheck = Check "html" (writeHtml5String (targetOptions "html"))

-- | Options for rendering a check target. A check asks whether pandoc
-- understands the formatted source the same way, seen through a target
-- format; it is not the user's own output configuration. So these are
-- pandoc's defaults for the target, independent of the profile's options,
-- except that:
--
-- * the template is the metadata (all of it, rendered by the target writer)
--   plus the body, rather than a standalone template that shows only some
--   metadata fields;
-- * line wrapping is off, since where the target breaks lines doesn't
--   change what it means.
targetOptions :: Text -> WriterOptions
targetOptions name =
  def
    { writerExtensions = getDefaultExtensions name
    , writerTemplate = Just (compileTemplateText "$meta-json$\n$body$\n")
    , writerWrapText = WrapNone
    }
