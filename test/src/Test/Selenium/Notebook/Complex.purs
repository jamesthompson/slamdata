module Test.Selenium.Notebook.Complex (test) where

import Prelude

import Data.List (length)
import Data.Traversable (traverse)
import Data.Array (last)
import Data.Maybe (maybe)
import Data.Either (Either(..))

import Selenium.Types
import Selenium.Monad
import Selenium.ActionSequence hiding (sequence)

import Test.Config
import Test.Selenium.ActionSequence
import Test.Selenium.Monad
import Test.Selenium.Log
import Test.Selenium.Common
import Test.Selenium.Notebook.Getters
import Test.Selenium.Notebook.Contexts
import Test.Selenium.Notebook.Viz (actualCanvasScreenshot)

import qualified Config as SDCfg
import qualified Data.String as S

checkMarkdownViz :: Check Unit
checkMarkdownViz = do
  setUp
  checkInput
  goToViewMode
  checkInput
  where
  goToViewMode = do
    config <- getConfig
    waitTime $ SDCfg.autosaveTick * 5
    map (S.replace "edit" "view") getCurrentUrl >>= get
    waitCanvas
    await "Error: has not been reloaded" do
      input <- attempt $ getElementByCss config.complex.inputSelector
               "there is no markdown result"
      case input of
        Left _ -> pure false
        Right i -> do
          val <- getAttribute i "value"
          pure $ maybe false (eq val) $ last config.complex.values


  setUp = do
    config <- getConfig
    insertMdCell
    mdCell <- getCell 0
    mdAce <- getAceFor mdCell
    mdPlay <- getPlayButtonFor mdCell
    sequence do
      leftClick mdAce
      keys "max = #____(10)"
      leftClick mdPlay
    waitNextQueryCellFor mdCell >>= sequence <<< leftClick
    await "Error: query cell has not been added"
      $ map (eq 2 <<< length) getCells
    queryCell <- getCell 1
    queryAce <- getAceFor queryCell
    queryPlay <- getPlayButtonFor queryCell

    sequence do
      leftClick queryAce
      keys config.query.parameterized
      leftClick queryPlay

    waitNextVizCellFor queryCell >>= sequence <<< leftClick
    await "Error: viz cell has not been added"
      $ map (eq 3 <<< length) getCells

  checkInput = do
    config <- getConfig
    traverse checkOneInput config.complex.values
    successMsg "Ok, value propagated"

  checkOneInput val = do
    config <- getConfig
    modifierKey <- getModifierKey
    input <- waitExistentCss config.complex.inputSelector
             "there is no markdown result"

    sequence do
      leftClick input
      selectAll modifierKey
      sendDelete
      keys val
      sendEnter

    await ("Error: incorrect chart ("<> val <> ")") do
      actualCanvasScreenshot
      screenshotsEqual $ config.screenshot.complex <> val <> ".png"

test :: Check Unit
test = do
  sectionMsg
    $ "Checking rendered markdown events propagating through\n"
    <> "query cell to viz cell"
  checkMarkdownViz