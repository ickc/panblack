-- | AST normalizations, applied right after every read (see docs/design.md,
-- "Normalizations").
--
-- Each one gives up pandoc-relative equality in one stated way, so each is
-- opt-in. Wrapping a profile's reader with 'normalizing' applies it to the
-- original and the formatted source alike: the checks compare normalized
-- documents, and the output is written from a normalized AST.
module Panblack.Normalize
  ( Normalization (..)
  , normalizationName
  , normalizationByName
  , normalize
  , normalizing
  ) where

import Data.Char (isSpace)
import Data.List (dropWhileEnd)
import Data.Text (Text)
import Data.Text qualified as T
import Panblack.Guard (Profile (..))
import Text.Pandoc.Definition
import Text.Pandoc.Walk (walk)

data Normalization
  = -- | Every column width becomes the default.
    TableWidths
  | -- | Soft line breaks inside table cells become spaces.
    TableCellBreaks
  | -- | Leading and trailing blank lines of code blocks are dropped.
    CodeBlockBlankLines
  | -- | A 'Plain' directly inside a 'Div' becomes a 'Para'.
    DivBareText
  | -- | Raw HTML blocks holding only an empty comment, @<!-- -->@, are dropped.
    EmptyComments
  deriving stock (Eq, Ord, Show, Enum, Bounded)

normalizationName :: Normalization -> Text
normalizationName = \case
  TableWidths -> "table-widths"
  TableCellBreaks -> "table-cell-breaks"
  CodeBlockBlankLines -> "code-block-blank-lines"
  DivBareText -> "div-bare-text"
  EmptyComments -> "empty-comments"

normalizationByName :: Text -> Maybe Normalization
normalizationByName name =
  lookup name [(normalizationName n, n) | n <- [minBound .. maxBound]]

-- | Apply the given normalizations. They are independent, so the order and
-- repetitions in the list don't matter.
normalize :: [Normalization] -> Pandoc -> Pandoc
normalize ns doc = foldr apply doc [n | n <- [minBound .. maxBound], n `elem` ns]

-- | Normalize everything the profile reads.
normalizing :: [Normalization] -> Profile -> Profile
normalizing [] profile = profile
normalizing ns profile = profile {profileRead = fmap (normalize ns) . profileRead profile}

apply :: Normalization -> Pandoc -> Pandoc
apply = \case
  TableWidths -> walk $ \case
    Table attr caption specs th tbs tf ->
      Table attr caption [(align, ColWidthDefault) | (align, _) <- specs] th tbs tf
    b -> b
  -- Cells only: a caption is a paragraph, which the writer breaks correctly.
  TableCellBreaks -> walk $ \case
    Table attr caption specs th tbs tf ->
      Table attr caption specs (walk softBreak th) (walk softBreak tbs) (walk softBreak tf)
    b -> b
  CodeBlockBlankLines -> walk $ \case
    CodeBlock attr code -> CodeBlock attr (stripBlankLines code)
    b -> b
  DivBareText -> walk $ \case
    Div attr blocks -> Div attr (map plainToPara blocks)
    b -> b
  EmptyComments -> walk (filter (not . isEmptyComment))
 where
  softBreak SoftBreak = Space
  softBreak i = i
  plainToPara (Plain is) = Para is
  plainToPara b = b
  stripBlankLines =
    T.intercalate "\n" . dropWhileEnd blank . dropWhile blank . T.splitOn "\n"
  blank = T.all isSpace
  isEmptyComment = \case
    RawBlock f t
      | f == Format "html"
      , Just inner <- T.stripPrefix "<!--" (T.strip t) >>= T.stripSuffix "-->" ->
          T.all isSpace inner
    _ -> False
