-- | The format-and-guard pipeline, independent of any source format.
--
-- A 'Profile' supplies a reader, a writer and a list of checks. 'format'
-- writes the source out once and accepts the result only if every check
-- renders the original and the formatted source identically (see
-- docs/design.md, "Guard algorithm"). This mirrors 0.x's
-- @require_idempotence_format@.
--
-- Everything runs in 'PandocPure': no IO, deterministic, sandboxed.
module Panblack.Guard
  ( Profile (..)
  , Check (..)
  , sourceCheck
  , Accepted (..)
  , Formatted (..)
  , GuardFailure (..)
  , CheckDiff (..)
  , format
  , compareSources
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Text.Pandoc.Class (PandocPure, runPure)
import Text.Pandoc.Definition (Pandoc)
import Text.Pandoc.Error (PandocError)

-- | A check renders a document; it passes when the original and the
-- formatted source render the same.
data Check = Check
  { checkName :: Text
  , checkRender :: Pandoc -> PandocPure Text
  }

data Profile = Profile
  { profileRead :: Text -> PandocPure Pandoc
  , profileWrite :: Pandoc -> PandocPure Text
  , profileChecks :: [Check]
  -- ^ All must pass. Empty means the output is always accepted, as in 0.x.
  }

-- | The check named @source@: render with the profile's own writer. Since
-- @write (parse src)@ is the formatted output, this checks stability,
-- @fmt (fmt x) == fmt x@ (0.x's @"input_format"@ entry).
sourceCheck :: Profile -> Check
sourceCheck profile = Check "source" (profileWrite profile)

-- | Why the output was accepted.
data Accepted
  = AstEqual
  -- ^ pandoc reads both the same, so every check passes without running it.
  | ChecksPassed [Text]
  deriving stock (Eq, Show)

data Formatted = Formatted
  { formattedText :: Text
  , formattedBy :: Accepted
  }
  deriving stock (Eq, Show)

data CheckDiff = CheckDiff
  { diffCheck :: Text
  , diffBefore :: Text
  , diffAfter :: Text
  }
  deriving stock (Eq, Show)

data GuardFailure
  = PandocFailed PandocError
  | ChecksFailed
      { failBefore :: Pandoc
      , failAfter :: Pandoc
      , failDiffs :: [CheckDiff]
      -- ^ Only the checks that failed.
      }
  deriving stock (Show)

-- | Format a source, or explain why the result can't be trusted.
format :: Profile -> Text -> Either GuardFailure Formatted
format profile src = either (Left . PandocFailed) id . runPure $ do
  before <- profileRead profile src
  out <- profileWrite profile before
  fmap (Formatted out) <$> judge profile before out

-- | Whether pandoc reads a second source the same as the first, as seen by
-- every check. For a result assembled from parts, such as the markdown cells
-- of a notebook, which must pass as a whole.
compareSources :: Profile -> Text -> Text -> Either GuardFailure Accepted
compareSources profile src out = either (Left . PandocFailed) id . runPure $ do
  before <- profileRead profile src
  judge profile before out

judge :: Profile -> Pandoc -> Text -> PandocPure (Either GuardFailure Accepted)
judge profile before out = do
  after <- profileRead profile out
  if before == after
    then pure (Right AstEqual)
    else do
      diffs <- traverse (renderBoth after) checks
      pure $ case [d | d <- diffs, diffBefore d /= diffAfter d] of
        [] -> Right . ChecksPassed $ map checkName checks
        failed -> Left $ ChecksFailed before after failed
 where
  checks = profileChecks profile
  -- 0.x compared renders with surrounding whitespace stripped.
  renderBoth after c =
    CheckDiff (checkName c)
      <$> (T.strip <$> checkRender c before)
      <*> (T.strip <$> checkRender c after)
