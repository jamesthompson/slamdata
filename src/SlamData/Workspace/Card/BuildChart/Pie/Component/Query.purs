module SlamData.Workspace.Card.BuildChart.Pie.Component.Query where

import SlamData.Prelude

import Data.Argonaut (JCursor)

import Halogen as H

import SlamData.Workspace.Card.Common.EvalQuery (CardEvalQuery)
import SlamData.Workspace.Card.BuildChart.Aggregation (Aggregation)
import SlamData.Workspace.Card.BuildChart.Inputs (SelectAction)
import SlamData.Workspace.Card.BuildChart.Pie.Component.ChildSlot (ChildQuery, ChildSlot)

data Selection f
  = Category (f JCursor)
  | Value (f JCursor)
  | ValueAgg (f Aggregation)
  | Donut (f JCursor)
  | Parallel (f JCursor)

data Query a
  = Select (Selection SelectAction) a

type QueryC = CardEvalQuery ⨁ Query

type QueryP = QueryC ⨁ H.ChildF ChildSlot ChildQuery