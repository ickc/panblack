-- | Unified diffs, as printed by @diff -u@.
module Panblack.Diff
  ( unifiedDiff
  ) where

import Data.Algorithm.Diff (PolyDiff (..))
import Data.Algorithm.DiffContext (Numbered (..), getContextDiff)
import Data.Text (Text)
import Data.Text qualified as T

-- | A unified diff with three lines of context, empty if the texts are equal.
unifiedDiff :: Text -> Text -> Text -> Text -> Text
unifiedDiff oldName newName old new
  | old == new = ""
  | otherwise =
      T.unlines $
        ["--- " <> oldName, "+++ " <> newName]
          ++ concatMap hunk (getContextDiff (Just 3) (lines' old) (lines' new))
 where
  -- A last line without a newline carries diff's marker, so it differs from
  -- the same line with one.
  lines' t
    | T.null t || "\n" `T.isSuffixOf` t = T.lines t
    | otherwise = let ls = T.lines t in init ls ++ [last ls <> "\n\\ No newline at end of file"]
  hunk h =
    ("@@ -" <> range [n | d <- h, n <- olds d] <> " +" <> range [n | d <- h, n <- news d] <> " @@")
      : concatMap line h
  olds = \case
    Both xs _ -> nums xs
    First xs -> nums xs
    Second _ -> []
  news = \case
    Both _ ys -> nums ys
    First _ -> []
    Second ys -> nums ys
  nums = map (\(Numbered n _) -> n)
  line = \case
    Both xs _ -> map ((" " <>) . unnum) xs
    First xs -> map (("-" <>) . unnum) xs
    Second ys -> map (("+" <>) . unnum) ys
  unnum (Numbered _ t) = t
  range = \case
    [] -> "0,0"
    [n] -> T.pack (show n)
    ns@(n : _) -> T.pack (show n <> "," <> show (length ns))
