# Phase 4b: Standing Queries — Composite States + Expression Evaluator

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the three composite standing query state machines (CrossState, SubscribeAcrossEdgeState, EdgeSubscriptionReciprocalState), the FilterMapState, the minimal expression evaluator, and a top-level state dispatch router — completing the full MVSQ state machine layer.

**Architecture:** Composite states receive results from child subqueries (via `on_subscription_result`) and emit effects (CreateSubscription, CancelSubscription, ReportResults). CrossState computes Cartesian products. SubscribeAcrossEdge/EdgeSubscriptionReciprocal handle the cross-edge subscription protocol. FilterMapState evaluates expressions from the `expr` package. All are pure functions following the same `(fields, inputs) -> { fields, effects, changed }` pattern as Phase 4a leaf states.

**Tech Stack:** Roc (nightly pre-release, d73ea109cc2)

**Depends on:** Phase 4a (all modules in `packages/graph/standing/`)

---

## Roc Quirks Reference

See `docs/roc-quirks.md` for known issues. Key ones for this phase:
1. **Recursive Eq** — QuineValue `==` fails across packages. Use `quine_value_eq` helpers.
2. **Record destructuring ICE** — Use field access (`r.field`) not destructuring (`{ field } = r`) on complex return types.
3. **Sub-package imports** — Use `import ast.MvStandingQuery`, `import result.StandingQueryResult`, etc. within the `standing` package.

---

## File Structure

| File | Responsibility |
|------|---------------|
| **Create:** `packages/graph/standing/state/CrossState.roc` | Cartesian product of subquery results, lazy subscription emission |
| **Create:** `packages/graph/standing/state/SubscribeAcrossEdgeState.roc` | Edge watching, cross-node subscription creation/cancellation |
| **Create:** `packages/graph/standing/state/EdgeSubscriptionReciprocalState.roc` | Reciprocal edge verification, andThen relay |
| **Create:** `packages/graph/standing/state/FilterMapState.roc` | Condition filtering + column projection using Expr evaluator |
| **Create:** `packages/graph/standing/state/StateDispatch.roc` | Top-level router: dispatches on_initialize/on_node_events/on_subscription_result/read_results to correct state module |
| **Create:** `packages/expr/main.roc` | Expression evaluator package definition |
| **Create:** `packages/expr/Expr.roc` | Expr AST types + eval function |
| **Modify:** `packages/graph/standing/state/main.roc` | Add new state module exports |
| **Modify:** `packages/graph/standing/main.roc` | Add StateDispatch + expr dependency |

---

### Task 1: CrossState — Initialization + Subscription Result Handling

**Files:**
- Create: `packages/graph/standing/state/CrossState.roc`

CrossState computes the Cartesian product of results from multiple subqueries. On init, it subscribes to child queries (all at once, or lazily one-at-a-time). When results arrive, it caches them per-subquery and computes the cross product when all subqueries have reported.

- [ ] **Step 1: Create CrossState module with types and on_initialize**

```roc
# packages/graph/standing/state/CrossState.roc
module [
    on_initialize,
    on_subscription_result,
    read_results,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import ast.MvStandingQuery exposing [MvStandingQuery, query_part_id]
import result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## Internal fields for CrossState.
CrossFields : {
    query_part_id : StandingQueryPartId,
    results_accumulator : Dict StandingQueryPartId (Result (List QueryContext) [Pending]),
}

## Initialize CrossState by subscribing to child subqueries.
##
## If emit_subscriptions_lazily is true, only subscribe to the first subquery.
## Subsequent subscriptions are emitted in on_subscription_result when the
## previous subquery produces results.
on_initialize :
    CrossFields,
    List MvStandingQuery,  # the child queries from Cross.queries
    Bool,                   # emit_subscriptions_lazily
    SqContext
    -> { fields : CrossFields, effects : List SqEffect }
on_initialize = |fields, queries, emit_lazily, ctx|
    to_subscribe = if emit_lazily then
        List.take_first(queries, 1)
    else
        queries
    { new_acc, effects } = List.walk(to_subscribe, { new_acc: fields.results_accumulator, effects: [] }, |acc, sq|
        part_id = query_part_id(sq)
        {
            new_acc: Dict.insert(acc.new_acc, part_id, Err(Pending)),
            effects: List.append(acc.effects, CreateSubscription({
                on_node: ctx.executing_node_id,
                query: sq,
                global_id: 0u128,  # filled by dispatch layer
                subscriber_part_id: fields.query_part_id,
            })),
        }
    )
    { fields: { fields & results_accumulator: new_acc }, effects }
```

- [ ] **Step 2: Add on_subscription_result**

This is the core function. When a child subquery delivers results:
1. Verify the result is for a known subscription
2. Cache the result
3. If `emit_subscriptions_lazily` and this is the most-recently-emitted subscription's first result, subscribe to the next child
4. If all subscriptions emitted and all have results, compute cross product and report

```roc
## Process a subscription result from a child subquery.
on_subscription_result :
    CrossFields,
    StandingQueryPartId,     # result's query_part_id
    List QueryContext,       # result_group
    List MvStandingQuery,    # the child queries (from Cross.queries)
    Bool,                    # emit_subscriptions_lazily
    SqContext
    -> { fields : CrossFields, effects : List SqEffect, changed : Bool }
on_subscription_result = |fields, result_part_id, result_group, queries, emit_lazily, ctx|
    # Verify this result is for a known subscription
    when Dict.get(fields.results_accumulator, result_part_id) is
        Err(_) ->
            # Unknown subscription — ignore
            { fields, effects: [], changed: Bool.false }
        Ok(previous_result) ->
            subscriptions_emitted = Dict.len(fields.results_accumulator)
            total_queries = List.len(queries)

            if subscriptions_emitted != total_queries then
                # Not all subscriptions emitted yet (lazy mode)
                # Check if this result is from the most recently emitted subscription
                # and if so, emit the next one
                most_recent_idx = subscriptions_emitted - 1
                result_idx = List.find_first_index(queries, |sq| query_part_id(sq) == result_part_id)

                { new_acc, new_effects } = when result_idx is
                    Ok(idx) if idx == most_recent_idx ->
                        # This is the first result from the most recent subscription — emit next
                        next_sq = List.get(queries, subscriptions_emitted)
                        when next_sq is
                            Ok(sq) ->
                                next_id = query_part_id(sq)
                                acc2 = Dict.insert(fields.results_accumulator, result_part_id, Ok(result_group))
                                acc3 = Dict.insert(acc2, next_id, Err(Pending))
                                effect = CreateSubscription({
                                    on_node: ctx.executing_node_id,
                                    query: sq,
                                    global_id: 0u128,
                                    subscriber_part_id: fields.query_part_id,
                                })
                                { new_acc: acc3, new_effects: [effect] }
                            Err(_) ->
                                # No more queries to subscribe to (shouldn't happen)
                                { new_acc: Dict.insert(fields.results_accumulator, result_part_id, Ok(result_group)), new_effects: [] }
                    _ ->
                        # Result from an earlier subscription, just cache it
                        { new_acc: Dict.insert(fields.results_accumulator, result_part_id, Ok(result_group)), new_effects: [] }

                { fields: { fields & results_accumulator: new_acc }, effects: new_effects, changed: Bool.true }
            else
                # All subscriptions emitted — cache result and maybe report
                new_acc = Dict.insert(fields.results_accumulator, result_part_id, Ok(result_group))
                is_new = when previous_result is
                    Ok(prev) -> !(query_context_lists_eq(prev, result_group))
                    Err(Pending) -> Bool.true

                if is_new and is_ready_to_report(new_acc) then
                    cross = generate_cross_product(new_acc)
                    when cross is
                        Ok(rows) ->
                            { fields: { fields & results_accumulator: new_acc }, effects: [ReportResults(rows)], changed: Bool.true }
                        Err(NotReady) ->
                            { fields: { fields & results_accumulator: new_acc }, effects: [], changed: Bool.true }
                else
                    { fields: { fields & results_accumulator: new_acc }, effects: [], changed: is_new }
```

- [ ] **Step 3: Add read_results and helpers**

```roc
## Read current cross-product results.
read_results :
    CrossFields,
    List MvStandingQuery,   # queries
    Dict Str PropertyValue,
    Str
    -> Result (List QueryContext) [NotReady]
read_results = |fields, queries, _properties, _labels_key|
    if Dict.len(fields.results_accumulator) == List.len(queries) and is_ready_to_report(fields.results_accumulator) then
        generate_cross_product(fields.results_accumulator)
    else
        Err(NotReady)

## Check if all subqueries have reported at least one result.
is_ready_to_report : Dict StandingQueryPartId (Result (List QueryContext) [Pending]) -> Bool
is_ready_to_report = |accumulator|
    Dict.walk(accumulator, Bool.true, |all_ready, _key, value|
        when value is
            Ok(_) -> all_ready
            Err(Pending) -> Bool.false
    )

## Compute the Cartesian product of all subquery result groups.
generate_cross_product : Dict StandingQueryPartId (Result (List QueryContext) [Pending]) -> Result (List QueryContext) [NotReady]
generate_cross_product = |accumulator|
    result_groups = Dict.walk(accumulator, { all_ready: Bool.true, groups: [] }, |acc, _key, value|
        when value is
            Ok(rows) -> { acc & groups: List.append(acc.groups, rows) }
            Err(Pending) -> { acc & all_ready: Bool.false }
    )
    if !(result_groups.all_ready) then
        Err(NotReady)
    else
        # Fold: start with one empty row, cross each group
        crossed = List.walk(result_groups.groups, [Dict.empty({})], |rows_so_far, next_group|
            List.join_map(rows_so_far, |row|
                List.map(next_group, |addition|
                    Dict.walk(addition, row, |merged, k, v|
                        Dict.insert(merged, k, v)
                    )
                )
            )
        )
        Ok(crossed)

## Compare two lists of QueryContext for equality (needed for dedup).
query_context_lists_eq : List QueryContext, List QueryContext -> Bool
query_context_lists_eq = |a, b|
    if List.len(a) != List.len(b) then
        Bool.false
    else
        List.map2(a, b, |ctx_a, ctx_b| query_context_eq(ctx_a, ctx_b))
        |> List.all(|x| x)

## Compare two QueryContext dicts for equality.
query_context_eq : QueryContext, QueryContext -> Bool
query_context_eq = |a, b|
    if Dict.len(a) != Dict.len(b) then
        Bool.false
    else
        Dict.walk(a, Bool.true, |all_eq, key, val_a|
            if !(all_eq) then Bool.false
            else
                when Dict.get(b, key) is
                    Ok(val_b) -> quine_value_eq(val_a, val_b)
                    Err(_) -> Bool.false
        )
```

Add the standard `quine_value_eq` helper (same pattern as LocalPropertyState.roc — compare variant by variant, use `QuineId.to_bytes` for Id, `Num.is_approx_eq` for F64).

- [ ] **Step 4: Write tests**

Required tests (minimum 12):
1. on_initialize with emit_lazily=false subscribes to all queries
2. on_initialize with emit_lazily=true subscribes to first query only
3. on_subscription_result caches result
4. on_subscription_result with lazy mode emits next subscription when first result arrives
5. generate_cross_product with two single-row groups → one merged row
6. generate_cross_product with two multi-row groups → N*M rows
7. generate_cross_product with one Pending → NotReady
8. read_results when all subscriptions ready → cross product
9. read_results when not all subscriptions emitted → NotReady
10. is_ready_to_report with all Ok → true
11. is_ready_to_report with some Pending → false
12. Dedup: same result arriving twice → changed=false on second

- [ ] **Step 5: Run tests**

Run: `roc test packages/graph/standing/state/CrossState.roc`
Expected: 0 failed

- [ ] **Step 6: Update state/main.roc and commit**

Add `CrossState` to exports in `packages/graph/standing/state/main.roc`.

```bash
git add packages/graph/standing/state/
git commit -m "phase-4b: CrossState — Cartesian product with lazy subscriptions"
```

---

### Task 2: SubscribeAcrossEdgeState

**Files:**
- Create: `packages/graph/standing/state/SubscribeAcrossEdgeState.roc`

This state watches for edges matching a pattern. When a matching edge is added, it creates an `EdgeSubscriptionReciprocal` query and sends a `CreateSubscription` to the remote node. When an edge is removed, it cancels the subscription and re-reports results.

- [ ] **Step 1: Create SubscribeAcrossEdgeState module**

```roc
# packages/graph/standing/state/SubscribeAcrossEdgeState.roc
module [
    on_node_events,
    on_subscription_result,
    read_results,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.HalfEdge exposing [HalfEdge]
import model.EdgeDirection exposing [EdgeDirection]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import ast.MvStandingQuery exposing [MvStandingQuery, query_part_id]
import result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect]

## Internal fields.
SubscribeAcrossEdgeFields : {
    query_part_id : StandingQueryPartId,
    edge_results : Dict HalfEdge (Result (List QueryContext) [Pending]),
}
```

Key functions:

**edge_matches_pattern : HalfEdge, Result Str [AnyEdge], Result EdgeDirection [AnyDirection] -> Bool**
Checks if a half-edge matches the query's edge pattern (name and direction filters).

**on_node_events** — Takes fields, events, edge_name pattern, edge_direction pattern, and_then query, and SqContext. For each event:
- `EdgeAdded(he)` if matches pattern: create `EdgeSubscriptionReciprocal` query with `HalfEdge.reflect(he, ctx.executing_node_id)`, emit `CreateSubscription` to `he.other`, add `he -> Err(Pending)` to edge_results
- `EdgeRemoved(he)` if in edge_results: remove from edge_results, emit `CancelSubscription` to `he.other`, if old result had rows then re-report via read_results

**on_subscription_result** — Find matching edge by `result.from` node ID, cache result, report updated results if changed.

**read_results** — If no edges, return `Ok([])`. If any edge has `Pending`, return `Err(NotReady)`. Otherwise concatenate all edge result rows into one list.

- [ ] **Step 2: Write tests**

Required tests (minimum 8):
1. EdgeAdded matching pattern → CreateSubscription effect + edge_results entry
2. EdgeAdded not matching pattern → no effect
3. EdgeRemoved for tracked edge → CancelSubscription effect + edge removed from results
4. on_subscription_result caches result per edge
5. on_subscription_result for unknown edge → no effect
6. read_results with no edges → Ok([])
7. read_results with all edges resolved → concatenated rows
8. read_results with some Pending → NotReady

- [ ] **Step 3: Run tests and commit**

Run: `roc test packages/graph/standing/state/SubscribeAcrossEdgeState.roc`

```bash
git add packages/graph/standing/state/
git commit -m "phase-4b: SubscribeAcrossEdgeState — edge watching and cross-node subscriptions"
```

---

### Task 3: EdgeSubscriptionReciprocalState

**Files:**
- Create: `packages/graph/standing/state/EdgeSubscriptionReciprocalState.roc`

This is the remote side of a cross-edge subscription. It verifies the reciprocal half-edge exists, subscribes to the `andThen` query locally, and relays results back.

- [ ] **Step 1: Create EdgeSubscriptionReciprocalState module**

```roc
# packages/graph/standing/state/EdgeSubscriptionReciprocalState.roc
module [
    on_node_events,
    on_subscription_result,
    read_results,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.HalfEdge exposing [HalfEdge]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import ast.MvStandingQuery exposing [MvStandingQuery]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## Internal fields.
EdgeReciprocalFields : {
    query_part_id : StandingQueryPartId,
    half_edge : HalfEdge,
    and_then_id : StandingQueryPartId,
    currently_matching : Bool,
    cached_result : Result (List QueryContext) [NoCachedResult],
}
```

**on_node_events** — For each event:
- `EdgeAdded(he)` if `he == fields.half_edge`: set `currently_matching = true`, look up andThen query via `ctx.lookup_query(fields.and_then_id)`, emit `CreateSubscription` to self, report results if cached_result exists
- `EdgeRemoved(he)` if `he == fields.half_edge`: set `currently_matching = false`, emit `CancelSubscription` to self for andThen, report empty results `ReportResults([])`

**on_subscription_result** — Cache result. If `currently_matching` and result is new, emit `ReportResults(result_group)`.

**read_results** — If `currently_matching` and `cached_result` is `Ok`, return cached result. Otherwise `Err(NotReady)`.

NOTE: HalfEdge comparison needs a helper since HalfEdge contains QuineId (opaque). Compare `edge_type`, `direction`, and `QuineId.to_bytes(other)`.

- [ ] **Step 2: Write tests**

Required tests (minimum 8):
1. EdgeAdded matching half_edge → currently_matching=true + CreateSubscription
2. EdgeAdded non-matching → no change
3. EdgeRemoved matching → currently_matching=false + CancelSubscription + ReportResults([])
4. on_subscription_result when matching → ReportResults with result
5. on_subscription_result when not matching → caches but no report
6. on_subscription_result same result again → changed=false (dedup)
7. read_results when matching and cached → Ok(cached)
8. read_results when not matching → NotReady

- [ ] **Step 3: Run tests and commit**

Run: `roc test packages/graph/standing/state/EdgeSubscriptionReciprocalState.roc`

```bash
git add packages/graph/standing/state/
git commit -m "phase-4b: EdgeSubscriptionReciprocalState — reciprocal edge verification and andThen relay"
```

---

### Task 4: Expr Package — AST + Evaluator

**Files:**
- Create: `packages/expr/main.roc`
- Create: `packages/expr/Expr.roc`

The minimal expression evaluator for FilterMap. Supports literals, variables, property access, comparisons, boolean logic, IS NULL, IN list, and id()/labels() functions.

- [ ] **Step 1: Create the expr package**

```roc
# packages/expr/main.roc
package [
    Expr,
] {
    id: "../core/id/main.roc",
    model: "../core/model/main.roc",
}
```

- [ ] **Step 2: Create Expr.roc with AST types**

```roc
# packages/expr/Expr.roc
module [
    Expr,
    CompOp,
    BoolLogic,
    ExprContext,
    eval,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]

## Expression AST — minimal subset for FilterMap (Phase 4).
## Phase 5 will expand this with the full Cypher expression set.
Expr : [
    Literal QuineValue,
    Variable Str,
    Property { expr : Expr, key : Str },
    Comparison { left : Expr, op : CompOp, right : Expr },
    BoolOp { left : Expr, op : BoolLogic, right : Expr },
    Not Expr,
    IsNull Expr,
    InList { elem : Expr, list : Expr },
    FnCall { name : Str, args : List Expr },
]

CompOp : [Eq, Neq, Lt, Gt, Lte, Gte]
BoolLogic : [And, Or]

## QueryContext passed to eval (same structural type as standing query's QueryContext).
QueryContext : Dict Str QuineValue

## Context for expression evaluation.
ExprContext : {
    node_id : QuineId,
    labels_property_key : Str,
    properties : Dict Str PropertyValue,
}
```

- [ ] **Step 3: Implement eval**

```roc
## Evaluate an expression against a query context and node context.
## Returns EvalError for unknown functions, type mismatches, etc.
eval : Expr, QueryContext, ExprContext -> Result QuineValue [EvalError Str]
eval = |expr, query_ctx, expr_ctx|
    when expr is
        Literal(value) -> Ok(value)

        Variable(name) ->
            when Dict.get(query_ctx, name) is
                Ok(value) -> Ok(value)
                Err(_) -> Ok(Null)  # missing variables evaluate to Null

        Property({ expr: inner_expr, key }) ->
            inner_result = eval(inner_expr, query_ctx, expr_ctx)?
            when inner_result is
                Map(m) ->
                    when Dict.get(m, key) is
                        Ok(v) -> Ok(v)
                        Err(_) -> Ok(Null)
                _ -> Ok(Null)  # property access on non-map → Null

        Comparison({ left, op, right }) ->
            left_val = eval(left, query_ctx, expr_ctx)?
            right_val = eval(right, query_ctx, expr_ctx)?
            eval_comparison(left_val, op, right_val)

        BoolOp({ left, op, right }) ->
            left_val = eval(left, query_ctx, expr_ctx)?
            right_val = eval(right, query_ctx, expr_ctx)?
            eval_bool_op(left_val, op, right_val)

        Not(inner) ->
            inner_val = eval(inner, query_ctx, expr_ctx)?
            when inner_val is
                True -> Ok(False)
                False -> Ok(True)
                Null -> Ok(Null)
                _ -> Err(EvalError("NOT requires a boolean, got non-boolean"))

        IsNull(inner) ->
            inner_val = eval(inner, query_ctx, expr_ctx)?
            when inner_val is
                Null -> Ok(True)
                _ -> Ok(False)

        InList({ elem, list: list_expr }) ->
            elem_val = eval(elem, query_ctx, expr_ctx)?
            list_val = eval(list_expr, query_ctx, expr_ctx)?
            when list_val is
                List(items) ->
                    found = List.any(items, |item| quine_value_eq(item, elem_val))
                    if found then Ok(True) else Ok(False)
                Null -> Ok(Null)
                _ -> Err(EvalError("IN requires a list on the right side"))

        FnCall({ name, args: _ }) ->
            when name is
                "id" -> Ok(Id(QuineId.to_bytes(expr_ctx.node_id)))
                "labels" ->
                    when Dict.get(expr_ctx.properties, expr_ctx.labels_property_key) is
                        Ok(pv) -> Ok(PropertyValue.get_value(pv))
                        Err(_) -> Ok(List([]))
                _ -> Err(EvalError(Str.concat("Unknown function: ", name)))
```

Helper functions:
- `eval_comparison` — handles Eq/Neq for all types, Lt/Gt/Lte/Gte for Integer/Floating/Str. Returns `Null` if either side is `Null` (SQL null semantics). Returns `EvalError` for incompatible types on ordered comparisons.
- `eval_bool_op` — `And`/`Or` with three-valued logic (True, False, Null).
- `quine_value_eq` — same pattern as other modules, compare recursively.

- [ ] **Step 4: Write tests**

Required tests (minimum 15):
1. Literal evaluates to itself
2. Variable lookup — present
3. Variable lookup — missing → Null
4. Property access on Map
5. Property access on non-Map → Null
6. Comparison Eq — equal values → True
7. Comparison Eq — unequal → False
8. Comparison Neq
9. Comparison Lt on integers
10. Comparison with Null → Null
11. BoolOp And — True, True → True
12. BoolOp And — True, False → False
13. BoolOp Or — False, True → True
14. Not True → False
15. Not Null → Null
16. IsNull Null → True
17. IsNull non-null → False
18. InList — present → True
19. InList — absent → False
20. FnCall "id" → node ID
21. FnCall "labels" → labels list
22. FnCall unknown → EvalError

- [ ] **Step 5: Run tests**

Run: `roc test packages/expr/Expr.roc`
Expected: 0 failed

- [ ] **Step 6: Commit**

```bash
git add packages/expr/
git commit -m "phase-4b: Expr package — minimal expression AST and evaluator"
```

---

### Task 5: FilterMapState

**Files:**
- Create: `packages/graph/standing/state/FilterMapState.roc`
- Modify: `packages/graph/standing/state/main.roc` (add expr dependency + FilterMapState export)

FilterMapState wraps a child subquery, filters each result row with a condition expression, and optionally projects new columns.

- [ ] **Step 1: Create FilterMapState module**

```roc
# packages/graph/standing/state/FilterMapState.roc
module [
    on_initialize,
    on_subscription_result,
    read_results,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]
import ast.MvStandingQuery exposing [MvStandingQuery, query_part_id]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect, SqContext]
import expr.Expr as ExprMod exposing [Expr, ExprContext, eval]

## Internal fields.
FilterMapFields : {
    query_part_id : StandingQueryPartId,
    kept_results : Result (List QueryContext) [NoCachedResult],
}
```

**on_initialize** — Subscribe to the `to_filter` child subquery on self.

**on_subscription_result** — When child delivers results:
1. For each row in result_group, evaluate `condition` — keep rows where result is `True`
2. For each kept row, apply `to_add` projections (evaluate each expr, add column)
3. If `drop_existing` is true, start each output row from empty dict (only projected columns)
4. If results changed from cached, emit `ReportResults` and update cache

**read_results** — Return cached `kept_results`.

Key detail: condition evaluation uses `eval(condition_expr, row, expr_ctx)` where `expr_ctx` is built from `SqContext`. A row passes the filter if `eval` returns `Ok(True)`. Rows where eval returns `Ok(False)`, `Ok(Null)`, or `Err` are filtered out.

- [ ] **Step 2: Write tests**

Required tests (minimum 8):
1. on_initialize subscribes to to_filter on self
2. on_subscription_result with no filter → all rows pass
3. on_subscription_result with condition → only matching rows kept
4. on_subscription_result with to_add → new columns projected
5. on_subscription_result with drop_existing=true → only projected columns
6. on_subscription_result with drop_existing=false → original + projected columns
7. on_subscription_result same results → no change (dedup)
8. read_results returns cached results

- [ ] **Step 3: Update state/main.roc**

Add `FilterMapState` to exports. Add `expr: "../../../expr/main.roc"` to dependencies.

- [ ] **Step 4: Run tests and commit**

Run: `roc test packages/graph/standing/state/FilterMapState.roc`

```bash
git add packages/graph/standing/state/ packages/expr/
git commit -m "phase-4b: FilterMapState — condition filtering and column projection"
```

---

### Task 6: StateDispatch — Top-Level Router

**Files:**
- Create: `packages/graph/standing/state/StateDispatch.roc`
- Modify: `packages/graph/standing/state/main.roc` (add export)
- Modify: `packages/graph/standing/main.roc` (add export)

StateDispatch routes `on_initialize`, `on_node_events`, `on_subscription_result`, and `read_results` calls to the correct state module based on the `SqPartState` variant.

- [ ] **Step 1: Create StateDispatch module**

```roc
# packages/graph/standing/state/StateDispatch.roc
module [
    dispatch_on_initialize,
    dispatch_on_node_events,
    dispatch_on_subscription_result,
    dispatch_read_results,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import ast.MvStandingQuery exposing [MvStandingQuery, query_part_id]
import result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId, QueryContext]
import SqPartState exposing [SqPartState, SqEffect, SqContext, SubscriptionResult]
import UnitState
import LocalIdState
import LocalPropertyState
import LabelsState
import AllPropertiesState
import CrossState
import SubscribeAcrossEdgeState
import EdgeSubscriptionReciprocalState
import FilterMapState
```

**dispatch_on_initialize : SqPartState, MvStandingQuery, SqContext -> { state : SqPartState, effects : List SqEffect }**

Pattern match on `SqPartState` variant, call the appropriate module's `on_initialize`, return updated state + effects. Most leaf states have no-op init. Cross subscribes to children. FilterMap subscribes to child.

**dispatch_on_node_events : SqPartState, List NodeChangeEvent, MvStandingQuery, SqContext -> { state : SqPartState, effects : List SqEffect, changed : Bool }**

Route to appropriate module. Leaf states that watch events: LocalPropertyState, LabelsState, AllPropertiesState. Edge states: SubscribeAcrossEdge, EdgeSubscriptionReciprocal. Others: no-op.

**dispatch_on_subscription_result : SqPartState, SubscriptionResult, MvStandingQuery, SqContext -> { state : SqPartState, effects : List SqEffect, changed : Bool }**

Route to: CrossState, SubscribeAcrossEdgeState, EdgeSubscriptionReciprocalState, FilterMapState. Others: no-op.

**dispatch_read_results : SqPartState, MvStandingQuery, Dict Str PropertyValue, Str -> Result (List QueryContext) [NotReady]**

Route to appropriate read_results.

- [ ] **Step 2: Write tests**

Required tests (minimum 6):
1. dispatch_on_initialize for UnitSq → no effects
2. dispatch_on_initialize for Cross → subscription effects
3. dispatch_on_node_events for LocalPropertyState → property change triggers effects
4. dispatch_on_subscription_result for CrossState → caches result
5. dispatch_read_results for UnitState → Ok([empty row])
6. dispatch_read_results for LocalIdState → Ok([id row])

- [ ] **Step 3: Update package exports and commit**

Update `state/main.roc` and `standing/main.roc`.

Run: `roc test packages/graph/standing/state/StateDispatch.roc`

```bash
git add packages/graph/standing/
git commit -m "phase-4b: StateDispatch — top-level state router for all SQ state variants"
```

---

### Task 7: Full Test Run + Final Wiring

**Files:**
- Modify: `packages/graph/standing/main.roc` (final exports if needed)

- [ ] **Step 1: Run all Phase 4b module tests**

```bash
roc test packages/graph/standing/state/CrossState.roc
roc test packages/graph/standing/state/SubscribeAcrossEdgeState.roc
roc test packages/graph/standing/state/EdgeSubscriptionReciprocalState.roc
roc test packages/graph/standing/state/FilterMapState.roc
roc test packages/graph/standing/state/StateDispatch.roc
roc test packages/expr/Expr.roc
```

Expected: All pass with 0 failures.

- [ ] **Step 2: Run all Phase 4a tests (regression check)**

```bash
roc test packages/graph/standing/result/StandingQueryResult.roc
roc test packages/graph/standing/result/ResultDiff.roc
roc test packages/graph/standing/ast/ValueConstraint.roc
roc test packages/graph/standing/ast/MvStandingQuery.roc
roc test packages/graph/standing/state/SqPartState.roc
roc test packages/graph/standing/state/UnitState.roc
roc test packages/graph/standing/state/LocalIdState.roc
roc test packages/graph/standing/state/LocalPropertyState.roc
roc test packages/graph/standing/state/LabelsState.roc
roc test packages/graph/standing/state/AllPropertiesState.roc
roc test packages/graph/standing/index/WatchableEventIndex.roc
```

Expected: All pass (163 tests from Phase 4a).

- [ ] **Step 3: Run existing graph layer tests (regression check)**

```bash
roc test packages/graph/types/Ids.roc
roc test packages/graph/types/Effects.roc
roc test packages/graph/types/Messages.roc
roc test packages/graph/types/NodeEntry.roc
roc test packages/graph/shard/Dispatch.roc
roc test packages/graph/shard/ShardState.roc
roc test packages/graph/shard/SleepWake.roc
roc test packages/graph/shard/Lru.roc
roc test packages/graph/codec/Codec.roc
roc test packages/graph/routing/Routing.roc
```

Expected: All pass (153 tests from Phase 3).

- [ ] **Step 4: Commit final wiring**

```bash
git add packages/graph/standing/
git commit -m "phase-4b: final wiring — all composite states and expr evaluator verified"
```

- [ ] **Step 5: Push**

```bash
git push
```

---

## Self-Review Checklist

### Spec Coverage

| Spec Section | Task(s) |
|-------------|---------|
| CrossState (cartesian product, lazy subscriptions) | Task 1 |
| SubscribeAcrossEdgeState (edge watching, cross-node subscriptions) | Task 2 |
| EdgeSubscriptionReciprocalState (reciprocal verification, andThen relay) | Task 3 |
| Expr AST (9 variants) | Task 4 |
| Expr evaluator (comparisons, bool logic, functions) | Task 4 |
| FilterMapState (condition filtering, column projection) | Task 5 |
| StateDispatch (top-level routing) | Task 6 |
| Full regression check | Task 7 |

### Phase 4b → Phase 4c Handoff

After Phase 4b, all MVSQ state machines exist as pure functions. Phase 4c integrates them into the graph layer:
- Extends NodeState with `sq_states` and `watchable_event_index`
- Extends dispatch to route SQ events and messages
- Extends NodeSnapshot with SQ persistence
- Extends ShardState with part_index and result buffer
- Extends Codec with SQ message encoding

### Type Consistency

- `CrossFields.results_accumulator : Dict StandingQueryPartId (Result (List QueryContext) [Pending])` — matches SqPartState.CrossState
- `SubscribeAcrossEdgeFields.edge_results : Dict HalfEdge (Result (List QueryContext) [Pending])` — matches SqPartState.SubscribeAcrossEdgeState
- `EdgeReciprocalFields` — matches SqPartState.EdgeSubscriptionReciprocalState
- `FilterMapFields` — matches SqPartState.FilterMapState
- `SqEffect` — same type throughout, defined in SqPartState.roc
- `Expr` — new package `packages/expr/`, imported by FilterMapState via `expr:` dependency
