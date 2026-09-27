-- | Checks by target name, through pandoc's writer registry. For the CLI, which
-- bundles all of pandoc anyway.
module Panblack.Target.Registry
  ( targetByName
  ) where

import Control.Monad.Except (throwError)
import Data.Text (Text)
import Panblack.Guard (Check (..))
import Panblack.Target.Html (targetOptions)
import Text.Pandoc.Class (runPure)
import Text.Pandoc.Error (PandocError (..))
import Text.Pandoc.Format (FlavoredFormat (..), parseFlavoredFormat)
import Text.Pandoc.Options (WriterOptions (..))
import Text.Pandoc.Writers (Writer (..), getWriter)

-- | A check from a pandoc format spec such as @html@ or @latex-smart@.
targetByName :: Text -> Either PandocError Check
targetByName spec = runPure $ do
  flavored <- parseFlavoredFormat spec
  (writer, exts) <- getWriter flavored
  let opts = (targetOptions (formatName flavored)) {writerExtensions = exts}
  case writer of
    TextWriter w -> pure $ Check spec (w opts)
    ByteStringWriter _ ->
      throwError . PandocAppError $ "binary target formats are not supported: " <> spec
