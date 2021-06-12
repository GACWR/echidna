{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Echidna.UI.Widgets where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import Control.Lens
import Control.Monad.Reader (MonadReader)
import Data.Has (Has(..))
import Data.List (nub, intersperse)
import Data.Version (showVersion)
import Text.Printf (printf)

import qualified Brick.AttrMap as A
import qualified Data.Text as T
import qualified Graphics.Vty as V
import qualified Paths_echidna (version)

import Echidna.ABI
import Echidna.Campaign (isDone)
import Echidna.Events (Events)
import Echidna.Types.Campaign
import Echidna.Types.Test (TestState(..), TestType(..), testEvents, testResult, testType, testState, EchidnaTest)
import Echidna.Types.Tx (Tx, TxResult(..), TxConf, src)
import Echidna.UI.Report

data UIState = Uninitialized | Running | Timedout

attrs :: A.AttrMap
attrs = A.attrMap (V.white `on` V.black)
  [ ("failure", fg V.brightRed)
  , ("bold", fg V.white `V.withStyle` V.bold)
  , ("tx", fg V.brightWhite)
  , ("working", fg V.brightBlue)
  , ("success", fg V.brightGreen)
  ]

-- | Render 'Campaign' progress as a 'Widget'.
campaignStatus :: (MonadReader x m, Has CampaignConf x, Has Names x, Has TxConf x)
               => (Campaign, UIState) -> m (Widget ())
campaignStatus (c@Campaign{_tests, _coverage, _ncallseqs}, uiState) = do
  done <- isDone c
  case (uiState, done) of
    (Uninitialized, _) -> pure $ mainbox (padLeft (Pad 1) $ str "Starting up, please wait...") emptyWidget
    (Timedout, _)      -> mainbox <$> testsWidget _tests <*> pure (str "Timed out, C-c or esc to exit")
    (_, True)          -> mainbox <$> testsWidget _tests <*> pure (str "Campaign complete, C-c or esc to exit")
    _                  -> mainbox <$> testsWidget _tests <*> pure emptyWidget
  where
    mainbox :: Widget () -> Widget () -> Widget ()
    mainbox inner underneath =
      padTop (Pad 1) $ hCenter $ hLimit 120 $
      wrapInner inner
      <=>
      hCenter underneath
    wrapInner inner =
      borderWithLabel (withAttr "bold" $ str title) $
      summaryWidget c
      <=>
      hBorderWithLabel (str "Tests")
      <=>
      inner
    title = "Echidna " ++ showVersion Paths_echidna.version

summaryWidget :: Campaign -> Widget ()
summaryWidget c =
  padLeft (Pad 1) (
    (if null (c ^. tests) then
      str ("No tests, benchmark mode. Number of call sequences: " ++ show (c ^. ncallseqs))
    else
      str ("Tests found: " ++ show (length $ c ^. tests)) <=>
      str ("Seed: " ++ show (c ^. genDict . defSeed))
    )
    <=>
    maybe emptyWidget str (ppCoverage $ c ^. coverage)
    <=>
    maybe emptyWidget str (ppCorpus $ c ^. corpus)
  )

testsWidget :: (MonadReader x m, Has CampaignConf x, Has Names x, Has TxConf x)
            => [EchidnaTest] -> m (Widget())
testsWidget tests' = foldl (<=>) emptyWidget . intersperse hBorder <$> traverse testWidget tests'

testWidget :: (MonadReader x m, Has CampaignConf x, Has Names x, Has TxConf x)
           => EchidnaTest -> m (Widget ())
testWidget etest =
 case test of
      Exploration       -> widget "exploration" ""
      PropertyTest n _  -> widget n ""
      AssertionTest s _ -> widget (encodeSig s) "assertion in "
      CallTest n _      -> widget n ""
 
  where
  test = etest ^. testType
  state = etest ^. testState
  events = etest ^. testEvents
  result = etest ^. testResult
  widget n infront = do
    (status, details) <- tsWidget state events result
    pure $ padLeft (Pad 1) $
      str infront <+> name n <+> str ": " <+> status
      <=> padTop (Pad 1) details
  name n = withAttr "bold" $ str (T.unpack n)

tsWidget :: (MonadReader x m, Has CampaignConf x, Has Names x, Has TxConf x)
         => TestState -> Events -> TxResult -> m (Widget (), Widget ())
tsWidget (Failed e) _ _  = pure (str "could not evaluate", str $ show e)
tsWidget (Solved l) es r = failWidget Nothing l es r
tsWidget Passed     _ _  = pure (withAttr "success" $ str "PASSED!", emptyWidget)
tsWidget (Open i)   _ _  = do
  t <- view (hasLens . testLimit)
  if i >= t then
    tsWidget Passed [] Stop
  else
    pure (withAttr "working" $ str $ "fuzzing " ++ progress i t, emptyWidget)
tsWidget (Large n l) es r = do
  m <- view (hasLens . shrinkLimit)
  failWidget (if n < m then Just (n,m) else Nothing) l es r

failWidget :: (MonadReader x m, Has Names x, Has TxConf x)
           => Maybe (Int, Int) -> [Tx] -> Events -> TxResult -> m (Widget (), Widget ())
failWidget _ [] _  _ = pure (failureBadge, str "*no transactions made*")
failWidget b xs es r = do
  s <- seqWidget
  pure (failureBadge  <+> str (" with " ++ show r), status <=> titleWidget <=> s <=> eventWidget <=> str (T.unpack $ T.intercalate ", " es))
  where
  titleWidget  = str "Call sequence" <+> str ":"
  eventWidget = str "Event sequence" <+> str ":"

  status = case b of
    Nothing    -> emptyWidget
    Just (n,m) -> str "Current action: " <+> withAttr "working" (str ("shrinking " ++ progress n m))

  seqWidget = do
    ppTxs <- mapM (ppTx $ length (nub $ view src <$> xs) /= 1) xs
    let ordinals = str . printf "%d." <$> [1 :: Int ..]
    pure $
      foldl (<=>) emptyWidget $
        zipWith (<+>) ordinals (withAttr "tx" . strWrap <$> ppTxs)

failureBadge :: Widget ()
failureBadge = withAttr "failure" $ str "FAILED!"
