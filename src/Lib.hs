{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Lib (generate) where

import           Control.Monad (unless)
import           Data.FileEmbed (embedStringFile)
import           Data.Generics (Data, Typeable)
import           Data.Text (Text, pack)
import           Data.Time.Clock (UTCTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           Data.Vector (Vector)
import           System.IO.Unsafe (unsafePerformIO)
import           Text.Hastache (MuContext, defaultConfig, encodeStr, hastacheStr)
import           Text.Hastache.Context (mkGenericContext)

import qualified Data.Text.Lazy.IO as TL
import qualified Data.Vector as V
import qualified GitHub as GH

--------------------------------------------------------------------------------

-- | Parameters required to generate a Delta.
data DeltaParams = DeltaParams {
    deltaAuth  :: GH.Auth
  , deltaOwner :: GH.Name GH.Owner
  , deltaRepo  :: GH.Name GH.Repo
  , deltaSince :: GH.Name GH.GitCommit
  }

--------------------------------------------------------------------------------

-- | Single event in a changelog.
data Event = Event { eventAuthor :: Text
                   , eventTitle  :: Text
                   , eventLink   :: Text
                   } deriving (Data, Typeable)

--------------------------------------------------------------------------------

-- | Single changelog entry.
data Delta = Delta { deltaDate :: Text, deltaEvents :: [Event] }
           deriving (Data, Typeable)

--------------------------------------------------------------------------------

-- | Write changelog entry since SHA to STDOUT.
generate :: GH.Auth -> GH.Name GH.Owner -> GH.Name GH.Repo -> GH.Name GH.GitCommit -> IO ()
generate auth owner repo sha = do
  response <- commitDate params
  case response of
    Left err    -> error $ show err
    Right since -> do
      prs <- closedPullRequestsSince params since
      unless (V.null prs) $
        hastacheStr defaultConfig (encodeStr template) (context since prs) >>= TL.putStrLn
  where
    context :: UTCTime -> Vector GH.SimplePullRequest -> MuContext IO
    context since prs = mkGenericContext $ toDelta since prs

    params :: DeltaParams
    params = DeltaParams auth owner repo sha

    template :: String
    template = $(embedStringFile "src/Delta.mustache")

--------------------------------------------------------------------------------

-- | Get date a commit was created.
commitDate :: DeltaParams -> IO (Either GH.Error UTCTime)
commitDate DeltaParams{..} = do
  response <- GH.executeRequest deltaAuth $ GH.gitCommitR deltaOwner deltaRepo deltaSince
  case response of
    Left  err    -> return $ Left err
    Right commit -> return $ Right (GH.gitUserDate $ GH.gitCommitAuthor commit)

--------------------------------------------------------------------------------

-- | Get pull requests closed since a given date.
closedPullRequestsSince :: DeltaParams -> UTCTime -> IO (Vector GH.SimplePullRequest)
closedPullRequestsSince params@DeltaParams{..} since = do
  response' <- GH.executeRequest deltaAuth $
    GH.pullRequestsForR deltaOwner deltaRepo (Just "closed") (Just 100)
  case response' of
    Left err  -> error $ show err
    Right prs -> return $ V.takeWhile (hasSinceBeenMerged since) prs
  where
    hasSinceBeenMerged :: UTCTime -> GH.SimplePullRequest -> Bool
    hasSinceBeenMerged since pr = case GH.simplePullRequestMergedAt pr of
      Just mergedAt -> since < mergedAt
      _             -> False

--------------------------------------------------------------------------------

-- | Convert collection of pull requests to internal representation.
toDelta :: UTCTime -> Vector GH.SimplePullRequest -> Delta
toDelta since prs = Delta date events
  where
    date :: Text
    date = pack $ formatTime defaultTimeLocale "%d %b %Y" since

    events :: [Event]
    events = V.toList $ fmap toEvent prs

--------------------------------------------------------------------------------

-- | Convert pull request to internal representation.
toEvent :: GH.SimplePullRequest -> Event
toEvent pr = Event author title link
  where
    author :: Text
    author = GH.untagName $ GH.simpleUserLogin $ GH.simplePullRequestUser pr

    title :: Text
    title = GH.simplePullRequestTitle pr

    link :: Text
    link = GH.pullRequestLinksHtml $ GH.simplePullRequestLinks pr