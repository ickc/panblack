module Main (main) where

import Control.Monad (unless)
import Data.IORef
import Panblack.Guard
import Panblack.Markdown (markdownProfile)
import Panblack.Target.Html (htmlCheck)
import System.Exit (exitFailure)
import Text.Pandoc.Options (def)
import Text.Pandoc.Readers.Markdown (readMarkdown)
import Text.Pandoc.Writers.Markdown (writeMarkdown)

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let check name ok = unless ok $ do
        putStrLn ("FAIL: " <> name)
        modifyIORef failures (+ 1)
      base = either (error . show) id (markdownProfile "markdown" "markdown" def def)
      md = base {profileChecks = [sourceCheck base, htmlCheck]}
      markdown = Profile (readMarkdown def) (writeMarkdown def) []
      withChecks p cs = p {profileChecks = cs}
      constCheck = Check "const" (const (pure ""))
      dropping = markdown {profileWrite = const (pure "")}
      drifting = markdown {profileWrite = fmap (<> " x") . writeMarkdown def}

  check "formatted input is unchanged" $
    textOf (format md "# Title\n\nSome *text*.\n") == Just "# Title\n\nSome *text*.\n"
  check "style is normalized, AST-equal" $
    format md "Title\n=====\n\n_a_\n" `eq` Right (Formatted "# Title\n\n*a*\n" AstEqual)
  check "title block becomes YAML, as with the pandoc CLI" $
    textOf (format md "% T\n\nx\n") == Just "---\ntitle: T\n---\n\nx\n"
  check "writer that drops content fails the html check" $
    failedChecks (format (withChecks dropping [htmlCheck]) "a\n") == ["html"]
  check "no checks accepts anything, as in 0.x" $
    format dropping "a\n" `eq` Right (Formatted "" (ChecksPassed []))
  check "AST change with passing checks is accepted" $
    format (withChecks markdown {profileWrite = const (pure "b\n")} [constCheck]) "a\n"
      `eq` Right (Formatted "b\n" (ChecksPassed ["const"]))
  check "drifting writer fails the source check" $
    failedChecks (format (withChecks drifting [sourceCheck drifting]) "a\n") == ["source"]

  n <- readIORef failures
  if n == 0 then putStrLn "all passed" else exitFailure
 where
  eq :: Either GuardFailure Formatted -> Either GuardFailure Formatted -> Bool
  eq (Right a) (Right b) = a == b
  eq _ _ = False
  textOf = either (const Nothing) (Just . formattedText)
  failedChecks = \case
    Left (ChecksFailed _ _ ds) -> map diffCheck ds
    _ -> []
