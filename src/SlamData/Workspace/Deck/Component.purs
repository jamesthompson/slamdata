{-
Copyright 2016 SlamData, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}


module SlamData.Workspace.Deck.Component
  ( initialState
  , render
  , eval
  , peek
  , module SlamData.Workspace.Deck.Component.Query
  , module DCS
  , module SlamData.Workspace.Deck.DeckPath
  ) where

import SlamData.Prelude

import Control.Monad.Aff as Aff
import Control.Monad.Aff.Promise as Promise
import Control.Monad.Eff.Exception as Exception
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Aff.EventLoop as EventLoop
import Control.UI.Browser (locationObject, setHref, newTab)

import Data.Array as Array
import Data.Lens ((.~), (%~), (^?), (?~), _Left, _Just)
import Data.List as L

import DOM.HTML.Location as Location
import DOM.HTML.HTMLElement (getBoundingClientRect)

import Halogen as H
import Halogen.Component.Opaque.Unsafe (opaqueState)
import Halogen.Component.Utils (raise', sendAfter', subscribeToBus')
import Halogen.HTML.Indexed as HH

import SlamData.Analytics as SA
import SlamData.Config as Config
import SlamData.FileSystem.Routing (parentURL)
import SlamData.GlobalError as GE
import SlamData.Guide as Guide
import SlamData.Quasar.Error as QE
import SlamData.Wiring (DeckMessage(..))
import SlamData.Wiring as Wiring
import SlamData.Wiring.Cache as Cache
import SlamData.Workspace.AccessType as AT
import SlamData.Workspace.Action as WA
import SlamData.Workspace.Card.CardId (CardId)
import SlamData.Workspace.Card.CardType as CT
import SlamData.Workspace.Card.Common.EvalQuery as CEQ
import SlamData.Workspace.Card.Component (CardQueryP, CardQuery(..), InnerCardQuery, AnyCardQuery)
import SlamData.Workspace.Card.Component.Query as CQ
import SlamData.Workspace.Card.InsertableCardType as ICT
import SlamData.Workspace.Card.Model as Card
import SlamData.Workspace.Card.Port as Port
import SlamData.Workspace.Deck.BackSide.Component as Back
import SlamData.Workspace.Deck.Common (DeckOptions, DeckHTML, DeckDSL)
import SlamData.Workspace.Deck.Component.ChildSlot (cpCard, ChildQuery, ChildSlot, cpDialog)
import SlamData.Workspace.Deck.Component.Cycle (DeckComponent)
import SlamData.Workspace.Deck.Component.Query (QueryP, Query(..), DeckAction(..))
import SlamData.Workspace.Deck.Component.Render as DCR
import SlamData.Workspace.Deck.Component.State as DCS
import SlamData.Workspace.Deck.DeckPath (deckPath, deckPath')
import SlamData.Workspace.Deck.DeckId (DeckId)
import SlamData.Workspace.Deck.Dialog.Component as Dialog
import SlamData.Workspace.Deck.Dialog.Share.Model (SharingInput)
import SlamData.Workspace.Deck.Model as Model
import SlamData.Workspace.Deck.Slider as Slider
import SlamData.Workspace.Eval.Persistence as P
import SlamData.Workspace.Routing (mkWorkspaceHash, mkWorkspaceURL)
import SlamData.Workspace.StateMode (StateMode(..))

import Utils.DOM (elementEq)
import Utils.LocalStorage as LocalStorage

initialState ∷ DeckId → DCS.StateP
initialState = opaqueState ∘ DCS.initialDeck

render ∷ DeckOptions → (DeckOptions → DeckComponent) → DCS.State → DeckHTML
render opts deckComponent st =
  -- HACK: required so that nested finalizers get run. Since this is run inside
  -- of a separate runUI instance with Deck.Component.Nested, they will not
  -- get invoked by normal machinery. -nf
  if st.finalized
  then HH.div_ []
  else case st.stateMode of
    Error err → DCR.renderError err
    _ → DCR.renderDeck opts deckComponent st

eval ∷ DeckOptions → Query ~> DeckDSL
eval opts = case _ of
  Init next → do
    { bus } ← H.liftH $ H.liftH Wiring.expose
    mb ← subscribeToBus' (H.action ∘ HandleMessage) bus.decks
    H.modify $ DCS._breakers .~ [mb]
    when (L.null opts.cursor) do
      eb ← subscribeToBus' (H.action ∘ HandleError) bus.globalError
      H.modify $ DCS._breakers %~ (Array.cons eb)
    updateCardSize
    loadDeck
    pure next
  PresentAccessNextActionCardGuide next → do
    H.modify (DCS._presentAccessNextActionCardGuide .~ true) $> next
  HideAccessNextActionCardGuide next →
    dismissAccessNextActionCardGuide $> next
  Finish next → do
    H.modify _ { finalized = true }
    H.gets _.breakers >>= traverse_ (H.fromAff ∘ EventLoop.break')
    pure next
  ExploreFile res next → do
    -- FIXME
    pure next
  Publish next → do
    { path } ← H.liftH $ H.liftH Wiring.expose
    deckPath ← deckPath' path <$> H.gets _.id
    H.fromEff ∘ newTab $ mkWorkspaceURL deckPath (WA.Load AT.ReadOnly)
    pure next
  FlipDeck next → do
    updateBackSide opts
    H.modify
      $ DCS._displayMode %~ case _ of
        DCS.Normal → DCS.Backside
        _ → DCS.Normal
    presentFlipGuideFirstTime
    pure next
  GrabDeck _ next →
    pure next
  UpdateCardSize next → do
    updateCardSize
    pure next
  ZoomIn next → do
    { path, varMaps } ← H.liftH $ H.liftH Wiring.expose
    st ← H.get
    let deckHash = mkWorkspaceHash (deckPath' path st.id) (WA.Load opts.accessType) varMaps
    H.fromEff $ locationObject >>= Location.setHash deckHash
    pure next
  ZoomOut next → do
    { path, varMaps } ← H.liftH $ H.liftH Wiring.expose
    st ← H.get
    case st.parent of
      Just (Tuple deckId _) → do
        let deckHash = mkWorkspaceHash (deckPath' path deckId) (WA.Load opts.accessType) varMaps
        H.fromEff $ locationObject >>= Location.setHash deckHash
      Nothing →
        void $ H.fromEff $ setHref $ parentURL $ Left path
    pure next
  StartSliding mouseEvent gDef next → do
    H.gets _.deckElement >>= traverse_ \el → do
      width ← getBoundingClientWidth el
      H.modify (DCS._cardElementWidth ?~ width)
      Slider.startSliding mouseEvent gDef
    pure next
  StopSlidingAndSnap mouseEvent next → do
    st ← H.get
    for_ st.activeCardIndex \oldIndex →
      for_ (DCS.cardCoordFromIndex oldIndex st) \coord →
        void $ queryCardEval coord $ H.action CQ.DeactivateCard
    Slider.stopSlidingAndSnap mouseEvent
    updateIndicator
    updateActiveState
    when (DCS.activeCard st ^? _Just ∘ _Left ≡ Just DCS.NextActionCard) do
      dismissAccessNextActionCardGuide
    pure next
  UpdateSliderPosition mouseEvent next →
    Slider.updateSliderPosition mouseEvent $> next
  SetCardElement element next → do
    H.modify _ { deckElement = element }
    pure next
  StopSliderTransition next → do
    sliderTransition ← H.gets _.sliderTransition
    when sliderTransition $
      H.modify $ DCS._sliderTransition .~ false
    pure next
  DoAction _ next → pure next
  Focus next → do
    st ← H.get
    when (not st.focused) do
      H.modify (DCS._focused .~ true)
      { bus } ← H.liftH $ H.liftH Wiring.expose
      H.fromAff $ Bus.write (DeckFocused st.id) bus.decks
      presentAccessNextActionCardGuideAfterDelay
    pure next
  -- Isn't always evaluated when deck looses focus
  Defocus ev next → do
    st ← H.get
    isFrame ← H.fromEff $ elementEq ev.target ev.currentTarget
    when (st.focused && isFrame) $
      for_ (L.last opts.cursor) \rootId → do
        { bus } ← H.liftH $ H.liftH Wiring.expose
        H.fromAff $ Bus.write (DeckFocused rootId) bus.decks
    H.modify (DCS._presentAccessNextActionCardGuide .~ false)
    pure next
  HandleMessage msg next → do
    st ← H.get
    case msg of
      DeckFocused focusedDeckId → do
        when (st.id ≡ focusedDeckId && not st.focused) $
          H.modify (DCS._focused .~ true)
        when (st.id ≠ focusedDeckId && st.focused) $
          H.modify (DCS._focused .~ false)
    pure next
  HandleError ge next → do
    showDialog $ Dialog.Error $ GE.print ge
    pure next
  DismissedCardGuide next → do
    -- FIXME
    pure next
  Run next → do
    -- FIXME
    pure next

  where
  getBoundingClientWidth =
    H.fromEff ∘ map _.width ∘ getBoundingClientRect

peek ∷ ∀ a. DeckOptions → H.ChildF ChildSlot ChildQuery a → DeckDSL Unit
peek opts (H.ChildF s q) =
  (peekCards ⊹ (\_ _ → pure unit) $ s)
   ⨁ peekBackSide opts
   ⨁ (const $ pure unit)
   ⨁ (peekDialog opts ⨁ (const $ pure unit))
   $ q

peekDialog ∷ ∀ a. DeckOptions → Dialog.Query a → DeckDSL Unit
peekDialog _ (Dialog.Show _ _) = do
  H.modify (DCS._displayMode .~ DCS.Dialog)
peekDialog _ (Dialog.Dismiss _) =
  H.modify (DCS._displayMode .~ DCS.Backside)
peekDialog _ (Dialog.FlipToFront _) =
  H.modify (DCS._displayMode .~ DCS.Normal)
peekDialog opts (Dialog.SetDeckName name _) =
  H.modify ((DCS._displayMode .~ DCS.Normal) ∘ (DCS._name .~ name))
    *> saveDeck opts Nothing
peekDialog _ (Dialog.Confirm d b _) = do
  H.modify (DCS._displayMode .~ DCS.Backside)
  case d of
    Dialog.DeleteDeck | b → raise' $ H.action $ DoAction DeleteDeck
    _ → pure unit

peekBackSide ∷ ∀ a. DeckOptions → Back.Query a → DeckDSL Unit
peekBackSide opts (Back.DoAction action _) = do
  { path } ← H.liftH $ H.liftH Wiring.expose
  case action of
    Back.Trash → do
      state ← H.get
      lastId ← H.gets DCS.findLastCard
      for_ (DCS.activeCard state <|> lastId) $ traverse_ \trashId → do
        -- FIXME
        H.modify
          $ (DCS._displayMode .~ DCS.Normal)
          ∘ (DCS._presentAccessNextActionCardGuide .~ false)
      void $ H.queryAll' cpCard $ left $ H.action UpdateDimensions
    Back.Rename → do
      name ← H.gets _.name
      showDialog $ Dialog.Rename name
    Back.Share → do
      sharingInput ← getSharingInput
      showDialog $ Dialog.Share sharingInput
    Back.Unshare → do
      sharingInput ← getSharingInput
      showDialog $ Dialog.Unshare sharingInput
    Back.Embed → do
      st ← H.get
      SA.track (SA.Embed st.id)
      -- FIXME
      sharingInput ← getSharingInput
      showDialog $ Dialog.Embed sharingInput mempty
    Back.Publish → do
      st ← H.get
      SA.track (SA.Publish st.id)
      -- FIXME
      sharingInput ← getSharingInput
      showDialog $ Dialog.Publish sharingInput mempty
    Back.DeleteDeck → do
      cards ← H.gets _.displayCards
      if Array.null cards
        then raise' $ H.action $ DoAction DeleteDeck
        else showDialog Dialog.DeleteDeck
    Back.Mirror → do
      H.modify $ DCS._displayMode .~ DCS.Normal
      raise' $ H.action $ DoAction Mirror
    Back.Wrap →
      raise' $ H.action $ DoAction Wrap
    Back.Unwrap decks →
      raise' $ H.action $ DoAction $ Unwrap decks
peekBackSide _ _ = pure unit

peekCards ∷ ∀ a. DeckId × CardId → CardQueryP a → DeckDSL Unit
peekCards cardId = const (pure unit) ⨁ peekCardInner cardId

showDialog ∷ Dialog.Dialog → DeckDSL Unit
showDialog dlg = do
  queryDialog $ H.action $ Dialog.Show dlg
  H.modify (DCS._displayMode .~ DCS.Dialog)

queryDialog ∷ Dialog.Query Unit → DeckDSL Unit
queryDialog q = H.query' cpDialog unit (left q) *> pure unit

queryCard ∷ ∀ a. DeckId × CardId → CQ.AnyCardQuery a → DeckDSL (Maybe a)
queryCard cid =
  H.query' cpCard cid
    ∘ right
    ∘ H.ChildF unit
    ∘ right

queryCardEval ∷ ∀ a. DeckId × CardId → CQ.CardQuery a → DeckDSL (Maybe a)
queryCardEval cid =
  H.query' cpCard cid ∘ left

updateActiveCardAndIndicator ∷ DeckDSL Unit
updateActiveCardAndIndicator = do
  st ← H.get
  case st.activeCardIndex of
    Nothing → H.modify $ DCS._activeCardIndex .~ Just (DCS.defaultActiveIndex st)
    Just _ → pure unit
  updateIndicator
  updateActiveState

updateIndicator ∷ DeckDSL Unit
updateIndicator =
  -- FIXME
  pure unit

updateActiveState ∷ DeckDSL Unit
updateActiveState = do
  st ← H.get
  { cache } ← H.liftH $ H.liftH Wiring.expose
  for_ st.activeCardIndex \cardIndex → do
    Cache.put st.id { cardIndex } cache.activeState
    for_ (DCS.cardCoordFromIndex cardIndex st) \coord →
      void $ queryCardEval coord $ H.action CQ.ActivateCard

updateBackSide ∷ DeckOptions → DeckDSL Unit
updateBackSide { cursor } = do
  -- FIXME
  pure unit

createCard ∷ CT.CardType → DeckDSL Unit
createCard cardType = do
  -- FIXME
  pure unit

dismissedAccessNextActionCardGuideKey ∷ String
dismissedAccessNextActionCardGuideKey = "dismissedAccessNextActionCardGuide"

getDismissedAccessNextActionCardGuideBefore ∷ DeckDSL Boolean
getDismissedAccessNextActionCardGuideBefore =
  H.liftH $ H.liftH
    $ either (const $ false) id
    <$> LocalStorage.getLocalStorage dismissedAccessNextActionCardGuideKey

storeDismissedAccessNextActionCardGuide ∷ DeckDSL Unit
storeDismissedAccessNextActionCardGuide =
  H.liftH $ H.liftH $ LocalStorage.setLocalStorage dismissedAccessNextActionCardGuideKey true

presentAccessNextActionCardGuideAfterDelay ∷ DeckDSL Unit
presentAccessNextActionCardGuideAfterDelay = do
  dismissedBefore ← getDismissedAccessNextActionCardGuideBefore
  focused ← H.gets _.focused
  when
    (not dismissedBefore && focused)
    do
      cancelPresentAccessNextActionCardGuide
      H.modify
        ∘ (DCS._presentAccessNextActionCardGuideCanceler .~ _)
        ∘ Just
        =<< (sendAfter' Config.addCardGuideDelay $ PresentAccessNextActionCardGuide unit)

cancelPresentAccessNextActionCardGuide ∷ DeckDSL Boolean
cancelPresentAccessNextActionCardGuide =
  H.fromAff ∘ maybe (pure false) (flip Aff.cancel $ Exception.error "Cancelled")
    =<< H.gets _.presentAccessNextActionCardGuideCanceler

dismissAccessNextActionCardGuide ∷ DeckDSL Unit
dismissAccessNextActionCardGuide =
  H.gets _.presentAccessNextActionCardGuide >>=
    flip when do
      H.modify (DCS._presentAccessNextActionCardGuide .~ false)
      storeDismissedAccessNextActionCardGuide

resetAccessNextActionCardGuideDelay ∷ DeckDSL Unit
resetAccessNextActionCardGuideDelay =
  cancelPresentAccessNextActionCardGuide
  >>= if _ then presentAccessNextActionCardGuideAfterDelay else pure unit

peekCardInner
  ∷ ∀ a
  . DeckId × CardId
  → H.ChildF Unit InnerCardQuery a
  → DeckDSL Unit
peekCardInner cardCoord = H.runChildF ⋙
  (peekCardEvalQuery cardCoord ⨁ peekAnyCard cardCoord)

peekCardEvalQuery ∷ ∀ a. DeckId × CardId → CEQ.CardEvalQuery a → DeckDSL Unit
peekCardEvalQuery cardCoord = case _ of
  CEQ.ZoomIn _ → raise' $ H.action ZoomIn
  _ → pure unit

peekAnyCard ∷ ∀ a. DeckId × CardId → AnyCardQuery a → DeckDSL Unit
peekAnyCard cardCoord q = do
  resetAccessNextActionCardGuideDelay
  -- FIXME
  -- for_ (q ^? _NextQuery ∘ _Right ∘ Next._AddCardType) createCard
  -- for_ (q ^? _NextQuery ∘ _Right ∘ Next._PresentReason) $ uncurry presentReason

presentReason ∷ Port.Port → CT.CardType → DeckDSL Unit
presentReason input cardType =
  showDialog dialog
  where
  insertableCardType = ICT.fromCardType cardType
  ioType = ICT.fromPort input
  reason = ICT.reason ioType cardType
  cardPaths = ICT.cardPathsBetween ioType insertableCardType
  dialog = Dialog.Reason cardType reason cardPaths

-- | Enqueues the card with the specified ID in the set of cards that are
-- | pending to run and enqueues a debounced query to trigger the cards to
-- | actually run.
runCard ∷ DeckId × CardId → DeckDSL Unit
runCard coord = do
  -- FIXME
  pure unit

-- | Saves the deck as JSON, using the current values present in the state.
saveDeck ∷ DeckOptions → Maybe (DeckId × CardId) → DeckDSL Unit
saveDeck { accessType, cursor } coord = do
  -- FIXME
  pure unit

loadDeck ∷ DeckDSL Unit
loadDeck = do
  st ← H.get
  H.modify _ { stateMode = Loading }
  { bus, value } ← H.liftH $ H.liftH $ P.getDeck' st.id
  Promise.wait value >>= case _ of
    Left err →
      H.modify _ { stateMode = Error "Error loading deck" }
    Right deck → do
      let
        cardIds = deck.mirror <> map (Tuple st.id ∘ _.cardId) deck.cards
      mbCards ← H.liftH $ H.liftH $ sequence <$> traverse P.getCard cardIds
      for_ mbCards \cards → do
        let
          displayCards = Array.zip cardIds cards <#> \(coord × c) →
            { coord
            , cardType: Card.modelCardType c.value.model.model
            }
        H.modify _
          { stateMode = Ready
          , displayCards = Right <$> displayCards
          }

getSharingInput ∷ DeckDSL SharingInput
getSharingInput = do
  -- FIXME
  { path } ← H.liftH $ H.liftH Wiring.expose
  deckId ← H.gets _.id
  pure { deckId, workspacePath: path, caches: L.Nil, sources: L.Nil }

updateCardSize ∷ DeckDSL Unit
updateCardSize = do
  H.queryAll' cpCard $ left $ H.action UpdateDimensions
  H.gets _.deckElement >>= traverse_ \el → do
    { width } ← H.fromEff $ getBoundingClientRect el
    H.modify $ DCS._responsiveSize .~ breakpoint width
  where
  breakpoint w
    | w < 240.0 = DCS.XSmall
    | w < 320.0 = DCS.Small
    | w < 420.0 = DCS.Medium
    | w < 540.0 = DCS.Large
    | w < 720.0 = DCS.XLarge
    | otherwise = DCS.XXLarge

getDeck
  ∷ DeckId
  → DeckDSL (Either QE.QError Model.Deck)
getDeck deckId =
  H.liftH $ H.liftH $ P.getDeck deckId

presentFlipGuideFirstTime ∷ DeckDSL Unit
presentFlipGuideFirstTime = do
  H.gets _.displayMode >>=
    case _ of
      DCS.Backside → do
        { bus } ← H.liftH $ H.liftH Wiring.expose
        shouldPresentFlipGuide >>=
          if _
          then H.fromAff $ Bus.write Wiring.FlipGuide bus.stepByStep
          else pure unit
      _ → pure unit

shouldPresentFlipGuide ∷ DeckDSL Boolean
shouldPresentFlipGuide =
  H.liftH
    $ H.liftH
    $ either (const true) not <$> LocalStorage.getLocalStorage Guide.dismissedFlipGuideKey

queryRootDeckCard ∷ ∀ a. CardId → CQ.AnyCardQuery a → DeckDSL (Maybe a)
queryRootDeckCard cid query =
  flip queryCard query ∘ flip Tuple cid =<< H.gets _.id
