/-
 Copyright (c) 2023 Vladimir Sedlacek. All rights reserved.
 Released under Apache 2.0 license as described in the file LICENSE.
 Authors: Vladimir Sedlacek
 -/

import Lean.Data.HashMap
import Lean.Elab.Tactic
import ProofWidgets.Component.PenroseDiagram
import ProofWidgets.Component.HtmlDisplay
import ProofWidgets.Component.Panel.Basic

open Lean Meta Server
open ProofWidgets

/-! # Minimal definitions of synthetic geometric primitives, inspired by https://github.com/ah1112/synthetic_euclid_4 -/

class IncidenceGeometry where
  Point : Type u₁
  Line : Type u₂
  Circle : Type u₃

  between : Point → Point → Point → Prop -- implies colinearity
  onLine : Point → Line → Prop
  onCircle : Point → Circle → Prop
  centerCircle : Point → Circle → Prop
  ne_23_of_between : ∀ {a b c : Point}, between a b c → b ≠ c
  line_unique_of_pts : ∀ {a b : Point}, ∀ {L M : Line}, a ≠ b → onLine a L → onLine b L → onLine a M → onLine b M → L = M
  onLine_2_of_between : ∀ {a b c : Point}, ∀ {L : Line}, between a b c → onLine a L → onLine c L → onLine b L

variable [i : IncidenceGeometry]
open IncidenceGeometry

/-! # Metaprogramming utilities to break down expressions -/

/-- If `e == onLine a L` return `some (a, L)`, otherwise `none`. -/
def isOnLinePred? (e : Expr) : Option (Expr × Expr) := do
  let some (_, a, L) := e.app3? ``onLine | none
  return (a, L)

/-- If `e == between a b c` return `some (a, b, c)`, otherwise `none`. -/
def isBetweenPred? (e : Expr) : Option (Expr × Expr × Expr) := do
  let some (_, a, b, c) := e.app4? ``between | none
  return (a, b, c)

/-- If `e == onCircle a C` return `some (a, C)`, otherwise `none`. -/
def isOnCirclePred? (e : Expr) : Option (Expr × Expr) := do
  let some (_, a, C) := e.app3? ``onCircle | none
  return (a, C)

/-- If `e == centerCircle a C` return `some (a, C)`, otherwise `none`. -/
def isCenterCirclePred? (e : Expr) : Option (Expr × Expr) := do
  let some (_, a, C) := e.app3? ``centerCircle | none
  return (a, C)

/-- Expressions to display as labels in a diagram. -/
abbrev ExprEmbeds := Array (String × Expr)

open scoped Jsx in
def mkEuclideanDiag (sub : String) (embeds : ExprEmbeds) : MetaM Html := do
  let embeds ← embeds.mapM fun (s, h) =>
      return (s, <InteractiveCode fmt={← Widget.ppExprTagged h} />)
  return (
    <PenroseDiagram
      embeds={embeds}
      dsl={include_str ".."/".."/"widget"/"penrose"/"euclidean.dsl"}
      sty={include_str ".."/".."/"widget"/"penrose"/"euclidean.sty"}
      sub={sub} />)

def isEuclideanGoal? (hyps : Array LocalDecl) : MetaM (Option Html) := do
  let mut sub := "AutoLabel All\n"
  let mut sets : HashMap String Expr := .empty
  for assm in hyps do
    let tp ← instantiateMVars assm.type

      -- capture onLine hypotheses
    if let some (a, L) := isOnLinePred? tp then
      let sa ← toString <$> Lean.Meta.ppExpr a
      let sL ← toString <$> Lean.Meta.ppExpr L
      let (sets', ca) := sets.insert' sa a
      let (sets', cL) := sets'.insert' sL L
      sets := sets'
      if !ca then
        sub := sub ++ s!"Point {sa}\n"
      if !cL then
        sub := sub ++ s!"Line {sL}\n"
      sub := sub ++ s!"OnLine({sa}, {sL})\n"

    -- capture between hypotheses
    if let some (a, b, c) := isBetweenPred? tp then
      let sa ← toString <$> Lean.Meta.ppExpr a
      let sb ← toString <$> Lean.Meta.ppExpr b
      let sc ← toString <$> Lean.Meta.ppExpr c
      let (sets', ca) := sets.insert' sa a
      let (sets', cb) := sets'.insert' sb b
      let (sets', cc) := sets'.insert' sc c
      sets := sets'
      if !ca then
        sub := sub ++ s!"Point {sa}\n"
      if !cb then
        sub := sub ++ s!"Point {sb}\n"
      if !cc then
        sub := sub ++ s!"Point {sc}\n"
      sub := sub ++ s!"Between({sa}, {sb}, {sc})\n"

    -- capture onCircle hypotheses
    if let some (a, C) := isOnCirclePred? tp then
      let sa ← toString <$> Lean.Meta.ppExpr a
      let sC ← toString <$> Lean.Meta.ppExpr C
      let (sets', ca) := sets.insert' sa a
      let (sets', cC) := sets'.insert' sC C
      sets := sets'
      if !ca then
        sub := sub ++ s!"Point {sa}\n"
      if !cC then
        sub := sub ++ s!"Circle {sC}\n"
      sub := sub ++ s!"OnCircle({sa}, {sC})\n"

    -- capture centerCircle hypotheses
    if let some (a, C) := isCenterCirclePred? tp then
      let sa ← toString <$> Lean.Meta.ppExpr a
      let sC ← toString <$> Lean.Meta.ppExpr C
      let (sets', ca) := sets.insert' sa a
      let (sets', cC) := sets'.insert' sC C
      sets := sets'
      if !ca then
        sub := sub ++ s!"Point {sa}\n"
      if !cC then
        sub := sub ++ s!"Circle {sC}\n"
      sub := sub ++ s!"CenterCircle({sa}, {sC})\n"

  if sets.isEmpty then return none
  some <$> mkEuclideanDiag sub sets.toArray

/-! # RPC handler and client-side code for the widget -/

structure Params where
  ci : WithRpcRef Elab.ContextInfo
  mvar : MVarId
  locs : Array SubExpr.GoalLocation

#mkrpcenc Params

structure Response where
  html? : Option Html

#mkrpcenc Response

open scoped Jsx in
@[server_rpc_method]
def getEuclideanGoal (ps : Params) : RequestM (RequestTask Response) := do
  RequestM.asTask do
    let html? ← ps.ci.val.runMetaM {} <| ps.mvar.withContext do
      -- Which hypotheses have been selected in the UI,
      -- meaning they should *not* be shown in the display.
      let mut hiddenLocs : HashSet FVarId := mkHashSet ps.locs.size
      for l in ps.locs do
        match l with
        | .hyp fv | .hypType fv _ =>
          hiddenLocs := hiddenLocs.insert fv
        | _ => continue
      -- Filter local declarations by whether they are not in `hiddenLocs`.
      let locs := (← getLCtx).decls.toArray.filterMap (fun d? =>
        if let some d := d? then
          if !hiddenLocs.contains d.fvarId then some d else none
        else
          none)
      isEuclideanGoal? locs
    return { html? }

@[widget_module]
def EuclideanDisplayPanel : Component PanelWidgetProps where
  javascript := s!"
    import * as React from 'react';
    import \{ DynamicComponent, useAsync, RpcContext } from '@leanprover/infoview';
    const e = React.createElement;

    function findGoalForLocation(goals, loc) \{
      for (const g of goals) \{
        if (g.mvarId === loc.mvarId) return g
      }
      throw new Error(`Could not find goal for location $\{JSON.stringify(loc)}`)
    }

    export default function(props) \{
      const rs = React.useContext(RpcContext)
      const st = useAsync(async () => \{
        if (props.goals.length === 0)
          return \{ html: \{ text: 'No goals' }}
        let g = null
        if (props.selectedLocations.length === 0)
          g = props.goals[0]
        else
          g = findGoalForLocation(props.goals, props.selectedLocations[0])
        const locs = props.selectedLocations.map(loc => loc.loc)
        return rs.call('getEuclideanGoal', \{ ci: g.ctx, mvar: g.mvarId, locs })
      }, [props.selectedLocations, props.goals, rs])
      let inner = undefined
      if (st.state === 'resolved')
        inner = e(DynamicComponent, \{
          pos: props.pos,
          hash: '{hash HtmlDisplay.javascript}',
          props: \{
            pos: props.pos,
            html: st.value.html ?? \{ text: 'No Euclidean goal.' }
          }
        }, null);
      else
        inner = JSON.stringify(st)
      return e('details', \{open: true}, [
        e('summary', \{className: 'mv2 pointer'}, 'Euclidean diagram'),
        inner
      ])
    }
  "

/-! # Example usage -/

example {a b c : Point} {L M : Line} {C D E: Circle} (Babc : between a b c)
   (aL : onLine a L) (bM : onLine b M) (cL : onLine c L) (cM : onLine c M)
   (aC : onCircle a C) (aD : onCircle a D) (bC : centerCircle b C) (cE : centerCircle c E): L = M := by
  with_panel_widgets [EuclideanDisplayPanel]
      -- Place your cursor here.
    have aC : onCircle a C := by sorry
    have aD : onCircle a D := by sorry
    have bC : centerCircle b C := by sorry
    have cE : centerCircle c E := by sorry
    have bc := ne_23_of_between Babc
    have bL := onLine_2_of_between Babc aL cL
    exact line_unique_of_pts bc bL cL bM cM
