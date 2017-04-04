{-# LANGUAGE TemplateHaskell #-}
module SemanticDiff (main) where

import Arguments
import Command
import Command.Parse
import Development.GitRev
import Data.Aeson
import qualified Data.ByteString as B
import Data.Functor.Both
import Data.String
import Data.Version (showVersion)
import Options.Applicative hiding (action)
import qualified Paths_semantic_diff as Library (version)
import Prologue hiding (fst, snd, readFile)
import qualified Renderer as R
import qualified Renderer.SExpression as R
import Source
import Text.Regex

main :: IO ()
main = do
  args@Arguments{..} <- programArguments =<< execParser argumentsParser
  text <- case runMode of
    Diff -> runCommand $ do
      let render = case format of
            R.Split -> fmap encodeText . renderDiffs R.SplitRenderer
            R.Patch -> fmap encodeText . renderDiffs R.PatchRenderer
            R.JSON -> fmap encodeJSON . renderDiffs R.JSONDiffRenderer
            R.Summary -> fmap encodeSummaries . renderDiffs R.SummaryRenderer
            R.SExpression -> renderDiffs (R.SExpressionDiffRenderer R.TreeOnly)
            R.TOC -> fmap encodeSummaries . renderDiffs R.ToCRenderer
            _ -> fmap encodeText . renderDiffs R.PatchRenderer
      diffs <- case diffMode of
        PathDiff paths -> do
          blobs <- traverse readFile paths
          terms <- traverse (traverse parseBlob) blobs
          diff' <- runBothWith maybeDiff terms
          return [(fromMaybe <$> (emptySourceBlob <$> paths) <*> blobs, diff')]
        CommitDiff -> do
          blobPairs <- readFilesAtSHAs gitDir alternateObjectDirs filePaths (fromMaybe (toS nullOid) (fst shaRange)) (fromMaybe (toS nullOid) (snd shaRange))
          for blobPairs . uncurry $ \ path blobs -> do
            terms <- traverse (traverse parseBlob) blobs
            diff' <- runBothWith maybeDiff terms
            return (fromMaybe <$> pure (emptySourceBlob path) <*> blobs, diff')
      render (diffs >>= \ (blobs, diff) -> (,) blobs <$> toList diff)
    Parse -> case format of
      R.Index -> parseIndex args
      R.SExpression -> parseSExpression args
      _ -> parseTree args
  writeToOutput outputPath (text <> "\n")
  where encodeText = encodeUtf8 . R.unFile
        encodeJSON = toS . encode
        encodeSummaries = toS . encode

-- | A parser for the application's command-line arguments.
argumentsParser :: ParserInfo CmdLineOptions
argumentsParser = info (version <*> helper <*> argumentsP)
                       (fullDesc <> progDesc "Set the GIT_DIR environment variable to specify the git repository. Set GIT_ALTERNATE_OBJECT_DIRECTORIES to specify location of alternates."
                                 <> header "semantic-diff - Show semantic changes between commits")
  where
    argumentsP :: Parser CmdLineOptions
    argumentsP = CmdLineOptions
      <$> (flag R.Split R.Patch (long "patch" <> help "output a patch(1)-compatible diff")
      <|> flag R.Split R.JSON (long "json" <> help "output a json diff")
      <|> flag' R.Split (long "split" <> help "output a split diff")
      <|> flag' R.Summary (long "summary" <> help "output a diff summary")
      <|> flag' R.SExpression (long "sexpression" <> help "output an s-expression diff tree")
      <|> flag' R.TOC (long "toc" <> help "output a table of contents diff summary")
      <|> flag' R.Index (long "index" <> help "output indexable JSON parse output")
      <|> flag' R.ParseTree (long "parse-tree" <> help "output JSON parse tree structure"))
      <*> optional (option auto (long "timeout" <> help "timeout for per-file diffs in seconds, defaults to 7 seconds"))
      <*> optional (strOption (long "output" <> short 'o' <> help "output directory for split diffs, defaults to stdout if unspecified"))
      <*> optional (strOption (long "commit" <> short 'c' <> help "single commit entry for parsing"))
      <*> switch (long "no-index" <> help "compare two paths on the filesystem")
      <*> some (argument (eitherReader parseShasAndFiles) (metavar "SHA_A..SHAB FILES..."))
      <*> switch (long "debug" <> short 'd' <> help "set debug mode for parsing which outputs sourcetext for each syntax node")
      <*> flag Diff Parse (long "parse" <> short 'p' <> help "parses a source file without diffing")
      where
        parseShasAndFiles :: String -> Either String ExtraArg
        parseShasAndFiles s = case matchRegex regex s of
          Just ["", sha2] -> Right . ShaPair $ both Nothing (Just sha2)
          Just [sha1, sha2] -> Right . ShaPair $ Just <$> both sha1 sha2
          _ -> Right $ FileArg s
          where regex = mkRegexWithOpts "([0-9a-f]{40})\\.\\.([0-9a-f]{40})" True False

versionString :: String
versionString = "semantic-diff version " <> showVersion Library.version <> " (" <> $(gitHash) <> ")"

version :: Parser (a -> a)
version = infoOption versionString (long "version" <> short 'V' <> help "output the version of the program")

writeToOutput :: Maybe FilePath -> ByteString -> IO ()
writeToOutput = maybe B.putStr B.writeFile
