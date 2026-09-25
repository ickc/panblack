{-# LANGUAGE CPP #-}

-- | Editor build spike: format stdin to stdout with a fixed profile. Built
-- twice, as the "md" tier (source check only) and, with -DWITH_HTML, the
-- "md+html" tier. Only concrete readers and writers are imported, so the
-- linker can drop every other format.
module Main (main) where

import Data.Text.IO qualified as TIO
import Panblack.Guard
import Panblack.Markdown (markdownProfile)
#ifdef WITH_HTML
import Panblack.Target.Html (htmlCheck)
#endif
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import Text.Pandoc.Options

main :: IO ()
main = do
  let wopts = def {writerWrapText = WrapPreserve, writerColumns = 120}
      base = either (error . show) id (markdownProfile "markdown" "markdown" def wopts)
#ifdef WITH_HTML
      profile = base {profileChecks = [sourceCheck base, htmlCheck]}
#else
      profile = base {profileChecks = [sourceCheck base]}
#endif
  src <- TIO.getContents
  case format profile src of
    Right f -> TIO.putStr (formattedText f)
    Left (PandocFailed e) -> hPutStrLn stderr (show e) >> exitWith (ExitFailure 3)
    Left (ChecksFailed _ _ ds) -> do
      hPutStrLn stderr ("rejected by: " <> unwords (map (show . diffCheck) ds))
      exitWith (ExitFailure 2)
