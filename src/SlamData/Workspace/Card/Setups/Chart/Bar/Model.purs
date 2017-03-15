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

module SlamData.Workspace.Card.Setups.Chart.Bar.Model where

import SlamData.Prelude

import Data.Argonaut (Json, decodeJson, (~>), (:=), isNull, jsonNull, (.?), jsonEmptyObject)
import Data.Lens ((^.), view)
import Data.Newtype (un)

import Test.StrongCheck.Arbitrary (arbitrary)
import Test.StrongCheck.Gen as Gen
import Test.StrongCheck.Data.Argonaut (ArbJCursor(..))

import SlamData.Workspace.Card.Setups.Dimension as D
import SlamData.Workspace.Card.Setups.Behaviour as SB
import SlamData.Workspace.Card.Setups.Axis as Ax
import SlamData.Form.Select as S
import SlamData.Form.Select ((⊝))

type BarR =
  { category ∷ D.LabeledJCursor
  , value ∷ D.LabeledJCursor
  , stack ∷ Maybe D.LabeledJCursor
  , parallel ∷ Maybe D.LabeledJCursor
  , axisLabelAngle ∷ Number
  }

type Model = Maybe BarR

initialModel ∷ Model
initialModel = Nothing

eqBarR ∷ BarR → BarR → Boolean
eqBarR r1 r2 =
  r1.category ≡ r2.category
  ∧ r1.value ≡ r2.value
  ∧ r1.stack ≡ r2.stack
  ∧ r1.parallel ≡ r2.parallel
  ∧ r1.axisLabelAngle ≡ r2.axisLabelAngle

eqModel ∷ Model → Model → Boolean
eqModel Nothing Nothing = true
eqModel (Just r1) (Just r2) = eqBarR r1 r2
eqModel _ _ = false

genModel ∷ Gen.Gen Model
genModel = do
  isNothing ← arbitrary
  if isNothing
    then pure Nothing
    else map Just do
    category ← map (map (un ArbJCursor) ∘ un D.DimensionWithStaticCategory) arbitrary
    value ← map (map (un ArbJCursor) ∘ un D.DimensionWithStaticCategory) arbitrary
    stack ← map (map (un ArbJCursor) ∘ un D.DimensionWithStaticCategory) <$> arbitrary
    parallel ← map (map (un ArbJCursor) ∘ un D.DimensionWithStaticCategory) <$> arbitrary
    axisLabelAngle ← arbitrary
    pure { category, value, stack, parallel, axisLabelAngle }

encode ∷ Model → Json
encode Nothing = jsonNull
encode (Just r) =
  "configType" := "bar"
  ~> "category" := r.category
  ~> "value" := r.value
  ~> "stack" := r.stack
  ~> "parallel" := r.parallel
  ~> "axisLabelAngle" := r.axisLabelAngle
  ~> jsonEmptyObject

decode ∷ Json → String ⊹ Model
decode js
  | isNull js = pure Nothing
  | otherwise = map Just $ decode' js <|> decodeLegacy js
  where
  decode' ∷ Json → String ⊹ BarR
  decode' js' = do
    obj ← decodeJson js'
    configType ← obj .? "configType"
    unless (configType ≡ "bar")
      $ throwError "This config is not bar"
    category ← obj .? "category"
    value ← obj .? "value"
    stack ← obj .? "stack"
    parallel ← obj .? "parallel"
    axisLabelAngle ← obj .? "axisLabelAngle"
    pure { category
         , value
         , stack
         , parallel
         , axisLabelAngle
         }

  decodeLegacy ∷ Json → String ⊹ BarR
  decodeLegacy js' = do
    obj ← decodeJson js'
    configType ← obj .? "configType"
    unless (configType ≡ "bar")
      $ throwError "This config is not bar"
    category ← map D.defaultJCursorDimension $ obj .? "category"
    val ← obj .? "value"
    valAggregation ← obj .? "valueAggregation"
    let value =
          D.Dimension
            (Just $ D.defaultJCursorCategory val)
            (D.Projection (Just valAggregation) val)
    stack ← map (map D.defaultJCursorDimension) $ obj .? "stack"
    parallel ← map (map D.defaultJCursorDimension) $ obj .? "parallel"
    axisLabelAngle ← obj .? "axisLabelAngle"
    pure { category, value, stack, parallel, axisLabelAngle }

type ReducedState r =
  { value ∷ S.Select D.LabeledJCursor
  , category ∷ S.Select D.LabeledJCursor
  , stack ∷ S.Select D.LabeledJCursor
  , parallel ∷ S.Select D.LabeledJCursor
  , axisLabelAngle ∷ Number
  , axes ∷ Ax.Axes
  | r }

initialState ∷ ReducedState ()
initialState =
  { value: S.emptySelect
  , category: S.emptySelect
  , stack: S.emptySelect
  , parallel: S.emptySelect
  , axisLabelAngle: zero
  , axes: Ax.initialAxes
  }

behaviour ∷ ∀ r. SB.Behaviour (ReducedState r) Model
behaviour =
  { synchronize
  , load
  , save
  }
  where
  synchronize st =
    let
      setPreviousValueFrom =
        S.setPreviousValueOn (view $ D._value ∘ D._projection)

      newCategory =
        setPreviousValueFrom st.category
          $ S.autoSelect
          $ S.newSelect
          $ map D.defaultJCursorDimension
          $ st.axes.category
          ⊕ st.axes.value
          ⊕ st.axes.time
          ⊕ st.axes.date
          ⊕ st.axes.datetime

      newValue =
        setPreviousValueFrom st.value
          $ S.autoSelect
          $ S.newSelect
          $ (map D.defaultJCursorDimension
          $ st.axes.value)
          ⊝ newCategory

      newStack =
        setPreviousValueFrom st.stack
          $ S.newSelect
          $ (map D.defaultJCursorDimension
          $ S.ifSelected [ newCategory ]
          $ st.axes.category
          ⊕ st.axes.time)
          ⊝ newCategory

      newParallel =
        setPreviousValueFrom st.parallel
          $ S.newSelect
          $ (map D.defaultJCursorDimension
          $ S.ifSelected [ newCategory ]
          $ st.axes.category
          ⊕ st.axes.time)
          ⊝ newCategory
          ⊝ newStack
    in
      st { category = newCategory
         , value = newValue
         , stack = newStack
         , parallel = newParallel
         }

  load Nothing st = st
  load (Just m) st =
    st { axisLabelAngle = m.axisLabelAngle
       , category = S.fromSelected $ Just m.category
       , value = S.fromSelected $ Just m.value
       , stack = S.fromSelected m.stack
       , parallel = S.fromSelected m.parallel
       }

  save st =
    { category: _
    , value: _
    , stack: st.stack ^. S._value
    , parallel: st.parallel ^. S._value
    , axisLabelAngle: st.axisLabelAngle
    }
    <$> (st.category ^. S._value)
    <*> (st.value ^. S._value)
