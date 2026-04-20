# Phase 4a: Standing Queries — AST, Leaf States, Index, Result Diffing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Roc foundation for standing queries: the MVSQ AST types, five leaf state machines (UnitState, LocalIdState, LocalPropertyState, LabelsState, AllPropertiesState), the WatchableEventIndex, and result diffing — all fully tested with no platform dependency.

**Architecture:** Each component is a standalone Roc module with inline `expect` tests. The standing query package (`packages/graph/standing/`) depends on `core/id` and `core/model` for QuineId, PropertyValue, HalfEdge, and NodeChangeEvent. State update functions are pure: `(state, inputs) -> { state, effects }`. No graph layer integration yet — that's Phase 4c.

**Tech Stack:** Roc (nightly pre-release, d73ea109cc2)

---

## File Structure

| File | Responsibility |
|------|---------------|
| **Create:** `packages/graph/standing/main.roc` | Package definition — exports all standing query modules |
| **Create:** `packages/graph/standing/ast/MvStandingQuery.roc` | MVSQ AST tagged union, `query_part_id` computation, `indexable_subqueries`, `create_state`, `relevant_event_types` |
| **Create:** `packages/graph/standing/ast/ValueConstraint.roc` | `ValueConstraint` and `LabelsConstraint` tagged unions with `check` functions |
| **Create:** `packages/graph/standing/state/SqPartState.roc` | `SqPartState` tagged union, `QueryContext` alias, `SqEffect`, `SqContext`, `SubscriptionResult` types, top-level dispatch functions (`on_initialize`, `on_node_events`, `on_subscription_result`, `read_results`) |
| **Create:** `packages/graph/standing/state/UnitState.roc` | UnitState logic — always returns one empty-row result |
| **Create:** `packages/graph/standing/state/LocalIdState.roc` | LocalIdState logic — returns node's own ID |
| **Create:** `packages/graph/standing/state/LocalPropertyState.roc` | LocalPropertyState logic — property watching with ValueConstraint |
| **Create:** `packages/graph/standing/state/LabelsState.roc` | LabelsState logic — label watching with LabelsConstraint |
| **Create:** `packages/graph/standing/state/AllPropertiesState.roc` | AllPropertiesState logic — all-property watching |
| **Create:** `packages/graph/standing/index/WatchableEventIndex.roc` | Event-to-subscriber dispatch index |
| **Create:** `packages/graph/standing/result/ResultDiff.roc` | `generate_result_reports` and `ResultsReporter` |
| **Create:** `packages/graph/standing/result/StandingQueryResult.roc` | `StandingQueryResult` type |

---

## Design Notes

### Roc Module Pattern

Each `.roc` file starts with `module [exports]` and uses `import` for dependencies. Tests are inline `expect` blocks at the bottom. Run with `roc test path/to/Module.roc`.

### StandingQueryId

The spec uses `U128` for `StandingQueryId`. Roc supports `U128` natively. For Phase 4a testing, we construct them as literal values. Phase 5/7 will generate them from UUIDs.

### SqContext as a Record (not closures)

The spec defines `lookup_query` as a function in `SqContext`. In Phase 4a tests, we construct test `SqContext` values with a simple closure that looks up from a `Dict`. In Phase 4c, the real shard populates this from its `part_index`.

### No Regex in Phase 4a

`ValueConstraint.Regex` requires a regex engine. Roc's standard library doesn't have one. Phase 4a defines the variant but `check` returns `Err RegexNotSupported`. Phase 5 (query languages) will bring a regex implementation.

---

### Task 1: Package Scaffold + StandingQueryResult Type

**Files:**
- Create: `packages/graph/standing/main.roc`
- Create: `packages/graph/standing/result/StandingQueryResult.roc`

- [ ] **Step 1: Create the StandingQueryResult module**

```roc
# packages/graph/standing/result/StandingQueryResult.roc
module [
    StandingQueryResult,
    StandingQueryId,
    StandingQueryPartId,
    QueryContext,
]

import model.QuineValue exposing [QuineValue]

## UUID identifying a top-level standing query.
StandingQueryId : U128

## Identifies one part of a compiled standing query.
## Computed by hashing the MVSQ AST subtree.
StandingQueryPartId : U64

## A row of named values — the result unit of an MVSQ.
QueryContext : Dict Str QuineValue

## A standing query result emitted to consumers.
StandingQueryResult : {
    is_positive_match : Bool,
    data : Dict Str QuineValue,
}

# ===== Tests =====

expect
    result : StandingQueryResult
    result = { is_positive_match: Bool.true, data: Dict.insert(Dict.empty({}), "name", Str("Alice")) }
    result.is_positive_match == Bool.true

expect
    result : StandingQueryResult
    result = { is_positive_match: Bool.false, data: Dict.empty({}) }
    result.is_positive_match == Bool.false

expect
    ctx : QueryContext
    ctx = Dict.insert(Dict.empty({}), "x", Integer(42))
    Dict.get(ctx, "x") == Ok(Integer(42))

expect
    # StandingQueryId is a U128
    id : StandingQueryId
    id = 12345u128
    id == 12345u128

expect
    # StandingQueryPartId is a U64
    pid : StandingQueryPartId
    pid = 99u64
    pid == 99u64
```

- [ ] **Step 2: Create the package main.roc**

```roc
# packages/graph/standing/main.roc
package [
    StandingQueryResult,
] {
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
}
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/graph/standing/result/StandingQueryResult.roc`
Expected: 0 failed and 5 passed

- [ ] **Step 4: Commit**

```bash
git add packages/graph/standing/
git commit -m "phase-4a: standing query package scaffold + StandingQueryResult type"
```

---

### Task 2: ValueConstraint Module

**Files:**
- Create: `packages/graph/standing/ast/ValueConstraint.roc`
- Modify: `packages/graph/standing/main.roc` (add export)

- [ ] **Step 1: Create the ValueConstraint module**

```roc
# packages/graph/standing/ast/ValueConstraint.roc
module [
    ValueConstraint,
    LabelsConstraint,
    check_value,
    check_labels,
    satisfied_by_none,
]

import model.QuineValue exposing [QuineValue]

## A constraint on a property value used by LocalProperty standing queries.
ValueConstraint : [
    Equal QuineValue,
    NotEqual QuineValue,
    Any,
    None,
    Unconditional,
    Regex Str,
    ListContains (List QuineValue),
]

## A constraint on node labels used by Labels standing queries.
LabelsConstraint : [
    Contains (List Str),
    Unconditional,
]

## Check whether a present property value satisfies the constraint.
check_value : ValueConstraint, QuineValue -> Result Bool [RegexNotSupported]
check_value = |constraint, value|
    when constraint is
        Equal(expected) -> Ok(value == expected)
        NotEqual(expected) -> Ok(value != expected)
        Any -> Ok(Bool.true)
        None -> Ok(Bool.false)
        Unconditional -> Ok(Bool.true)
        Regex(_) -> Err(RegexNotSupported)
        ListContains(must_contain) ->
            when value is
                List(items) ->
                    all_present = List.all(must_contain, |needed|
                        List.contains(items, needed)
                    )
                    Ok(all_present)
                _ -> Ok(Bool.false)

## Whether the constraint is satisfied when the property is absent.
satisfied_by_none : ValueConstraint -> Bool
satisfied_by_none = |constraint|
    when constraint is
        Equal(_) -> Bool.false
        NotEqual(_) -> Bool.false
        Any -> Bool.false
        None -> Bool.true
        Unconditional -> Bool.true
        Regex(_) -> Bool.false
        ListContains(_) -> Bool.false

## Check whether a set of labels satisfies the constraint.
check_labels : LabelsConstraint, List Str -> Bool
check_labels = |constraint, labels|
    when constraint is
        Contains(must_contain) ->
            List.all(must_contain, |needed|
                List.contains(labels, needed)
            )
        Unconditional -> Bool.true

# ===== Tests =====

# --- ValueConstraint: Equal ---
expect check_value(Equal(Str("Alice")), Str("Alice")) == Ok(Bool.true)
expect check_value(Equal(Str("Alice")), Str("Bob")) == Ok(Bool.false)
expect check_value(Equal(Integer(42)), Integer(42)) == Ok(Bool.true)
expect check_value(Equal(Integer(42)), Integer(43)) == Ok(Bool.false)

# --- ValueConstraint: NotEqual ---
expect check_value(NotEqual(Str("Alice")), Str("Bob")) == Ok(Bool.true)
expect check_value(NotEqual(Str("Alice")), Str("Alice")) == Ok(Bool.false)

# --- ValueConstraint: Any ---
expect check_value(Any, Str("anything")) == Ok(Bool.true)
expect check_value(Any, Null) == Ok(Bool.true)

# --- ValueConstraint: None ---
expect check_value(None, Str("anything")) == Ok(Bool.false)

# --- ValueConstraint: Unconditional ---
expect check_value(Unconditional, Str("anything")) == Ok(Bool.true)

# --- ValueConstraint: Regex (not supported in Phase 4a) ---
expect check_value(Regex(".*"), Str("test")) == Err(RegexNotSupported)

# --- ValueConstraint: ListContains ---
expect check_value(ListContains([Str("a"), Str("b")]), List([Str("a"), Str("b"), Str("c")])) == Ok(Bool.true)
expect check_value(ListContains([Str("a"), Str("d")]), List([Str("a"), Str("b"), Str("c")])) == Ok(Bool.false)
expect check_value(ListContains([Str("a")]), Str("not a list")) == Ok(Bool.false)
expect check_value(ListContains([]), List([Str("a")])) == Ok(Bool.true)

# --- satisfied_by_none ---
expect satisfied_by_none(Equal(Str("x"))) == Bool.false
expect satisfied_by_none(NotEqual(Str("x"))) == Bool.false
expect satisfied_by_none(Any) == Bool.false
expect satisfied_by_none(None) == Bool.true
expect satisfied_by_none(Unconditional) == Bool.true
expect satisfied_by_none(Regex(".*")) == Bool.false
expect satisfied_by_none(ListContains([Str("a")])) == Bool.false

# --- LabelsConstraint: Contains ---
expect check_labels(Contains(["Person"]), ["Person", "Employee"]) == Bool.true
expect check_labels(Contains(["Person", "Admin"]), ["Person", "Employee"]) == Bool.false
expect check_labels(Contains(["Person"]), []) == Bool.false
expect check_labels(Contains([]), ["Person"]) == Bool.true

# --- LabelsConstraint: Unconditional ---
expect check_labels(Unconditional, ["Person"]) == Bool.true
expect check_labels(Unconditional, []) == Bool.true
```

- [ ] **Step 2: Update main.roc to export ValueConstraint**

```roc
# packages/graph/standing/main.roc
package [
    StandingQueryResult,
    ValueConstraint,
] {
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
}
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/graph/standing/ast/ValueConstraint.roc`
Expected: 0 failed and 22 passed

- [ ] **Step 4: Commit**

```bash
git add packages/graph/standing/
git commit -m "phase-4a: ValueConstraint and LabelsConstraint with check functions"
```

---

### Task 3: MvStandingQuery AST + Part ID Computation

**Files:**
- Create: `packages/graph/standing/ast/MvStandingQuery.roc`
- Modify: `packages/graph/standing/main.roc` (add export)

- [ ] **Step 1: Create the MvStandingQuery module**

This module defines the AST tagged union, `query_part_id` computation (FNV-1a hash of a canonical byte encoding), and `indexable_subqueries`.

```roc
# packages/graph/standing/ast/MvStandingQuery.roc
module [
    MvStandingQuery,
    WatchableEventType,
    query_part_id,
    indexable_subqueries,
    relevant_event_types,
    children,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.HalfEdge exposing [HalfEdge]
import model.EdgeDirection exposing [EdgeDirection]
import StandingQueryResult exposing [StandingQueryPartId]
import ValueConstraint exposing [ValueConstraint, LabelsConstraint]

## Placeholder for Expr type — Phase 4b will create the real expr package.
## For Phase 4a, FilterMap is defined in the AST but not usable without Expr.
Expr : [ExprPlaceholder]

## AST for a MultipleValues standing query.
MvStandingQuery : [
    UnitSq,
    Cross {
        queries : List MvStandingQuery,
        emit_subscriptions_lazily : Bool,
    },
    LocalProperty {
        prop_key : Str,
        constraint : ValueConstraint,
        aliased_as : Result Str [NoAlias],
    },
    Labels {
        aliased_as : Result Str [NoAlias],
        constraint : LabelsConstraint,
    },
    LocalId {
        aliased_as : Str,
        format_as_string : Bool,
    },
    AllProperties {
        aliased_as : Str,
    },
    SubscribeAcrossEdge {
        edge_name : Result Str [AnyEdge],
        edge_direction : Result EdgeDirection [AnyDirection],
        and_then : MvStandingQuery,
    },
    EdgeSubscriptionReciprocal {
        half_edge : HalfEdge,
        and_then_id : StandingQueryPartId,
    },
    FilterMap {
        condition : Result Expr [NoFilter],
        to_filter : MvStandingQuery,
        drop_existing : Bool,
        to_add : List { alias : Str, expr : Expr },
    },
]

## Local events a standing query may want to watch.
WatchableEventType : [
    PropertyChange Str,
    EdgeChange (Result Str [AnyLabel]),
    AnyPropertyChange,
]

## Compute a deterministic part ID for a standing query by FNV-1a hashing
## a canonical byte encoding of the AST.
query_part_id : MvStandingQuery -> StandingQueryPartId
query_part_id = |query|
    bytes = encode_query_bytes(query)
    hash_bytes_to_u64(bytes)

## Direct children of this query (not including deeper descendants).
children : MvStandingQuery -> List MvStandingQuery
children = |query|
    when query is
        UnitSq -> []
        Cross({ queries }) -> queries
        LocalProperty(_) -> []
        Labels(_) -> []
        LocalId(_) -> []
        AllProperties(_) -> []
        SubscribeAcrossEdge({ and_then }) -> [and_then]
        EdgeSubscriptionReciprocal(_) -> []
        FilterMap({ to_filter }) -> [to_filter]

## Which event types this query's state wants to be notified about.
relevant_event_types : MvStandingQuery, Str -> List WatchableEventType
relevant_event_types = |query, labels_property_key|
    when query is
        UnitSq -> []
        Cross(_) -> []
        LocalProperty({ prop_key }) -> [PropertyChange(prop_key)]
        Labels(_) -> [PropertyChange(labels_property_key)]
        LocalId(_) -> []
        AllProperties(_) -> [AnyPropertyChange]
        SubscribeAcrossEdge({ edge_name }) -> [EdgeChange(edge_name)]
        EdgeSubscriptionReciprocal({ half_edge }) -> [EdgeChange(Ok(half_edge.edge_type))]
        FilterMap(_) -> []

## Extract all globally-indexable subqueries (excludes EdgeSubscriptionReciprocal).
indexable_subqueries : MvStandingQuery -> List MvStandingQuery
indexable_subqueries = |query|
    collect_subqueries(query, [])

collect_subqueries : MvStandingQuery, List MvStandingQuery -> List MvStandingQuery
collect_subqueries = |query, acc|
    when query is
        EdgeSubscriptionReciprocal(_) -> acc
        _ ->
            # Check if this query's part_id is already in acc
            this_id = query_part_id(query)
            already_present = List.any(acc, |q| query_part_id(q) == this_id)
            if already_present then
                acc
            else
                with_self = List.append(acc, query)
                List.walk(children(query), with_self, |inner_acc, child|
                    collect_subqueries(child, inner_acc)
                )

## Canonical byte encoding for part ID computation.
## Each variant gets a unique tag byte, followed by deterministic field encoding.
encode_query_bytes : MvStandingQuery -> List U8
encode_query_bytes = |query|
    when query is
        UnitSq -> [0x01]
        Cross({ queries, emit_subscriptions_lazily }) ->
            tag = [0x02]
            lazy_byte = if emit_subscriptions_lazily then [0x01] else [0x00]
            child_bytes = List.join_map(queries, encode_query_bytes)
            count = List.len(queries) |> Num.to_u8
            List.join([tag, [count], lazy_byte, child_bytes])
        LocalProperty({ prop_key, constraint, aliased_as }) ->
            tag = [0x03]
            key_bytes = Str.to_utf8(prop_key)
            key_len = List.len(key_bytes) |> Num.to_u8
            constraint_bytes = encode_constraint_bytes(constraint)
            alias_bytes = when aliased_as is
                Ok(alias) -> List.concat([0x01], Str.to_utf8(alias))
                Err(NoAlias) -> [0x00]
            List.join([tag, [key_len], key_bytes, constraint_bytes, alias_bytes])
        Labels({ aliased_as, constraint }) ->
            tag = [0x04]
            constraint_bytes = encode_labels_constraint_bytes(constraint)
            alias_bytes = when aliased_as is
                Ok(alias) -> List.concat([0x01], Str.to_utf8(alias))
                Err(NoAlias) -> [0x00]
            List.join([tag, constraint_bytes, alias_bytes])
        LocalId({ aliased_as, format_as_string }) ->
            tag = [0x05]
            alias_bytes = Str.to_utf8(aliased_as)
            fmt = if format_as_string then [0x01] else [0x00]
            List.join([tag, alias_bytes, fmt])
        AllProperties({ aliased_as }) ->
            tag = [0x06]
            alias_bytes = Str.to_utf8(aliased_as)
            List.join([tag, alias_bytes])
        SubscribeAcrossEdge({ edge_name, edge_direction, and_then }) ->
            tag = [0x07]
            name_bytes = when edge_name is
                Ok(name) -> List.concat([0x01], Str.to_utf8(name))
                Err(AnyEdge) -> [0x00]
            dir_bytes = when edge_direction is
                Ok(Outgoing) -> [0x01]
                Ok(Incoming) -> [0x02]
                Ok(Undirected) -> [0x03]
                Err(AnyDirection) -> [0x00]
            then_bytes = encode_query_bytes(and_then)
            List.join([tag, name_bytes, dir_bytes, then_bytes])
        EdgeSubscriptionReciprocal({ half_edge, and_then_id }) ->
            tag = [0x08]
            edge_type_bytes = Str.to_utf8(half_edge.edge_type)
            other_bytes = QuineId.to_bytes(half_edge.other)
            id_bytes = encode_u64(and_then_id)
            List.join([tag, edge_type_bytes, other_bytes, id_bytes])
        FilterMap({ condition, to_filter, drop_existing, to_add }) ->
            tag = [0x09]
            cond_byte = when condition is
                Ok(_) -> [0x01]
                Err(NoFilter) -> [0x00]
            drop_byte = if drop_existing then [0x01] else [0x00]
            add_count = List.len(to_add) |> Num.to_u8
            filter_bytes = encode_query_bytes(to_filter)
            List.join([tag, cond_byte, drop_byte, [add_count], filter_bytes])

encode_constraint_bytes : ValueConstraint -> List U8
encode_constraint_bytes = |constraint|
    when constraint is
        Equal(_) -> [0x01]
        NotEqual(_) -> [0x02]
        Any -> [0x03]
        None -> [0x04]
        Unconditional -> [0x05]
        Regex(pattern) -> List.concat([0x06], Str.to_utf8(pattern))
        ListContains(_) -> [0x07]

encode_labels_constraint_bytes : LabelsConstraint -> List U8
encode_labels_constraint_bytes = |constraint|
    when constraint is
        Contains(labels) ->
            count = List.len(labels) |> Num.to_u8
            label_bytes = List.join_map(labels, Str.to_utf8)
            List.join([[0x01, count], label_bytes])
        Unconditional -> [0x02]

encode_u64 : U64 -> List U8
encode_u64 = |n|
    [
        Num.to_u8(Num.bitwise_and(n, 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 8), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 16), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 24), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 32), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 40), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 48), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 56), 0xFF)),
    ]

## FNV-1a hash producing a U64.
hash_bytes_to_u64 : List U8 -> U64
hash_bytes_to_u64 = |bytes|
    List.walk(
        bytes,
        14695981039346656037u64,
        |h, b|
            xored = Num.bitwise_xor(h, Num.to_u64(b))
            Num.mul_wrap(xored, 1099511628211u64),
    )

# ===== Tests =====

# --- query_part_id is deterministic ---
expect
    q = UnitSq
    query_part_id(q) == query_part_id(q)

expect
    q1 = LocalProperty({ prop_key: "name", constraint: Equal(Str("Alice")), aliased_as: Ok("n") })
    q2 = LocalProperty({ prop_key: "name", constraint: Equal(Str("Alice")), aliased_as: Ok("n") })
    query_part_id(q1) == query_part_id(q2)

# --- Different queries produce different IDs ---
expect
    q1 = LocalProperty({ prop_key: "name", constraint: Equal(Str("Alice")), aliased_as: Ok("n") })
    q2 = LocalProperty({ prop_key: "age", constraint: Equal(Integer(30)), aliased_as: Ok("a") })
    query_part_id(q1) != query_part_id(q2)

# --- children ---
expect children(UnitSq) == []
expect
    q1 = LocalProperty({ prop_key: "x", constraint: Any, aliased_as: Err(NoAlias) })
    q2 = LocalId({ aliased_as: "id", format_as_string: Bool.false })
    cross = Cross({ queries: [q1, q2], emit_subscriptions_lazily: Bool.false })
    List.len(children(cross)) == 2

expect
    inner = UnitSq
    edge = SubscribeAcrossEdge({ edge_name: Ok("KNOWS"), edge_direction: Ok(Outgoing), and_then: inner })
    List.len(children(edge)) == 1

# --- relevant_event_types ---
expect relevant_event_types(UnitSq, "__labels") == []
expect
    q = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Err(NoAlias) })
    relevant_event_types(q, "__labels") == [PropertyChange("name")]

expect
    q = Labels({ aliased_as: Err(NoAlias), constraint: Unconditional })
    relevant_event_types(q, "__labels") == [PropertyChange("__labels")]

expect
    q = AllProperties({ aliased_as: "props" })
    relevant_event_types(q, "__labels") == [AnyPropertyChange]

expect
    inner = UnitSq
    q = SubscribeAcrossEdge({ edge_name: Ok("KNOWS"), edge_direction: Ok(Outgoing), and_then: inner })
    relevant_event_types(q, "__labels") == [EdgeChange(Ok("KNOWS"))]

# --- indexable_subqueries ---
expect
    subs = indexable_subqueries(UnitSq)
    List.len(subs) == 1

expect
    q1 = LocalProperty({ prop_key: "x", constraint: Any, aliased_as: Err(NoAlias) })
    q2 = LocalId({ aliased_as: "id", format_as_string: Bool.false })
    cross = Cross({ queries: [q1, q2], emit_subscriptions_lazily: Bool.false })
    subs = indexable_subqueries(cross)
    # cross + q1 + q2 = 3
    List.len(subs) == 3

expect
    # EdgeSubscriptionReciprocal is excluded from indexable subqueries
    he = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    recip = EdgeSubscriptionReciprocal({ half_edge: he, and_then_id: 42 })
    subs = indexable_subqueries(recip)
    List.len(subs) == 0
```

- [ ] **Step 2: Update main.roc**

```roc
# packages/graph/standing/main.roc
package [
    StandingQueryResult,
    ValueConstraint,
    MvStandingQuery,
] {
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
}
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/graph/standing/ast/MvStandingQuery.roc`
Expected: 0 failed and 11 passed

- [ ] **Step 4: Commit**

```bash
git add packages/graph/standing/
git commit -m "phase-4a: MvStandingQuery AST with part ID computation and indexable_subqueries"
```

---

### Task 4: SqPartState Types + SqEffect + SqContext

**Files:**
- Create: `packages/graph/standing/state/SqPartState.roc`
- Modify: `packages/graph/standing/main.roc` (add export)

- [ ] **Step 1: Create SqPartState module with types only**

This module defines the state tagged union, effect type, context type, and subscription result type. The actual state logic lives in per-state modules (Tasks 5-9). This module provides the top-level dispatch functions that route to those modules.

```roc
# packages/graph/standing/state/SqPartState.roc
module [
    SqPartState,
    SqEffect,
    SqContext,
    SubscriptionResult,
    SqSubscription,
    SqMsgSubscriber,
    create_state,
]

import id.QuineId exposing [QuineId]
import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]
import StandingQueryResult exposing [StandingQueryId, StandingQueryPartId, QueryContext]
import MvStandingQuery exposing [MvStandingQuery]

## Per-node state for one part of a standing query.
SqPartState : [
    UnitState,
    CrossState {
        query_part_id : StandingQueryPartId,
        results_accumulator : Dict StandingQueryPartId (Result (List QueryContext) [Pending]),
    },
    LocalPropertyState {
        query_part_id : StandingQueryPartId,
        value_at_last_report : Result (Result PropertyValue [Absent]) [NeverReported],
        last_report_was_match : Result Bool [NeverReported],
    },
    LabelsState {
        query_part_id : StandingQueryPartId,
        last_reported_labels : Result (List Str) [NeverReported],
        last_report_was_match : Result Bool [NeverReported],
    },
    LocalIdState {
        query_part_id : StandingQueryPartId,
        result : List QueryContext,
    },
    AllPropertiesState {
        query_part_id : StandingQueryPartId,
        last_reported_properties : Result (Dict Str PropertyValue) [NeverReported],
    },
    SubscribeAcrossEdgeState {
        query_part_id : StandingQueryPartId,
        edge_results : Dict HalfEdge (Result (List QueryContext) [Pending]),
    },
    EdgeSubscriptionReciprocalState {
        query_part_id : StandingQueryPartId,
        half_edge : HalfEdge,
        and_then_id : StandingQueryPartId,
        currently_matching : Bool,
        cached_result : Result (List QueryContext) [NoCachedResult],
    },
    FilterMapState {
        query_part_id : StandingQueryPartId,
        kept_results : Result (List QueryContext) [NoCachedResult],
    },
]

## Effects produced by SQ state updates.
SqEffect : [
    CreateSubscription {
        on_node : QuineId,
        query : MvStandingQuery,
        global_id : StandingQueryId,
        subscriber_part_id : StandingQueryPartId,
    },
    CancelSubscription {
        on_node : QuineId,
        query_part_id : StandingQueryPartId,
        global_id : StandingQueryId,
    },
    ReportResults (List QueryContext),
]

## Context provided to SQ state functions.
SqContext : {
    lookup_query : StandingQueryPartId -> Result MvStandingQuery [NotFound],
    executing_node_id : QuineId,
    current_properties : Dict Str PropertyValue,
    labels_property_key : Str,
}

## Result from a subquery delivered to a parent state.
SubscriptionResult : {
    from : QuineId,
    query_part_id : StandingQueryPartId,
    global_id : StandingQueryId,
    for_query_part_id : StandingQueryPartId,
    result_group : List QueryContext,
}

## Who is subscribing to results.
SqMsgSubscriber : [
    NodeSubscriber {
        subscribing_node : QuineId,
        global_id : StandingQueryId,
        query_part_id : StandingQueryPartId,
    },
    GlobalSubscriber {
        global_id : StandingQueryId,
    },
]

## Tracks subscriptions for a query part on a node.
SqSubscription : {
    for_query : StandingQueryPartId,
    global_id : StandingQueryId,
    subscribers : List SqMsgSubscriber,
}

## Create the initial state for a standing query.
create_state : MvStandingQuery -> SqPartState
create_state = |query|
    part_id = MvStandingQuery.query_part_id(query)
    when query is
        UnitSq -> UnitState
        Cross(_) ->
            CrossState({
                query_part_id: part_id,
                results_accumulator: Dict.empty({}),
            })
        LocalProperty(_) ->
            LocalPropertyState({
                query_part_id: part_id,
                value_at_last_report: Err(NeverReported),
                last_report_was_match: Err(NeverReported),
            })
        Labels(_) ->
            LabelsState({
                query_part_id: part_id,
                last_reported_labels: Err(NeverReported),
                last_report_was_match: Err(NeverReported),
            })
        LocalId({ aliased_as, format_as_string: _ }) ->
            LocalIdState({
                query_part_id: part_id,
                result: [Dict.insert(Dict.empty({}), aliased_as, Null)],
            })
        AllProperties(_) ->
            AllPropertiesState({
                query_part_id: part_id,
                last_reported_properties: Err(NeverReported),
            })
        SubscribeAcrossEdge(_) ->
            SubscribeAcrossEdgeState({
                query_part_id: part_id,
                edge_results: Dict.empty({}),
            })
        EdgeSubscriptionReciprocal({ half_edge, and_then_id }) ->
            EdgeSubscriptionReciprocalState({
                query_part_id: part_id,
                half_edge,
                and_then_id,
                currently_matching: Bool.false,
                cached_result: Err(NoCachedResult),
            })
        FilterMap(_) ->
            FilterMapState({
                query_part_id: part_id,
                kept_results: Err(NoCachedResult),
            })

# ===== Tests =====

expect
    state = create_state(UnitSq)
    when state is
        UnitState -> Bool.true
        _ -> Bool.false

expect
    q = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    state = create_state(q)
    when state is
        LocalPropertyState({ value_at_last_report: Err(NeverReported) }) -> Bool.true
        _ -> Bool.false

expect
    q = LocalId({ aliased_as: "id", format_as_string: Bool.false })
    state = create_state(q)
    when state is
        LocalIdState({ result }) -> List.len(result) == 1
        _ -> Bool.false

expect
    q1 = LocalProperty({ prop_key: "x", constraint: Any, aliased_as: Err(NoAlias) })
    q2 = LocalId({ aliased_as: "id", format_as_string: Bool.false })
    cross = Cross({ queries: [q1, q2], emit_subscriptions_lazily: Bool.false })
    state = create_state(cross)
    when state is
        CrossState({ results_accumulator }) -> Dict.is_empty(results_accumulator)
        _ -> Bool.false

expect
    he = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    q = EdgeSubscriptionReciprocal({ half_edge: he, and_then_id: 42 })
    state = create_state(q)
    when state is
        EdgeSubscriptionReciprocalState({ currently_matching: Bool.false }) -> Bool.true
        _ -> Bool.false
```

- [ ] **Step 2: Update main.roc**

```roc
# packages/graph/standing/main.roc
package [
    StandingQueryResult,
    ValueConstraint,
    MvStandingQuery,
    SqPartState,
] {
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
}
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/graph/standing/state/SqPartState.roc`
Expected: 0 failed and 5 passed

- [ ] **Step 4: Commit**

```bash
git add packages/graph/standing/
git commit -m "phase-4a: SqPartState types, SqEffect, SqContext, create_state"
```

---

### Task 5: UnitState Logic

**Files:**
- Create: `packages/graph/standing/state/UnitState.roc`

- [ ] **Step 1: Create UnitState module**

UnitState is the simplest state — it always returns exactly one empty-row result. It never changes.

```roc
# packages/graph/standing/state/UnitState.roc
module [
    read_results,
    on_node_events,
    on_initialize,
]

import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import StandingQueryResult exposing [QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## UnitState always returns one empty-row result.
read_results : Dict Str PropertyValue, Str -> Result (List QueryContext) [NotReady]
read_results = |_properties, _labels_key|
    Ok([Dict.empty({})])

## UnitState is not affected by node events.
on_node_events : List NodeChangeEvent, SqContext -> { effects : List SqEffect, changed : Bool }
on_node_events = |_events, _ctx|
    { effects: [], changed: Bool.false }

## UnitState needs no initialization.
on_initialize : SqContext -> { effects : List SqEffect }
on_initialize = |_ctx|
    { effects: [] }

# ===== Tests =====

expect
    result = read_results(Dict.empty({}), "__labels")
    result == Ok([Dict.empty({})])

expect
    result = read_results(Dict.empty({}), "__labels")
    when result is
        Ok(rows) -> List.len(rows) == 1
        _ -> Bool.false

expect
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([1]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    result = on_node_events([], ctx)
    result.changed == Bool.false and List.is_empty(result.effects)
```

- [ ] **Step 2: Run tests**

Run: `roc test packages/graph/standing/state/UnitState.roc`
Expected: 0 failed and 3 passed

- [ ] **Step 3: Commit**

```bash
git add packages/graph/standing/state/UnitState.roc
git commit -m "phase-4a: UnitState — always returns one empty-row result"
```

---

### Task 6: LocalIdState Logic

**Files:**
- Create: `packages/graph/standing/state/LocalIdState.roc`

- [ ] **Step 1: Create LocalIdState module**

LocalIdState returns the node's own ID. The result is pre-computed during initialization (rehydrate in Scala terms). It never changes after creation.

```roc
# packages/graph/standing/state/LocalIdState.roc
module [
    rehydrate,
    read_results,
    on_node_events,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import StandingQueryResult exposing [QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## Pre-compute the result for a LocalIdState.
## Called once during state creation or on node wake.
rehydrate : Str, Bool, QuineId -> List QueryContext
rehydrate = |aliased_as, format_as_string, node_id|
    id_value =
        if format_as_string then
            Str(QuineId.to_hex_str(node_id))
        else
            Id(QuineId.to_bytes(node_id))
    [Dict.insert(Dict.empty({}), aliased_as, id_value)]

## LocalIdState always has results ready.
read_results : List QueryContext, Dict Str PropertyValue, Str -> Result (List QueryContext) [NotReady]
read_results = |pre_computed_result, _properties, _labels_key|
    Ok(pre_computed_result)

## LocalIdState is not affected by node events.
on_node_events : List NodeChangeEvent, SqContext -> { effects : List SqEffect, changed : Bool }
on_node_events = |_events, _ctx|
    { effects: [], changed: Bool.false }

# ===== Tests =====

expect
    # rehydrate with format_as_string=false produces Id value
    qid = QuineId.from_bytes([0x0A, 0x0B])
    result = rehydrate("nodeId", Bool.false, qid)
    when List.first(result) is
        Ok(row) ->
            when Dict.get(row, "nodeId") is
                Ok(Id(bytes)) -> bytes == [0x0A, 0x0B]
                _ -> Bool.false
        _ -> Bool.false

expect
    # rehydrate with format_as_string=true produces Str value
    qid = QuineId.from_bytes([0x0A])
    result = rehydrate("nodeId", Bool.true, qid)
    when List.first(result) is
        Ok(row) ->
            when Dict.get(row, "nodeId") is
                Ok(Str(s)) -> Str.starts_with(s, "0")
                _ -> Bool.false
        _ -> Bool.false

expect
    # read_results always returns the pre-computed result
    pre_computed = [Dict.insert(Dict.empty({}), "id", Integer(1))]
    result = read_results(pre_computed, Dict.empty({}), "__labels")
    result == Ok(pre_computed)

expect
    # on_node_events does nothing
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([1]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    result = on_node_events([], ctx)
    result.changed == Bool.false
```

- [ ] **Step 2: Run tests**

Run: `roc test packages/graph/standing/state/LocalIdState.roc`
Expected: 0 failed and 4 passed

- [ ] **Step 3: Commit**

```bash
git add packages/graph/standing/state/LocalIdState.roc
git commit -m "phase-4a: LocalIdState — returns pre-computed node ID"
```

---

### Task 7: LocalPropertyState Logic

**Files:**
- Create: `packages/graph/standing/state/LocalPropertyState.roc`

- [ ] **Step 1: Create LocalPropertyState module**

This is the most complex leaf state. It watches a single property key, checks a ValueConstraint, tracks the last-reported value, and emits results only when the match status or value changes.

```roc
# packages/graph/standing/state/LocalPropertyState.roc
module [
    on_node_events,
    read_results,
]

import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import ValueConstraint exposing [ValueConstraint, check_value, satisfied_by_none]
import SqPartState exposing [SqPartState, SqEffect]

## Internal type for the mutable fields of LocalPropertyState.
LocalPropertyFields : {
    query_part_id : StandingQueryPartId,
    value_at_last_report : Result (Result PropertyValue [Absent]) [NeverReported],
    last_report_was_match : Result Bool [NeverReported],
}

## Process node events for a LocalPropertyState.
##
## Returns the updated state fields, a list of effects, and whether anything changed.
on_node_events :
    LocalPropertyFields,
    List NodeChangeEvent,
    Str,
    ValueConstraint,
    Result Str [NoAlias]
    -> { fields : LocalPropertyFields, effects : List SqEffect, changed : Bool }
on_node_events = |fields, events, prop_key, constraint, aliased_as|
    # Find the relevant property event
    relevant = List.keep_if(events, |event|
        when event is
            PropertySet({ key }) -> key == prop_key
            PropertyRemoved({ key }) -> key == prop_key
            _ -> Bool.false
    )
    when List.first(relevant) is
        Ok(event) ->
            current_property = when event is
                PropertySet({ value }) -> Ok(value)
                PropertyRemoved(_) -> Err(Absent)
                _ -> Err(Absent)  # unreachable given keep_if above

            current_matches = when current_property is
                Ok(pv) ->
                    qv = PropertyValue.get_value(pv)
                    when check_value(constraint, qv) is
                        Ok(b) -> b
                        Err(RegexNotSupported) -> Bool.false
                Err(Absent) -> satisfied_by_none(constraint)

            { new_fields, effects, did_change } = when aliased_as is
                Ok(alias) ->
                    know_same = when fields.value_at_last_report is
                        Ok(prev) -> prev == current_property
                        Err(NeverReported) -> Bool.false

                    if !(know_same) and current_matches then
                        value_expr = when current_property is
                            Ok(pv) -> PropertyValue.get_value(pv)
                            Err(Absent) -> Null
                        result_row = Dict.insert(Dict.empty({}), alias, value_expr)
                        {
                            new_fields: {
                                fields &
                                value_at_last_report: Ok(current_property),
                                last_report_was_match: Ok(Bool.true),
                            },
                            effects: [ReportResults([result_row])],
                            did_change: Bool.true,
                        }
                    else if know_same then
                        {
                            new_fields: fields,
                            effects: [],
                            did_change: Bool.false,
                        }
                    else
                        # Not matching, was matching or unknown -> report empty
                        was_match = when fields.last_report_was_match is
                            Ok(b) -> b
                            Err(NeverReported) -> Bool.true  # conservative
                        if was_match then
                            {
                                new_fields: {
                                    fields &
                                    value_at_last_report: Ok(current_property),
                                    last_report_was_match: Ok(Bool.false),
                                },
                                effects: [ReportResults([])],
                                did_change: Bool.true,
                            }
                        else
                            {
                                new_fields: {
                                    fields &
                                    value_at_last_report: Ok(current_property),
                                    last_report_was_match: Ok(Bool.false),
                                },
                                effects: [],
                                did_change: Bool.false,
                            }

                Err(NoAlias) ->
                    prev_matched = when fields.last_report_was_match is
                        Ok(b) -> Ok(b)
                        Err(NeverReported) -> Err(NeverReported)

                    needs_report = when prev_matched is
                        Ok(prev) -> prev != current_matches
                        Err(NeverReported) -> Bool.true

                    if needs_report then
                        result_group = if current_matches then [Dict.empty({})] else []
                        {
                            new_fields: {
                                fields &
                                value_at_last_report: Ok(current_property),
                                last_report_was_match: Ok(current_matches),
                            },
                            effects: [ReportResults(result_group)],
                            did_change: Bool.true,
                        }
                    else
                        {
                            new_fields: {
                                fields &
                                value_at_last_report: Ok(current_property),
                                last_report_was_match: Ok(current_matches),
                            },
                            effects: [],
                            did_change: Bool.false,
                        }

            {
                fields: new_fields,
                effects,
                changed: did_change,
            }

        Err(_) ->
            # No relevant event — initialize if first call
            if fields.value_at_last_report == Err(NeverReported) then
                {
                    fields: {
                        fields &
                        value_at_last_report: Ok(Err(Absent)),
                        last_report_was_match: Ok(satisfied_by_none(constraint)),
                    },
                    effects: [],
                    changed: Bool.false,
                }
            else
                { fields, effects: [], changed: Bool.false }

## Read current results based on current properties.
read_results :
    Dict Str PropertyValue,
    Str,
    ValueConstraint,
    Result Str [NoAlias]
    -> Result (List QueryContext) [NotReady]
read_results = |properties, prop_key, constraint, aliased_as|
    current_property = Dict.get(properties, prop_key)
    current_matches = when current_property is
        Ok(pv) ->
            qv = PropertyValue.get_value(pv)
            when check_value(constraint, qv) is
                Ok(b) -> b
                Err(RegexNotSupported) -> Bool.false
        Err(_) -> satisfied_by_none(constraint)

    if !(current_matches) then
        Ok([])
    else
        when aliased_as is
            Ok(alias) ->
                value = when current_property is
                    Ok(pv) -> PropertyValue.get_value(pv)
                    Err(_) -> Null
                Ok([Dict.insert(Dict.empty({}), alias, value)])
            Err(NoAlias) ->
                Ok([Dict.empty({})])

# ===== Tests =====

expect
    # PropertySet matching Equal constraint -> reports result with alias
    fields : LocalPropertyFields
    fields = { query_part_id: 1, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }
    events = [PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })]
    result = on_node_events(fields, events, "name", Equal(Str("Alice")), Ok("n"))
    result.changed == Bool.true and List.len(result.effects) == 1

expect
    # PropertySet not matching Equal constraint -> reports empty (was unknown/matching)
    fields : LocalPropertyFields
    fields = { query_part_id: 1, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }
    events = [PropertySet({ key: "name", value: PropertyValue.from_value(Str("Bob")) })]
    result = on_node_events(fields, events, "name", Equal(Str("Alice")), Ok("n"))
    result.changed == Bool.true
    and
    when List.first(result.effects) is
        Ok(ReportResults(rows)) -> List.is_empty(rows)
        _ -> Bool.false

expect
    # No alias: matching -> empty positive row
    fields : LocalPropertyFields
    fields = { query_part_id: 1, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }
    events = [PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })]
    result = on_node_events(fields, events, "name", Equal(Str("Alice")), Err(NoAlias))
    result.changed == Bool.true
    and
    when List.first(result.effects) is
        Ok(ReportResults(rows)) -> List.len(rows) == 1
        _ -> Bool.false

expect
    # PropertyRemoved with None constraint -> matches
    fields : LocalPropertyFields
    fields = { query_part_id: 1, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }
    events = [PropertyRemoved({ key: "x", previous_value: PropertyValue.from_value(Integer(1)) })]
    result = on_node_events(fields, events, "x", None, Err(NoAlias))
    result.changed == Bool.true

expect
    # No relevant event, first call -> initializes state
    fields : LocalPropertyFields
    fields = { query_part_id: 1, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    result = on_node_events(fields, [EdgeAdded(edge)], "name", Any, Ok("n"))
    result.fields.value_at_last_report == Ok(Err(Absent))

expect
    # read_results: property present and matching
    props = Dict.insert(Dict.empty({}), "name", PropertyValue.from_value(Str("Alice")))
    result = read_results(props, "name", Equal(Str("Alice")), Ok("n"))
    when result is
        Ok(rows) -> List.len(rows) == 1
        _ -> Bool.false

expect
    # read_results: property absent, Any constraint -> no match
    result = read_results(Dict.empty({}), "name", Any, Ok("n"))
    result == Ok([])

expect
    # read_results: property absent, None constraint -> matches
    result = read_results(Dict.empty({}), "name", None, Err(NoAlias))
    when result is
        Ok(rows) -> List.len(rows) == 1
        _ -> Bool.false

expect
    # Repeated same value -> no change
    pv = PropertyValue.from_value(Str("Alice"))
    fields : LocalPropertyFields
    fields = { query_part_id: 1, value_at_last_report: Ok(Ok(pv)), last_report_was_match: Ok(Bool.true) }
    events = [PropertySet({ key: "name", value: pv })]
    result = on_node_events(fields, events, "name", Equal(Str("Alice")), Ok("n"))
    result.changed == Bool.false
```

- [ ] **Step 2: Run tests**

Run: `roc test packages/graph/standing/state/LocalPropertyState.roc`
Expected: 0 failed and 9 passed

- [ ] **Step 3: Commit**

```bash
git add packages/graph/standing/state/LocalPropertyState.roc
git commit -m "phase-4a: LocalPropertyState — property watching with constraints"
```

---

### Task 8: LabelsState Logic

**Files:**
- Create: `packages/graph/standing/state/LabelsState.roc`

- [ ] **Step 1: Create LabelsState module**

LabelsState is structurally similar to LocalPropertyState but watches the labels property specifically. Labels are stored as a `QuineValue.List` of `QuineValue.Str` under a configurable property key.

```roc
# packages/graph/standing/state/LabelsState.roc
module [
    on_node_events,
    read_results,
    extract_labels,
]

import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import ValueConstraint exposing [LabelsConstraint, check_labels]
import SqPartState exposing [SqEffect]

## Internal fields for LabelsState.
LabelsFields : {
    query_part_id : StandingQueryPartId,
    last_reported_labels : Result (List Str) [NeverReported],
    last_report_was_match : Result Bool [NeverReported],
}

## Extract label strings from a QuineValue (expected to be List of Str).
extract_labels : Result QuineValue [Absent] -> List Str
extract_labels = |maybe_value|
    when maybe_value is
        Ok(List(items)) ->
            List.keep_oks(items, |item|
                when item is
                    Str(s) -> Ok(s)
                    _ -> Err({})
            )
        _ -> []

## Process node events for LabelsState.
on_node_events :
    LabelsFields,
    List NodeChangeEvent,
    Str,
    LabelsConstraint,
    Result Str [NoAlias]
    -> { fields : LabelsFields, effects : List SqEffect, changed : Bool }
on_node_events = |fields, events, labels_key, constraint, aliased_as|
    relevant = List.keep_if(events, |event|
        when event is
            PropertySet({ key }) -> key == labels_key
            PropertyRemoved({ key }) -> key == labels_key
            _ -> Bool.false
    )
    when List.first(relevant) is
        Ok(event) ->
            labels_value = when event is
                PropertySet({ value }) -> Ok(PropertyValue.get_value(value))
                PropertyRemoved(_) -> Err(Absent)
                _ -> Err(Absent)
            current_labels = extract_labels(labels_value)
            matched = check_labels(constraint, current_labels)

            { new_fields, effects, did_change } = when aliased_as is
                Ok(alias) ->
                    know_same = when fields.last_reported_labels is
                        Ok(prev) -> prev == current_labels
                        Err(NeverReported) -> Bool.false
                    if !(know_same) and matched then
                        labels_expr = List(List.map(current_labels, |l| Str(l)))
                        result_row = Dict.insert(Dict.empty({}), alias, labels_expr)
                        {
                            new_fields: { fields & last_reported_labels: Ok(current_labels), last_report_was_match: Ok(Bool.true) },
                            effects: [ReportResults([result_row])],
                            did_change: Bool.true,
                        }
                    else if know_same then
                        { new_fields: fields, effects: [], did_change: Bool.false }
                    else
                        was_match = when fields.last_report_was_match is
                            Ok(b) -> b
                            Err(NeverReported) -> Bool.true
                        if was_match then
                            {
                                new_fields: { fields & last_reported_labels: Ok(current_labels), last_report_was_match: Ok(Bool.false) },
                                effects: [ReportResults([])],
                                did_change: Bool.true,
                            }
                        else
                            {
                                new_fields: { fields & last_reported_labels: Ok(current_labels), last_report_was_match: Ok(Bool.false) },
                                effects: [],
                                did_change: Bool.false,
                            }
                Err(NoAlias) ->
                    prev_matched = when fields.last_report_was_match is
                        Ok(b) -> Ok(b)
                        Err(NeverReported) -> Err(NeverReported)
                    needs_report = when prev_matched is
                        Ok(prev) -> prev != matched
                        Err(NeverReported) -> Bool.true
                    if needs_report then
                        result_group = if matched then [Dict.empty({})] else []
                        {
                            new_fields: { fields & last_reported_labels: Ok(current_labels), last_report_was_match: Ok(matched) },
                            effects: [ReportResults(result_group)],
                            did_change: Bool.true,
                        }
                    else
                        {
                            new_fields: { fields & last_reported_labels: Ok(current_labels), last_report_was_match: Ok(matched) },
                            effects: [],
                            did_change: Bool.false,
                        }

            { fields: new_fields, effects, changed: did_change }

        Err(_) ->
            if fields.last_reported_labels == Err(NeverReported) then
                {
                    fields: { fields & last_reported_labels: Ok([]), last_report_was_match: Ok(check_labels(constraint, [])) },
                    effects: [],
                    changed: Bool.false,
                }
            else
                { fields, effects: [], changed: Bool.false }

## Read current results based on current properties.
read_results :
    Dict Str PropertyValue,
    Str,
    LabelsConstraint,
    Result Str [NoAlias]
    -> Result (List QueryContext) [NotReady]
read_results = |properties, labels_key, constraint, aliased_as|
    labels_value = when Dict.get(properties, labels_key) is
        Ok(pv) -> Ok(PropertyValue.get_value(pv))
        Err(_) -> Err(Absent)
    labels = extract_labels(labels_value)
    matched = check_labels(constraint, labels)
    if !(matched) then
        Ok([])
    else
        when aliased_as is
            Ok(alias) ->
                labels_expr = List(List.map(labels, |l| Str(l)))
                Ok([Dict.insert(Dict.empty({}), alias, labels_expr)])
            Err(NoAlias) ->
                Ok([Dict.empty({})])

# ===== Tests =====

expect extract_labels(Ok(List([Str("Person"), Str("Employee")]))) == ["Person", "Employee"]
expect extract_labels(Ok(List([]))) == []
expect extract_labels(Err(Absent)) == []
expect extract_labels(Ok(Str("not a list"))) == []

expect
    # Contains constraint: labels present and matching
    fields : LabelsFields
    fields = { query_part_id: 1, last_reported_labels: Err(NeverReported), last_report_was_match: Err(NeverReported) }
    pv = PropertyValue.from_value(List([Str("Person"), Str("Employee")]))
    events = [PropertySet({ key: "__labels", value: pv })]
    result = on_node_events(fields, events, "__labels", Contains(["Person"]), Err(NoAlias))
    result.changed == Bool.true

expect
    # Contains constraint: labels present but not matching
    fields : LabelsFields
    fields = { query_part_id: 1, last_reported_labels: Err(NeverReported), last_report_was_match: Err(NeverReported) }
    pv = PropertyValue.from_value(List([Str("Employee")]))
    events = [PropertySet({ key: "__labels", value: pv })]
    result = on_node_events(fields, events, "__labels", Contains(["Person"]), Err(NoAlias))
    result.changed == Bool.true
    and
    when List.first(result.effects) is
        Ok(ReportResults(rows)) -> List.is_empty(rows)
        _ -> Bool.false

expect
    # read_results with matching labels
    props = Dict.insert(Dict.empty({}), "__labels", PropertyValue.from_value(List([Str("Person")])))
    result = read_results(props, "__labels", Contains(["Person"]), Ok("labels"))
    when result is
        Ok(rows) -> List.len(rows) == 1
        _ -> Bool.false

expect
    # read_results with no labels property
    result = read_results(Dict.empty({}), "__labels", Contains(["Person"]), Ok("labels"))
    result == Ok([])
```

- [ ] **Step 2: Run tests**

Run: `roc test packages/graph/standing/state/LabelsState.roc`
Expected: 0 failed and 8 passed

- [ ] **Step 3: Commit**

```bash
git add packages/graph/standing/state/LabelsState.roc
git commit -m "phase-4a: LabelsState — label watching with constraints"
```

---

### Task 9: AllPropertiesState Logic

**Files:**
- Create: `packages/graph/standing/state/AllPropertiesState.roc`

- [ ] **Step 1: Create AllPropertiesState module**

AllPropertiesState watches all properties (except the labels property) and emits the full property map as a single result column whenever any property changes.

```roc
# packages/graph/standing/state/AllPropertiesState.roc
module [
    on_node_events,
    read_results,
]

import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect]

## Internal fields for AllPropertiesState.
AllPropertiesFields : {
    query_part_id : StandingQueryPartId,
    last_reported_properties : Result (Dict Str PropertyValue) [NeverReported],
}

## Build the properties map as a QuineValue, excluding the labels property.
properties_as_quine_value : Dict Str PropertyValue, Str -> QuineValue
properties_as_quine_value = |properties, labels_key|
    entries = Dict.walk(properties, [], |acc, key, pv|
        if key == labels_key then
            acc
        else
            List.append(acc, { key, value: PropertyValue.get_value(pv) })
    )
    # Build a QuineValue.Map from the entries
    map_dict = List.walk(entries, Dict.empty({}), |acc, entry|
        Dict.insert(acc, entry.key, entry.value)
    )
    Map(map_dict)

## Process node events for AllPropertiesState.
on_node_events :
    AllPropertiesFields,
    List NodeChangeEvent,
    Str,
    Str,
    Dict Str PropertyValue
    -> { fields : AllPropertiesFields, effects : List SqEffect, changed : Bool }
on_node_events = |fields, events, aliased_as, labels_key, current_properties|
    has_property_change = List.any(events, |event|
        when event is
            PropertySet({ key }) -> key != labels_key
            PropertyRemoved({ key }) -> key != labels_key
            _ -> Bool.false
    )
    if has_property_change then
        same_as_before = when fields.last_reported_properties is
            Ok(prev) -> prev == current_properties
            Err(NeverReported) -> Bool.false
        if same_as_before then
            { fields, effects: [], changed: Bool.false }
        else
            props_value = properties_as_quine_value(current_properties, labels_key)
            result_row = Dict.insert(Dict.empty({}), aliased_as, props_value)
            {
                fields: { fields & last_reported_properties: Ok(current_properties) },
                effects: [ReportResults([result_row])],
                changed: Bool.true,
            }
    else
        { fields, effects: [], changed: Bool.false }

## Read current results from properties.
read_results : Dict Str PropertyValue, Str, Str -> Result (List QueryContext) [NotReady]
read_results = |properties, aliased_as, labels_key|
    props_value = properties_as_quine_value(properties, labels_key)
    result_row = Dict.insert(Dict.empty({}), aliased_as, props_value)
    Ok([result_row])

# ===== Tests =====

expect
    # Properties as QuineValue excludes labels
    props = Dict.empty({})
        |> Dict.insert("name", PropertyValue.from_value(Str("Alice")))
        |> Dict.insert("__labels", PropertyValue.from_value(List([Str("Person")])))
    result = properties_as_quine_value(props, "__labels")
    when result is
        Map(d) -> Dict.contains(d, "name") and !(Dict.contains(d, "__labels"))
        _ -> Bool.false

expect
    # on_node_events: property change triggers report
    fields : AllPropertiesFields
    fields = { query_part_id: 1, last_reported_properties: Err(NeverReported) }
    pv = PropertyValue.from_value(Str("Alice"))
    events = [PropertySet({ key: "name", value: pv })]
    current = Dict.insert(Dict.empty({}), "name", pv)
    result = on_node_events(fields, events, "props", "__labels", current)
    result.changed == Bool.true and List.len(result.effects) == 1

expect
    # on_node_events: labels change does NOT trigger report
    fields : AllPropertiesFields
    fields = { query_part_id: 1, last_reported_properties: Err(NeverReported) }
    pv = PropertyValue.from_value(List([Str("Person")]))
    events = [PropertySet({ key: "__labels", value: pv })]
    current = Dict.insert(Dict.empty({}), "__labels", pv)
    result = on_node_events(fields, events, "props", "__labels", current)
    result.changed == Bool.false

expect
    # on_node_events: same properties as last report -> no change
    pv = PropertyValue.from_value(Str("Alice"))
    current = Dict.insert(Dict.empty({}), "name", pv)
    fields : AllPropertiesFields
    fields = { query_part_id: 1, last_reported_properties: Ok(current) }
    events = [PropertySet({ key: "name", value: pv })]
    result = on_node_events(fields, events, "props", "__labels", current)
    result.changed == Bool.false

expect
    # read_results always returns current properties
    props = Dict.insert(Dict.empty({}), "age", PropertyValue.from_value(Integer(30)))
    result = read_results(props, "props", "__labels")
    when result is
        Ok(rows) -> List.len(rows) == 1
        _ -> Bool.false
```

- [ ] **Step 2: Run tests**

Run: `roc test packages/graph/standing/state/AllPropertiesState.roc`
Expected: 0 failed and 5 passed

- [ ] **Step 3: Commit**

```bash
git add packages/graph/standing/state/AllPropertiesState.roc
git commit -m "phase-4a: AllPropertiesState — all-property watching with dedup"
```

---

### Task 10: WatchableEventIndex

**Files:**
- Create: `packages/graph/standing/index/WatchableEventIndex.roc`
- Modify: `packages/graph/standing/main.roc` (add export)

- [ ] **Step 1: Create WatchableEventIndex module**

```roc
# packages/graph/standing/index/WatchableEventIndex.roc
module [
    WatchableEventIndex,
    SqSubscriber,
    empty,
    register_standing_query,
    unregister_standing_query,
    subscribers_for_event,
]

import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]
import model.NodeEvent exposing [NodeChangeEvent]
import StandingQueryResult exposing [StandingQueryId, StandingQueryPartId]
import MvStandingQuery exposing [WatchableEventType]

## Identifies an SQ state registered in the event index.
SqSubscriber : {
    global_id : StandingQueryId,
    part_id : StandingQueryPartId,
}

## Per-node index mapping events to interested SQ subscribers.
WatchableEventIndex : {
    watching_for_property : Dict Str (List SqSubscriber),
    watching_for_edge : Dict Str (List SqSubscriber),
    watching_for_any_edge : List SqSubscriber,
    watching_for_any_property : List SqSubscriber,
}

## Create an empty index.
empty : WatchableEventIndex
empty = {
    watching_for_property: Dict.empty({}),
    watching_for_edge: Dict.empty({}),
    watching_for_any_edge: [],
    watching_for_any_property: [],
}

## Register a subscriber for an event type. Returns initial events from existing node state.
register_standing_query :
    WatchableEventIndex,
    SqSubscriber,
    WatchableEventType,
    Dict Str PropertyValue,
    Dict Str (List HalfEdge)
    -> { index : WatchableEventIndex, initial_events : List NodeChangeEvent }
register_standing_query = |index, subscriber, event_type, properties, edges|
    when event_type is
        PropertyChange(key) ->
            existing = Dict.get(index.watching_for_property, key) |> Result.with_default([])
            new_list = List.append(existing, subscriber)
            new_prop_map = Dict.insert(index.watching_for_property, key, new_list)
            initial = when Dict.get(properties, key) is
                Ok(pv) -> [PropertySet({ key, value: pv })]
                Err(_) -> []
            { index: { index & watching_for_property: new_prop_map }, initial_events: initial }

        AnyPropertyChange ->
            new_any = List.append(index.watching_for_any_property, subscriber)
            initial = Dict.walk(properties, [], |acc, key, pv|
                List.append(acc, PropertySet({ key, value: pv }))
            )
            { index: { index & watching_for_any_property: new_any }, initial_events: initial }

        EdgeChange(Ok(key)) ->
            existing = Dict.get(index.watching_for_edge, key) |> Result.with_default([])
            new_list = List.append(existing, subscriber)
            new_edge_map = Dict.insert(index.watching_for_edge, key, new_list)
            initial = when Dict.get(edges, key) is
                Ok(edge_list) -> List.map(edge_list, |he| EdgeAdded(he))
                Err(_) -> []
            { index: { index & watching_for_edge: new_edge_map }, initial_events: initial }

        EdgeChange(Err(AnyLabel)) ->
            new_any = List.append(index.watching_for_any_edge, subscriber)
            initial = Dict.walk(edges, [], |acc, _key, edge_list|
                List.concat(acc, List.map(edge_list, |he| EdgeAdded(he)))
            )
            { index: { index & watching_for_any_edge: new_any }, initial_events: initial }

## Unregister a subscriber from an event type.
unregister_standing_query :
    WatchableEventIndex,
    SqSubscriber,
    WatchableEventType
    -> WatchableEventIndex
unregister_standing_query = |index, subscriber, event_type|
    when event_type is
        PropertyChange(key) ->
            when Dict.get(index.watching_for_property, key) is
                Ok(list) ->
                    filtered = List.keep_if(list, |s| s != subscriber)
                    new_map = if List.is_empty(filtered) then
                        Dict.remove(index.watching_for_property, key)
                    else
                        Dict.insert(index.watching_for_property, key, filtered)
                    { index & watching_for_property: new_map }
                Err(_) -> index

        AnyPropertyChange ->
            filtered = List.keep_if(index.watching_for_any_property, |s| s != subscriber)
            { index & watching_for_any_property: filtered }

        EdgeChange(Ok(key)) ->
            when Dict.get(index.watching_for_edge, key) is
                Ok(list) ->
                    filtered = List.keep_if(list, |s| s != subscriber)
                    new_map = if List.is_empty(filtered) then
                        Dict.remove(index.watching_for_edge, key)
                    else
                        Dict.insert(index.watching_for_edge, key, filtered)
                    { index & watching_for_edge: new_map }
                Err(_) -> index

        EdgeChange(Err(AnyLabel)) ->
            filtered = List.keep_if(index.watching_for_any_edge, |s| s != subscriber)
            { index & watching_for_any_edge: filtered }

## Find all subscribers interested in a given node change event.
subscribers_for_event :
    WatchableEventIndex,
    NodeChangeEvent
    -> List SqSubscriber
subscribers_for_event = |index, event|
    when event is
        PropertySet({ key }) ->
            specific = Dict.get(index.watching_for_property, key) |> Result.with_default([])
            List.concat(specific, index.watching_for_any_property)

        PropertyRemoved({ key }) ->
            specific = Dict.get(index.watching_for_property, key) |> Result.with_default([])
            List.concat(specific, index.watching_for_any_property)

        EdgeAdded(half_edge) ->
            specific = Dict.get(index.watching_for_edge, half_edge.edge_type) |> Result.with_default([])
            List.concat(specific, index.watching_for_any_edge)

        EdgeRemoved(half_edge) ->
            specific = Dict.get(index.watching_for_edge, half_edge.edge_type) |> Result.with_default([])
            List.concat(specific, index.watching_for_any_edge)

# ===== Tests =====

expect
    # Empty index returns no subscribers
    idx = empty
    pv = PropertyValue.from_value(Str("x"))
    subs = subscribers_for_event(idx, PropertySet({ key: "name", value: pv }))
    List.is_empty(subs)

expect
    # Register for PropertyChange, then lookup
    sub = { global_id: 1u128, part_id: 10u64 }
    result = register_standing_query(empty, sub, PropertyChange("name"), Dict.empty({}), Dict.empty({}))
    subs = subscribers_for_event(result.index, PropertySet({ key: "name", value: PropertyValue.from_value(Str("x")) }))
    List.len(subs) == 1

expect
    # PropertyChange registration returns initial event if property exists
    sub = { global_id: 1u128, part_id: 10u64 }
    pv = PropertyValue.from_value(Str("Alice"))
    props = Dict.insert(Dict.empty({}), "name", pv)
    result = register_standing_query(empty, sub, PropertyChange("name"), props, Dict.empty({}))
    List.len(result.initial_events) == 1

expect
    # PropertyChange registration returns no initial event if property absent
    sub = { global_id: 1u128, part_id: 10u64 }
    result = register_standing_query(empty, sub, PropertyChange("name"), Dict.empty({}), Dict.empty({}))
    List.is_empty(result.initial_events)

expect
    # EdgeChange registration returns initial events for existing edges
    sub = { global_id: 1u128, part_id: 10u64 }
    he = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    edges = Dict.insert(Dict.empty({}), "KNOWS", [he])
    result = register_standing_query(empty, sub, EdgeChange(Ok("KNOWS")), Dict.empty({}), edges)
    List.len(result.initial_events) == 1

expect
    # AnyPropertyChange gets all property events
    sub = { global_id: 1u128, part_id: 10u64 }
    pv = PropertyValue.from_value(Str("x"))
    props = Dict.insert(Dict.empty({}), "a", pv) |> Dict.insert("b", pv)
    result = register_standing_query(empty, sub, AnyPropertyChange, props, Dict.empty({}))
    List.len(result.initial_events) == 2

expect
    # Unregister removes subscriber
    sub = { global_id: 1u128, part_id: 10u64 }
    result = register_standing_query(empty, sub, PropertyChange("name"), Dict.empty({}), Dict.empty({}))
    idx2 = unregister_standing_query(result.index, sub, PropertyChange("name"))
    subs = subscribers_for_event(idx2, PropertySet({ key: "name", value: PropertyValue.from_value(Str("x")) }))
    List.is_empty(subs)

expect
    # Subscriber for unrelated property gets nothing
    sub = { global_id: 1u128, part_id: 10u64 }
    result = register_standing_query(empty, sub, PropertyChange("name"), Dict.empty({}), Dict.empty({}))
    subs = subscribers_for_event(result.index, PropertySet({ key: "age", value: PropertyValue.from_value(Integer(30)) }))
    List.is_empty(subs)

expect
    # AnyPropertyChange subscriber gets notified on any property
    sub = { global_id: 1u128, part_id: 10u64 }
    result = register_standing_query(empty, sub, AnyPropertyChange, Dict.empty({}), Dict.empty({}))
    subs = subscribers_for_event(result.index, PropertySet({ key: "anything", value: PropertyValue.from_value(Str("x")) }))
    List.len(subs) == 1

expect
    # EdgeChange(AnyLabel) subscriber gets notified on any edge
    sub = { global_id: 1u128, part_id: 10u64 }
    result = register_standing_query(empty, sub, EdgeChange(Err(AnyLabel)), Dict.empty({}), Dict.empty({}))
    he = { edge_type: "FOLLOWS", direction: Outgoing, other: QuineId.from_bytes([2]) }
    subs = subscribers_for_event(result.index, EdgeAdded(he))
    List.len(subs) == 1
```

- [ ] **Step 2: Update main.roc**

```roc
# packages/graph/standing/main.roc
package [
    StandingQueryResult,
    ValueConstraint,
    MvStandingQuery,
    SqPartState,
    WatchableEventIndex,
] {
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
}
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/graph/standing/index/WatchableEventIndex.roc`
Expected: 0 failed and 10 passed

- [ ] **Step 4: Commit**

```bash
git add packages/graph/standing/
git commit -m "phase-4a: WatchableEventIndex — event-to-subscriber dispatch"
```

---

### Task 11: ResultDiff + ResultsReporter

**Files:**
- Create: `packages/graph/standing/result/ResultDiff.roc`

- [ ] **Step 1: Create ResultDiff module**

```roc
# packages/graph/standing/result/ResultDiff.roc
module [
    generate_result_reports,
    ResultsReporter,
    new_reporter,
    apply_and_emit_results,
]

import model.QuineValue exposing [QuineValue]
import StandingQueryResult exposing [StandingQueryResult, QueryContext]

## Tracks last-reported results for a top-level SQ, enabling result diffing.
ResultsReporter : {
    last_results : List QueryContext,
}

## Create a new reporter with no previous results.
new_reporter : ResultsReporter
new_reporter = { last_results: [] }

## Compute the diff between old and new result groups.
##
## Returns positive matches for newly-added rows, and optionally
## cancellation results for removed rows.
generate_result_reports :
    List QueryContext,
    List QueryContext,
    Bool
    -> List StandingQueryResult
generate_result_reports = |old_results, new_results, include_cancellations|
    added = list_diff(new_results, old_results)
    removed = list_diff(old_results, new_results)

    positive = List.map(added, |ctx|
        { is_positive_match: Bool.true, data: ctx }
    )
    cancellations = if include_cancellations then
        List.map(removed, |ctx|
            { is_positive_match: Bool.false, data: ctx }
        )
    else
        []

    List.concat(positive, cancellations)

## Apply a new result group to the reporter, returning updated reporter and reports.
apply_and_emit_results :
    ResultsReporter,
    List QueryContext,
    Bool
    -> { reporter : ResultsReporter, reports : List StandingQueryResult }
apply_and_emit_results = |reporter, new_results, include_cancellations|
    reports = generate_result_reports(reporter.last_results, new_results, include_cancellations)
    { reporter: { last_results: new_results }, reports }

## Compute elements in `a` that are not in `b` (multiset diff).
## For each element in `a`, it is included in the result only if it appears
## more times in `a` than in `b`.
list_diff : List QueryContext, List QueryContext -> List QueryContext
list_diff = |a_list, b_list|
    # Simple O(n*m) approach — fine for the small result sets in SQ results
    List.walk(a_list, { result: [], remaining_b: b_list }, |acc, item|
        idx = List.find_first_index(acc.remaining_b, |b| b == item)
        when idx is
            Ok(i) ->
                { acc & remaining_b: List.drop_at(acc.remaining_b, i) }
            Err(_) ->
                { acc & result: List.append(acc.result, item) }
    ).result

# ===== Tests =====

expect
    # Empty -> non-empty: all positive
    reports = generate_result_reports(
        [],
        [Dict.insert(Dict.empty({}), "name", Str("Alice"))],
        Bool.true,
    )
    List.len(reports) == 1
    and
    when List.first(reports) is
        Ok(r) -> r.is_positive_match == Bool.true
        _ -> Bool.false

expect
    # Non-empty -> empty: all cancellations (when enabled)
    reports = generate_result_reports(
        [Dict.insert(Dict.empty({}), "name", Str("Alice"))],
        [],
        Bool.true,
    )
    List.len(reports) == 1
    and
    when List.first(reports) is
        Ok(r) -> r.is_positive_match == Bool.false
        _ -> Bool.false

expect
    # Non-empty -> empty: no cancellations when disabled
    reports = generate_result_reports(
        [Dict.insert(Dict.empty({}), "name", Str("Alice"))],
        [],
        Bool.false,
    )
    List.is_empty(reports)

expect
    # Same results -> no reports
    row = Dict.insert(Dict.empty({}), "x", Integer(1))
    reports = generate_result_reports([row], [row], Bool.true)
    List.is_empty(reports)

expect
    # Partial overlap: one added, one removed
    row1 = Dict.insert(Dict.empty({}), "x", Integer(1))
    row2 = Dict.insert(Dict.empty({}), "x", Integer(2))
    row3 = Dict.insert(Dict.empty({}), "x", Integer(3))
    reports = generate_result_reports([row1, row2], [row2, row3], Bool.true)
    # row3 added (positive), row1 removed (cancellation)
    List.len(reports) == 2

expect
    # ResultsReporter: apply first results
    reporter = new_reporter
    row = Dict.insert(Dict.empty({}), "name", Str("Alice"))
    result = apply_and_emit_results(reporter, [row], Bool.true)
    List.len(result.reports) == 1 and result.reporter.last_results == [row]

expect
    # ResultsReporter: apply same results again -> no reports
    row = Dict.insert(Dict.empty({}), "name", Str("Alice"))
    reporter = { last_results: [row] }
    result = apply_and_emit_results(reporter, [row], Bool.true)
    List.is_empty(result.reports)

expect
    # list_diff: basic multiset diff
    a = [Dict.insert(Dict.empty({}), "x", Integer(1)), Dict.insert(Dict.empty({}), "x", Integer(2))]
    b = [Dict.insert(Dict.empty({}), "x", Integer(1))]
    diff = list_diff(a, b)
    List.len(diff) == 1

expect
    # list_diff: duplicate handling
    row = Dict.insert(Dict.empty({}), "x", Integer(1))
    diff = list_diff([row, row, row], [row])
    List.len(diff) == 2
```

- [ ] **Step 2: Run tests**

Run: `roc test packages/graph/standing/result/ResultDiff.roc`
Expected: 0 failed and 9 passed

- [ ] **Step 3: Commit**

```bash
git add packages/graph/standing/result/ResultDiff.roc
git commit -m "phase-4a: ResultDiff — result group diffing and ResultsReporter"
```

---

### Task 12: Final Package Wiring + Full Test Run

**Files:**
- Modify: `packages/graph/standing/main.roc` (final exports)

- [ ] **Step 1: Update main.roc with all exports**

```roc
# packages/graph/standing/main.roc
package [
    StandingQueryResult,
    ValueConstraint,
    MvStandingQuery,
    SqPartState,
    UnitState,
    LocalIdState,
    LocalPropertyState,
    LabelsState,
    AllPropertiesState,
    WatchableEventIndex,
    ResultDiff,
] {
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
}
```

- [ ] **Step 2: Run all standing query tests**

Run each module individually (Roc tests are per-file):

```bash
roc test packages/graph/standing/result/StandingQueryResult.roc
roc test packages/graph/standing/ast/ValueConstraint.roc
roc test packages/graph/standing/ast/MvStandingQuery.roc
roc test packages/graph/standing/state/SqPartState.roc
roc test packages/graph/standing/state/UnitState.roc
roc test packages/graph/standing/state/LocalIdState.roc
roc test packages/graph/standing/state/LocalPropertyState.roc
roc test packages/graph/standing/state/LabelsState.roc
roc test packages/graph/standing/state/AllPropertiesState.roc
roc test packages/graph/standing/index/WatchableEventIndex.roc
roc test packages/graph/standing/result/ResultDiff.roc
```

Expected: All modules pass with 0 failures. Total: ~80+ tests across all modules.

- [ ] **Step 3: Run existing graph layer tests to verify no regressions**

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

Expected: All existing tests still pass (0 regressions).

- [ ] **Step 4: Commit final wiring**

```bash
git add packages/graph/standing/main.roc
git commit -m "phase-4a: final package wiring — all standing query modules exported"
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
| MVSQ AST (8 variants) | Task 3 |
| ValueConstraint (7 variants) | Task 2 |
| LabelsConstraint (2 variants) | Task 2 |
| Part ID computation (FNV-1a) | Task 3 |
| indexable_subqueries | Task 3 |
| relevant_event_types | Task 3 |
| SqPartState (9 variants) | Task 4 |
| SqEffect, SqContext types | Task 4 |
| create_state | Task 4 |
| UnitState | Task 5 |
| LocalIdState | Task 6 |
| LocalPropertyState | Task 7 |
| LabelsState | Task 8 |
| AllPropertiesState | Task 9 |
| WatchableEventIndex | Task 10 |
| Result diffing | Task 11 |
| ResultsReporter | Task 11 |
| StandingQueryResult type | Task 1 |

**Not in scope (Phase 4b):** CrossState, SubscribeAcrossEdgeState, EdgeSubscriptionReciprocalState, FilterMapState, Expr evaluator

### Type Consistency

- `StandingQueryId : U128` — defined in StandingQueryResult.roc, used consistently
- `StandingQueryPartId : U64` — defined in StandingQueryResult.roc (moved from Ids.roc to avoid circular deps), used consistently
- `QueryContext : Dict Str QuineValue` — defined in StandingQueryResult.roc, used in all state modules
- `SqEffect` — defined in SqPartState.roc, used in all state modules
- `SqContext` — defined in SqPartState.roc, used in UnitState and LocalIdState
- `WatchableEventType` — defined in MvStandingQuery.roc, used in WatchableEventIndex.roc
- `SqSubscriber` — defined in WatchableEventIndex.roc
- `ValueConstraint` / `LabelsConstraint` — defined in ValueConstraint.roc, used in LocalPropertyState/LabelsState
