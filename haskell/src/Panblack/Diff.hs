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
          ++ concatMap hunk (getContextDiff (Just 3) (T.lines old) (T.lines new))
 where
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
