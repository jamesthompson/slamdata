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

module SlamData.Workspace.Deck.Slider
  ( startSliding
  , stopSlidingAndSnap
  , updateSliderPosition
  , setLens
  , render
  , containerProperties
  ) where

import CSS (CSS)
import SlamData.Workspace.AccessType as AccessType
import Control.Monad.Aff.Free (fromEff)
import DOM.HTML.Types (HTMLElement)
import Data.Int as Int
import Data.Lens (LensP)
import Data.Lens.Setter ((.~))
import Data.Array ((..))
import Data.Array as Array
import Data.Ord (max, min)
import Data.Tuple as Tuple
import Halogen as H
import Halogen.HTML.CSS.Indexed (style)
import Halogen.HTML.Indexed as HH
import Halogen.HTML.Events.Handler as HEH
import Halogen.Component.ChildPath (injSlot, injState)
import Halogen.HTML.Events.Indexed as HE
import Halogen.HTML.Events.Types (Event, MouseEvent)
import Halogen.HTML.Properties.Indexed (IProp(), I)
import Halogen.HTML.Properties.Indexed as HP
import Halogen.HTML.Properties.Indexed.ARIA as ARIA
import SlamData.Config as Config
import SlamData.Workspace.Card.CardId (CardId)
import SlamData.Workspace.Card.CardId as CardId
import SlamData.Workspace.Deck.Common (DeckHTML, DeckDSL)
import SlamData.Workspace.Card.Component as Card
import SlamData.Workspace.Deck.Gripper as Gripper
import SlamData.Workspace.Deck.Component.Query (Query)
import SlamData.Workspace.Deck.Component.Query as Query
import SlamData.Workspace.Deck.Component.ChildSlot as ChildSlot
import SlamData.Workspace.Card.Next.Component as Next
import SlamData.Workspace.Deck.Component.State (VirtualState, State, CardDef)
import SlamData.Workspace.Deck.Component.State as State
import SlamData.Prelude
import SlamData.Render.CSS as ClassNames
import Utils.CSS as CSSUtils
import Utils.DOM (getBoundingClientRect)

render :: VirtualState -> Boolean -> DeckHTML
render virtualState visible =
  HH.div
    ([ HP.key "deck-cards"
     , HP.classes [ ClassNames.cardSlider ]
     , HE.onTransitionEnd $ HE.input_ Query.StopSliderTransition
     , style
         $ (cardSliderTransformCSS state.activeCardIndex state.sliderTranslateX)
         *> (cardSliderTransitionCSS state.sliderTransition)
     ]
       ⊕ (guard (not visible) $> (HP.class_ ClassNames.invisible)))
    ((map (Tuple.uncurry (renderCard state)) (Array.zip state.cards (0 .. Array.length state.cards))) ⊕ [ renderNextActionCard state ])
  where
    state = State.runVirtualState virtualState

startSliding :: Event MouseEvent -> DeckDSL Unit
startSliding mouseEvent =
  setLens State._initialSliderX (Just mouseEvent.screenX)
    *> (setLens State._initialSliderCardWidth =<< getCardWidth)
    *> setLens State._sliderTransition false
    *> setLens State._backsided false

stopSlidingAndSnap :: Event MouseEvent -> DeckDSL Unit
stopSlidingAndSnap mouseEvent =
  updateSliderPosition mouseEvent
    *> startTransition
    *> snap
    *> stopSliding

updateSliderPosition :: Event MouseEvent -> DeckDSL Unit
updateSliderPosition mouseEvent =
  (f mouseEvent.screenX =<< H.gets _.initialSliderX)

f :: Number -> Maybe Number -> DeckDSL Unit
f screenX =
  maybe (pure unit) (setLens State._sliderTranslateX <<< translateXCalc screenX)

translateXCalc :: Number -> Number -> Number
translateXCalc eventScreenX initialX =
  eventScreenX - initialX

setLens :: forall b. LensP State b -> b -> DeckDSL Unit
setLens lens =
  H.modify <<< (lens .~ _)

stopSliding :: DeckDSL Unit
stopSliding =
  setLens State._initialSliderX Nothing *> setLens State._sliderTranslateX 0.0

getBoundingClientWidth :: HTMLElement -> DeckDSL Number
getBoundingClientWidth =
  fromEff <<< map _.width <<< getBoundingClientRect

getCardWidth :: DeckDSL (Maybe Number)
getCardWidth =
  traverse getBoundingClientWidth =<< H.gets _.nextActionCardElement

getCardIdByIndex :: Array CardDef -> Int -> Maybe CardId
getCardIdByIndex cards =
  map _.id <<< Array.index cards

snapActiveCardIndexByTranslationAndCardWidth :: Int -> Number -> Number -> Int -> Int
snapActiveCardIndexByTranslationAndCardWidth numberOfCards translateX cardWidth
  | translateX <= -(offsetCardSpacing cardWidth / 2.0) =
    min numberOfCards <<< flip sub (1 + Int.floor ((translateX - (offsetCardSpacing cardWidth / 2.0)) / cardWidth))
  | translateX >= (offsetCardSpacing cardWidth / 2.0) =
    max 0 <<< add (1 + Int.floor ((-translateX - (offsetCardSpacing cardWidth / 2.0)) / cardWidth))
  | otherwise =
    id

offsetCardSpacing :: Number -> Number
offsetCardSpacing = add $ cardSpacingGridSquares * Config.gridPx

snapActiveCardIndex :: VirtualState -> Int
snapActiveCardIndex virtualState =
  maybe id (snapActiveCardIndexByTranslationAndCardWidth (Array.length st.cards) st.sliderTranslateX) st.initialSliderCardWidth st.activeCardIndex
  where
  st = State.runVirtualState virtualState

snap :: DeckDSL Unit
snap =
  H.modify $ \st →
    st # State._activeCardIndex .~ snapActiveCardIndex (State.virtualState st)

startTransition :: DeckDSL Unit
startTransition =
  setLens State._sliderTransition true

willChangeActiveCardWhenDropped :: State -> Boolean
willChangeActiveCardWhenDropped st =
  st.activeCardIndex ≠ snapActiveCardIndex (State.virtualState st)

cardPositionCSS :: Int -> CSS
cardPositionCSS index = do
  CSSUtils.left $ CSSUtils.calc $
    "(100% + " <> show cardSpacingPx <> "px) * " <> show index

cardSliderTransformCSS :: Int -> Number -> CSS
cardSliderTransformCSS activeCardIndex translateX =
  CSSUtils.transform
    $ CSSUtils.translate3d (cardSliderTranslateX activeCardIndex translateX) "0" "0"

cardSliderTransitionCSS :: Boolean -> CSS
cardSliderTransitionCSS false = CSSUtils.transition "none"
cardSliderTransitionCSS true = CSSUtils.transition "all 0.33s"

cardSliderTranslateX :: Int -> Number -> String
cardSliderTranslateX activeCardIndex translateX =
  CSSUtils.calc
    $ "(-100% - " <> show cardSpacingPx <> "px)"
    ++ " * " ++ show activeCardIndex
    ++ " + " ++ show translateX ++ "px"

dropEffect :: Boolean -> String
dropEffect true = "execute"
dropEffect false = "none"

nextActionCardActive :: State -> Boolean
nextActionCardActive state = isNothing $ State.cardIdFromIndex state state.activeCardIndex

containerProperties :: forall a. State -> Array (IProp (onMouseUp :: I, onMouseLeave :: I, onMouseMove :: I | a) (Query Unit))
containerProperties state =
  [ ARIA.dropEffect $ dropEffect $ willChangeActiveCardWhenDropped state ]
    ⊕ (guard (isJust state.initialSliderX)
         $> (HE.onMouseUp \e -> HEH.preventDefault $> Just (H.action (Query.StopSlidingAndSnap e))))
    ⊕ (guard (isJust state.initialSliderX)
         $> (HE.onMouseLeave \e -> HEH.stopPropagation $> HEH.preventDefault $> Just (H.action (Query.StopSlidingAndSnap e))))
    ⊕ (guard (isJust state.initialSliderX)
         $> (HE.onMouseMove $ HE.input Query.UpdateSliderPosition))

cardSelected :: State -> CardId -> Boolean
cardSelected state cardId =
  Just cardId == State.cardIdFromIndex state state.activeCardIndex

cardPresented :: State -> CardId -> Boolean
cardPresented state cardId =
  cardSelected state cardId || isJust state.initialSliderX

cardProperties :: forall a b. State -> CardId -> Array (IProp a b)
cardProperties state cardId =
  [ ARIA.disabled $ show $ not $ cardSelected state cardId ]

cardSpacingGridSquares :: Number
cardSpacingGridSquares = 2.0

cardSpacingPx :: Number
cardSpacingPx = cardSpacingGridSquares * Config.gridPx

renderCard :: State -> CardDef -> Int -> DeckHTML
renderCard state cardDef index =
  HH.div
  ([ HP.key ("card" ⊕ CardId.cardIdToString cardDef.id)
   , HP.classes [ ClassNames.card ]
   , style $ cardPositionCSS index
   ]
   ⊕ foldMap (viewingStyle cardDef) state.viewingCard)
  (Gripper.renderGrippers
      (cardSelected state cardDef.id)
      (isJust state.initialSliderX)
      (Gripper.gripperDefsForCardId state.cards $ Just cardDef.id)
      ⊕ [ HH.div
            (cardProperties state cardDef.id)
            [ HH.Slot $ transformCardConstructor cardDef.ctor ]
        ]
  )
  where
  viewingStyle cardDef cid =
    guard (not (cardDef.id ≡ cid))
    $> (HP.class_ ClassNames.invisible)
  transformCardConstructor (H.SlotConstructor p l) =
    H.SlotConstructor
      (injSlot ChildSlot.cpCard p)
      (l <#> \def →
        { component: H.transformChild ChildSlot.cpCard def.component
        , initialState: injState ChildSlot.cpCard def.initialState
        }
      )

renderNextActionCard :: State -> DeckHTML
renderNextActionCard state =
  HH.div
    ([ HP.key ("next-action-card")
     , HP.classes [ ClassNames.card ]
     , HP.ref (H.action <<< Query.SetNextActionCardElement)
     , style $ cardPositionCSS (Array.length state.cards)
     ]
       ⊕ (guard (shouldHideNextActionCard state) $> (HP.class_ ClassNames.invisible))
    )
    (Gripper.renderGrippers
       (isNothing $ State.cardIdFromIndex state state.activeCardIndex)
       (isJust state.initialSliderX)
       (Gripper.gripperDefsForCardId state.cards Nothing)
       ⊕ [ HH.slot' ChildSlot.cpCard (ChildSlot.CardSlot top) \_ →
             { component: Next.nextCardComponent
             , initialState: H.parentState Card.initialCardState
             }
         ]
    )

shouldHideNextActionCard :: State -> Boolean
shouldHideNextActionCard state =
  isJust state.viewingCard ∨ state.accessType ≡ AccessType.ReadOnly