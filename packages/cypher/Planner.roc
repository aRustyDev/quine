module [
    QueryPlan,
    PlanStep,
    ProjectItem,
    plan,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import expr.Expr exposing [Expr]

## A flat sequence of operations for the Rust executor to walk.
QueryPlan : {
    steps : List PlanStep,
    aliases : List Str,
}

## One step in a query plan.
PlanStep : [
    ScanSeeds {
        alias : Str,
        node_ids : List QuineId,
        label : [Labeled Str, Unlabeled],
        inline_props : List { key : Str, value : QuineValue },
    },
    Traverse {
        from_alias : Str,
        edge_type : [Typed Str, Untyped],
        direction : [Outgoing, Incoming, Undirected],
        to_alias : Str,
        to_label : [Labeled Str, Unlabeled],
    },
    Filter {
        predicate : Expr,
    },
    Project {
        items : List ProjectItem,
    },
]

## An item in the Project step.
ProjectItem : [
    WholeNode Str,
    NodeProperty { alias : Str, prop : Str, output_name : Str },
]

## Convert a CypherQuery AST + seed node IDs into a QueryPlan.
plan : { pattern : _, where_ : _, return_items : _ }, List QuineId -> Result QueryPlan [PlanError Str]
plan = |_query, _node_ids|
    Err(PlanError("not implemented"))
