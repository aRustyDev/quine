# Phase 4: Standing Queries — Design Spec

**Status:** Draft
**Date:** 2026-04-20
**Depends on:** Phase 1 (graph node model), Phase 2 (persistence interfaces), Phase 3 (graph structure & concurrency)
**Unblocks:** Phase 5 (query languages), Phase 6 (ingest & outputs)

---

## Overview

Standing queries are Quine's core differentiator: live, incremental graph pattern
matchers that trigger actions when patterns are detected in the evolving graph.
Unlike traditional queries that run against a snapshot, a standing query is
registered once and continuously monitors the graph. When a node's state changes,
only relevant standing query states are re-evaluated, and only the affected
portion of the pattern is recomputed.

Phase 4 ports the **MultipleValues Standing Query (MVSQ)** system to Roc. This is
the most capable of Quine's three SQ systems. The DomainGraphBranch (DGB/v1)
system is intentionally omitted — MVSQ subsumes its capabilities and starting
fresh avoids porting legacy complexity.

### What this phase delivers

1. MVSQ AST (8 query variants as Roc tagged unions)
2. Per-node SQ state machines (9 state types, pure update functions)
3. WatchableEventIndex for O(1) event-to-subscriber dispatch
4. Cross-edge subscription protocol (SubscribeAcrossEdge <-> EdgeSubscriptionReciprocal)
5. Result diffing and delivery to shard-level result buffers
6. Minimal expression evaluator for FilterMap conditions and projections
7. Integration with existing ShardState dispatch, NodeState, and effects
8. SQ persistence via NodeSnapshot (OnNodeSleep strategy)
9. Backpressure from SQ result buffers to ingest

---

## Decisions & Rationale

### MVSQ only — no DGB, no QuinePattern

The Scala codebase has three coexisting SQ systems due to evolutionary history.
The Roc port unifies on MVSQ:

- **DGB/v1** is strictly less expressive (boolean-only results vs. rows of named
  values). Every DGB pattern can be expressed as an MVSQ. Removing DGB eliminates
  ~40% of the SQ code surface (DomainNodeIndex, SubscribersToThisNode,
  DomainGraphNodeRegistry, 6 message types).
- **QuinePattern** is still evolving upstream and uses a different runtime model.
  It can be evaluated as a future phase if needed.
- Unifying on MVSQ means one state machine model, one serialization format, one
  event index type, and one result delivery path.

### Immutable state + effect lists (not mutable vars)

Scala's MVSQ states use mutable `var` fields within the actor's single-threaded
context. In Roc, each state type is an immutable record. Update functions return
`{ state, effects }` pairs — the same pattern used throughout the graph layer.

This makes all SQ logic property-testable: given a state and inputs, assert the
output state and effects.

### Effects-as-data for SQ operations

SQ state updates produce `SqEffect` values (CreateSubscription, CancelSubscription,
ReportResults) rather than performing side effects directly. The dispatch layer
translates these into graph-level `Effect` values (SendToNode, EmitSqResult).

This keeps the SQ state logic decoupled from the message routing mechanism.

### Global part index lives in the shard

The `NamespaceSqIndex.partIndex` in Scala maps `PartId -> MvStandingQuery` at
the graph level. In our model, each shard holds a copy of this index. When a new
SQ is registered, the index is broadcast to all shards. Nodes look up query
definitions by part ID through a context record passed to state functions.

Alternative considered: embedding the full query AST in each subscription message.
Rejected because the same query part may exist on thousands of nodes, and the AST
can be large (especially for Cross with many subqueries).

### OnNodeSleep persistence (initially)

SQ state is serialized as part of the NodeSnapshot on sleep. This is the simplest
strategy and matches the existing Phase 3 persistence model. OnNodeUpdate
persistence (per-state-change) can be added later if durability requirements
demand it.

### Minimal expression evaluator (Phase 4 subset)

FilterMap needs to evaluate Cypher-like expressions. Phase 4 implements only the
subset used by MVSQ FilterMap:

- Literals, variables, property access
- Comparisons (`==`, `!=`, `<`, `>`, `<=`, `>=`)
- Boolean logic (`and`, `or`, `not`)
- `id()` and `labels()` functions
- `IS NULL` / `IS NOT NULL`
- List membership (`IN`)

The full Cypher expression evaluator is Phase 5 scope. Phase 4's evaluator is
designed to be subsumed by Phase 5's, not replaced.

### NodeChangeEvent not extended — events derived from mutations

ADR-005 left open whether to extend `NodeChangeEvent` or introduce a parent type.
Decision: **do not modify NodeChangeEvent**. Standing query subscription events
(DomainIndexEvent in Scala) are not needed because:

1. We don't have DGB (which was the primary consumer of DomainIndexEvent)
2. MVSQ subscription state is tracked in-memory in `sq_states` and serialized
   in NodeSnapshot — no need to journal individual SQ state changes
3. Node mutations already produce the right `NodeChangeEvent` variants that the
   WatchableEventIndex consumes

The dispatch layer derives `NodeChangeEvent` values from mutations (SetProp
produces `PropertySet`, AddEdge produces `EdgeAdded`, etc.) and routes them
through the index.

---

## MVSQ AST

### Standing Query Definition

```roc
StandingQueryId : U128     # UUID identifying a top-level standing query

MvStandingQuery : [
    ## Produces exactly one empty result — identity for Cross
    UnitSq,

    ## Cartesian product of subqueries
    Cross {
        queries : List MvStandingQuery,
        emit_subscriptions_lazily : Bool,
    },

    ## Watches a single property key with a value constraint
    LocalProperty {
        prop_key : Str,
        constraint : ValueConstraint,
        aliased_as : Result Str [NoAlias],
    },

    ## Watches node labels
    Labels {
        aliased_as : Result Str [NoAlias],
        constraint : LabelsConstraint,
    },

    ## Returns the node's own ID
    LocalId {
        aliased_as : Str,
        format_as_string : Bool,
    },

    ## Returns all properties as a map
    AllProperties {
        aliased_as : Str,
    },

    ## Watches for edges matching a pattern, subscribes andThen on remote node
    SubscribeAcrossEdge {
        edge_name : Result Str [AnyEdge],
        edge_direction : Result EdgeDirection [AnyDirection],
        and_then : MvStandingQuery,
    },

    ## Verifies the reciprocal half-edge exists, then subscribes to andThen
    ## (synthetically created by SubscribeAcrossEdge, not globally indexed)
    EdgeSubscriptionReciprocal {
        half_edge : HalfEdge,
        and_then_id : StandingQueryPartId,
    },

    ## Filters results with a condition, maps with new column expressions
    FilterMap {
        condition : Result Expr [NoFilter],
        to_filter : MvStandingQuery,
        drop_existing : Bool,
        to_add : List { alias : Str, expr : Expr },
    },
]
```

### Value Constraints

```roc
ValueConstraint : [
    Equal QuineValue,
    NotEqual QuineValue,
    Any,                    # matches any non-null value
    None,                   # matches only when property is absent
    Unconditional,          # matches regardless (present, absent, any value)
    Regex Str,
    ListContains (List QuineValue),
]
```

### Labels Constraints

```roc
LabelsConstraint : [
    Contains (List Str),    # node must have all listed labels
    Unconditional,          # matches any labels (including none)
]
```

### Part ID Computation

Each `MvStandingQuery` node has a deterministic `StandingQueryPartId` computed by
hashing the AST structure. This enables state sharing: if two top-level SQs have
identical subtrees, nodes can share state for those subtrees.

```roc
query_part_id : MvStandingQuery -> StandingQueryPartId
```

The hash must be injective (`id(q1) == id(q2)` implies structural equality) and
should be deterministic across runs. Use FNV-1a (already in the codebase for
shard routing) over a canonical byte encoding of the AST.

`EdgeSubscriptionReciprocal` nodes are not globally indexed — they are ephemeral,
created per-edge by `SubscribeAcrossEdgeState`.

### Indexable Subqueries

```roc
## Extract all globally-indexable subqueries from an MVSQ AST.
## Excludes EdgeSubscriptionReciprocal (ephemeral, not globally registered).
indexable_subqueries : MvStandingQuery -> List MvStandingQuery
```

---

## Per-Node SQ State

### State Types

Each MVSQ variant has a corresponding state type. All are variants of a single
tagged union for storage in the node's `sq_states` dict.

```roc
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
        result : List QueryContext,   # pre-computed during rehydrate
    },

    AllPropertiesState {
        query_part_id : StandingQueryPartId,
        last_reported_properties : Result (Dict Str PropertyValue) [NeverReported],
    },

    SubscribeAcrossEdgeState {
        query_part_id : StandingQueryPartId,
        ## Per-edge result cache. Ok = received result, Err Pending = subscription sent but no result yet.
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
```

### QueryContext

```roc
## A row of named values — the result unit of an MVSQ.
QueryContext : Dict Str QuineValue
```

### State Update Functions

All state updates are pure functions returning the new state and a list of effects.

```roc
## Context provided to SQ state functions for looking up queries and node state.
SqContext : {
    lookup_query : StandingQueryPartId -> Result MvStandingQuery [NotFound],
    executing_node_id : QuineId,
    current_properties : Dict Str PropertyValue,
    labels_property_key : Str,
}

## Effects produced by SQ state updates.
SqEffect : [
    ## Subscribe to a query on a node (may be self or remote)
    CreateSubscription {
        on_node : QuineId,
        query : MvStandingQuery,
        global_id : StandingQueryId,
        subscriber_part_id : StandingQueryPartId,
    },
    ## Cancel a previously-issued subscription
    CancelSubscription {
        on_node : QuineId,
        query_part_id : StandingQueryPartId,
        global_id : StandingQueryId,
    },
    ## Report updated results to subscribers
    ReportResults (List QueryContext),
]

## Called when the state is first created on a node (not on wake from sleep).
on_initialize : SqPartState, SqContext -> { state : SqPartState, effects : List SqEffect }

## Called when node events occur that this state is interested in.
on_node_events : SqPartState, List NodeChangeEvent, SqContext -> { state : SqPartState, effects : List SqEffect, changed : Bool }

## Called when a subquery delivers a new result.
on_subscription_result : SqPartState, SubscriptionResult, SqContext -> { state : SqPartState, effects : List SqEffect, changed : Bool }

## Read the current accumulated results for this state.
read_results : SqPartState, Dict Str PropertyValue, Str -> Result (List QueryContext) [NotReady]
```

### SubscriptionResult

```roc
SubscriptionResult : {
    from : QuineId,
    query_part_id : StandingQueryPartId,
    global_id : StandingQueryId,
    for_query_part_id : StandingQueryPartId,
    result_group : List QueryContext,
}
```

### Relevant Event Types

Each state type declares which `WatchableEventType`s it cares about:

| State Type | Watches |
|-----------|---------|
| UnitState | (nothing) |
| CrossState | (nothing — receives results from children) |
| LocalPropertyState | `PropertyChange(prop_key)` |
| LabelsState | `PropertyChange(labels_property_key)` |
| LocalIdState | (nothing) |
| AllPropertiesState | `AnyPropertyChange` |
| SubscribeAcrossEdgeState | `EdgeChange(edge_name)` |
| EdgeSubscriptionReciprocalState | `EdgeChange(Some(half_edge.edge_type))` |
| FilterMapState | (nothing — receives results from child) |

---

## WatchableEventIndex

The per-node dispatch index that maps events to interested SQ subscribers.
Enables O(1) lookup of which SQ states to notify on each node change.

```roc
WatchableEventType : [
    PropertyChange Str,
    EdgeChange (Result Str [AnyLabel]),
    AnyPropertyChange,
]

## Identifies an SQ state registered in the event index.
SqSubscriber : {
    global_id : StandingQueryId,
    part_id : StandingQueryPartId,
}

WatchableEventIndex : {
    watching_for_property : Dict Str (List SqSubscriber),
    watching_for_edge : Dict Str (List SqSubscriber),
    watching_for_any_edge : List SqSubscriber,
    watching_for_any_property : List SqSubscriber,
}

## Register an SQ subscriber and return initial events from existing node state.
register_standing_query :
    WatchableEventIndex,
    SqSubscriber,
    WatchableEventType,
    Dict Str PropertyValue,
    Dict Str (List HalfEdge)
    -> { index : WatchableEventIndex, initial_events : List NodeChangeEvent }

## Unregister an SQ subscriber.
unregister_standing_query :
    WatchableEventIndex,
    SqSubscriber,
    WatchableEventType
    -> WatchableEventIndex

## Look up which subscribers care about a given event.
subscribers_for_event :
    WatchableEventIndex,
    NodeChangeEvent
    -> List SqSubscriber
```

---

## SQ Messages

### NodeMessage Extension

```roc
NodeMessage : [
    LiteralCmd LiteralCommand,
    SleepCheck { now : U64 },
    ## Phase 4: Standing query commands
    SqCmd SqCommand,
]

SqCommand : [
    ## Subscribe to an MVSQ part on this node
    CreateSqSubscription {
        subscriber : SqMsgSubscriber,
        query : MvStandingQuery,
    },
    ## Cancel a subscription
    CancelSqSubscription {
        subscriber : SqMsgSubscriber,
        query_part_id : StandingQueryPartId,
    },
    ## Deliver a result group from another node
    NewSqResult SubscriptionResult,
    ## Trigger SQ sync on this node (on wake or after new SQ registration)
    UpdateStandingQueries,
]

## Who is subscribing / who should receive results
SqMsgSubscriber : [
    ## Another node — results go as NewSqResult messages
    NodeSubscriber {
        subscribing_node : QuineId,
        global_id : StandingQueryId,
        query_part_id : StandingQueryPartId,
    },
    ## The end-user — results go to the shard result buffer
    GlobalSubscriber {
        global_id : StandingQueryId,
    },
]
```

### Effect Extension

```roc
Effect : [
    Reply { request_id : RequestId, payload : ReplyPayload },
    SendToNode { target : QuineId, msg : NodeMessage },
    SendToShard { shard_id : ShardId, payload : List U8 },
    Persist { command : PersistCommand },
    EmitBackpressure BackpressureSignal,
    UpdateCostToSleep I64,
    ## Phase 4: Emit a standing query result to the shard result buffer
    EmitSqResult {
        query_id : StandingQueryId,
        result : StandingQueryResult,
    },
]
```

### StandingQueryResult

```roc
StandingQueryResult : {
    is_positive_match : Bool,
    data : Dict Str QuineValue,
}
```

---

## Subscription Lifecycle

### 1. Registration (shard-level)

1. User registers SQ via API (Phase 7) or test harness
2. Shard receives `RegisterStandingQuery { id, query }`:
   a. Computes `indexable_subqueries(query)` to build the part index
   b. Stores `part_index : Dict StandingQueryPartId MvStandingQuery`
   c. Stores `running_queries : Dict StandingQueryId RunningQuery`
   d. Broadcasts `UpdateStandingQueries` to all nodes (via shard message)

### 2. Per-Node State Creation

When a node receives `CreateSqSubscription { subscriber, query }`:

1. Check if state already exists for `(global_id, query.part_id)`:
   - If yes: add subscriber to existing subscription, return current results
   - If no: continue to step 2

2. Create state: `query.create_state()` returns the appropriate `SqPartState`

3. Rehydrate: look up the query definition via `sq_context.lookup_query`

4. Initialize: call `on_initialize(state, sq_context)` to issue any initial
   subscriptions (e.g., Cross subscribes to its first subquery)

5. Register in event index: for each `relevant_event_type` of the state, call
   `register_standing_query` which returns initial events from existing node state

6. Process initial events: call `on_node_events(state, initial_events, sq_context)`
   to seed the state with pre-existing node data

7. Read initial results: call `read_results` and send to the subscriber

8. Store: add `(global_id, part_id) -> { subscription, state }` to
   `node.sq_states`

### 3. Incremental Updates (post-mutation dispatch)

When `dispatch_node_msg` processes a LiteralCmd that mutates node state:

1. **Derive events**: SetProp produces `PropertySet`, AddEdge produces
   `EdgeAdded`, RemoveProp produces `PropertyRemoved`, RemoveEdge produces
   `EdgeRemoved`

2. **Index lookup**: for each event, call `subscribers_for_event(index, event)`
   to find interested SQ states

3. **State updates**: for each interested state, call
   `on_node_events(state, [event], sq_context)` — returns updated state and
   `SqEffect` list

4. **Effect translation**: translate `SqEffect`s to graph `Effect`s:
   - `CreateSubscription { on_node, query, ... }` ->
     `SendToNode { target: on_node, msg: SqCmd(CreateSqSubscription { ... }) }`
   - `CancelSubscription { on_node, ... }` ->
     `SendToNode { target: on_node, msg: SqCmd(CancelSqSubscription { ... }) }`
   - `ReportResults results` -> deliver to subscribers (either `SendToNode` for
     NodeSubscriber, or `EmitSqResult` for GlobalSubscriber)

5. **Persist state**: if using OnNodeSleep, mark the state as dirty for snapshot

### 4. Cross-Edge Subscription Protocol

The key multi-node interaction:

```
Node A                                          Node B
  |                                               |
  | SubscribeAcrossEdgeState sees EdgeAdded(B)    |
  |  -> creates EdgeSubscriptionReciprocal query  |
  |  -> SqEffect: CreateSubscription(on: B, ...)  |
  | ------------------------------------------------>
  |                                               |
  |                 B creates EdgeSubscriptionReciprocalState
  |                 B verifies reciprocal half-edge exists
  |                 B subscribes to andThen locally
  |                 B runs andThen (e.g. LocalId)
  |                 andThen produces result
  |                 B relays result back to A
  |                                               |
  | <------------------------------------------------
  | SubscribeAcrossEdgeState caches result per edge|
  | Combines with other edges' results             |
  | Reports to Cross (parent)                      |
```

### 5. Result Delivery

At the top of the SQ tree, a `GlobalSubscriber` receives results:

1. The node's `SqSubscription` has a GlobalSubscriber in its subscriber set
2. When `ReportResults` effect fires for a GlobalSubscriber:
   a. The shard's `ResultsReporter` diffs the new result group against
      previously-reported results
   b. New matches become positive `StandingQueryResult`s
   c. No-longer-matching results become cancellation `StandingQueryResult`s
      (if `include_cancellations` is enabled)
   d. Results are offered to the shard's bounded result buffer
3. Output sinks (Phase 6) consume from the buffer

### 6. Cancellation

1. User cancels SQ -> shard removes from registry and part index
2. Shard broadcasts `UpdateStandingQueries` to all nodes
3. Each node's `sync_standing_queries` removes state for deleted SQs:
   a. Unregister from WatchableEventIndex
   b. Remove from `sq_states`
   c. Remove ResultsReporter
4. Edge removal also triggers selective cancellation:
   a. `SubscribeAcrossEdgeState` sees EdgeRemoved -> cancels subscription on
      remote node -> remote node removes `EdgeSubscriptionReciprocalState`

---

## Result Diffing

```roc
## Compute the diff between old and new result groups.
##
## Returns StandingQueryResults for newly-added rows (positive matches) and
## optionally for removed rows (cancellations).
generate_result_reports :
    List QueryContext,         # old results (tracked)
    List QueryContext,         # new results
    Bool                       # include cancellations?
    -> List StandingQueryResult
```

This is a pure function. Implementation:
- `added = list_diff(new_results, old_results)` -> positive matches
- `removed = list_diff(old_results, new_results)` -> cancellations (if enabled)
- Map each to `StandingQueryResult` with `is_positive_match` flag

### ResultsReporter (shard-level)

```roc
ResultsReporter : {
    last_results : List QueryContext,
}

apply_and_emit_results :
    ResultsReporter,
    List QueryContext,
    Bool                    # include cancellations?
    -> { reporter : ResultsReporter, reports : List StandingQueryResult }
```

One ResultsReporter per top-level SQ per node that has a GlobalSubscriber.
Stored alongside the SQ state.

---

## Backpressure

### Mechanism

1. Each shard maintains a bounded result buffer for SQ results
2. When `EmitSqResult` is executed and the buffer is full, the shard emits
   `EmitBackpressure(SqBufferFull)` (already defined in Effects.roc)
3. The host aggregates SqBufferFull signals across shards into a global flag
4. Ingest sources (Phase 6) check this flag before producing data
5. When the buffer drains below threshold, `EmitBackpressure(Clear)` is emitted

### Configuration

```roc
SqConfig : {
    result_buffer_size : U32,             # default 1024
    backpressure_threshold : U32,         # default 768 (75%)
    include_cancellations : Bool,         # default true
}
```

---

## Integration with Existing Graph Layer

### NodeState Changes

```roc
NodeState : {
    id : QuineId,
    properties : Dict Str PropertyValue,
    edges : Dict Str (List HalfEdge),
    journal : List TimestampedEvent,
    snapshot_base : [None, Some NodeSnapshot],
    edge_storage : [Inline],
    ## Phase 4 additions:
    sq_states : Dict SqStateKey SqNodeState,
    watchable_event_index : WatchableEventIndex,
}

SqStateKey : {
    global_id : StandingQueryId,
    part_id : StandingQueryPartId,
}

SqNodeState : {
    subscription : SqSubscription,
    state : SqPartState,
}

SqSubscription : {
    for_query : StandingQueryPartId,
    global_id : StandingQueryId,
    subscribers : List SqMsgSubscriber,
}
```

### NodeSnapshot Changes

```roc
NodeSnapshot : {
    properties : Dict Str PropertyValue,
    edges : List HalfEdge,
    time : EventTime,
    ## Phase 4: serialized SQ state restored on wake
    sq_snapshot : List SqStateSnapshot,
}

SqStateSnapshot : {
    global_id : StandingQueryId,
    part_id : StandingQueryPartId,
    subscription : SqSubscription,
    state_bytes : List U8,
}
```

The WatchableEventIndex is reconstructed from `sq_states` on wake — it is not
persisted.

### Dispatch Changes

`dispatch_node_msg` gains:

1. A new `SqCmd` branch for handling SQ-specific messages
2. Post-mutation SQ dispatch for LiteralCmd mutations

```roc
dispatch_node_msg : NodeState, NodeMessage, SqContext -> { state : NodeState, effects : List Effect }
dispatch_node_msg = |node, msg, sq_ctx|
    when msg is
        LiteralCmd(cmd) ->
            { state: node2, effects: literal_effects, events } = handle_literal_with_events(node, cmd)
            { state: node3, effects: sq_effects } = dispatch_sq_events(node2, events, sq_ctx)
            { state: node3, effects: List.concat(literal_effects, sq_effects) }

        SqCmd(sq_cmd) ->
            handle_sq_command(node, sq_cmd, sq_ctx)

        SleepCheck(_) ->
            { state: node, effects: [] }
```

The key new function is `handle_literal_with_events`, which extends the current
`handle_literal` to also return the `NodeChangeEvent` values corresponding to
the mutation. And `dispatch_sq_events`, which routes events through the
WatchableEventIndex to interested SQ states.

```roc
## Route node change events to interested SQ states.
dispatch_sq_events :
    NodeState,
    List NodeChangeEvent,
    SqContext
    -> { state : NodeState, effects : List Effect }
dispatch_sq_events = |node, events, sq_ctx|
    # For each event, find interested subscribers
    subscribers = List.join_map(events, |event|
        subscribers_for_event(node.watchable_event_index, event)
    )
    # Deduplicate subscribers
    unique_subscribers = deduplicate(subscribers)
    # Update each interested SQ state
    List.walk(unique_subscribers, { state: node, effects: [] }, |acc, subscriber|
        key = { global_id: subscriber.global_id, part_id: subscriber.part_id }
        when Dict.get(acc.state.sq_states, key) is
            Ok(sq_node_state) ->
                result = on_node_events(sq_node_state.state, events, sq_ctx)
                new_sq_state = { sq_node_state & state: result.state }
                new_states = Dict.insert(acc.state.sq_states, key, new_sq_state)
                translated = translate_sq_effects(result.effects, sq_node_state.subscription)
                {
                    state: { acc.state & sq_states: new_states },
                    effects: List.concat(acc.effects, translated),
                }
            Err(_) -> acc   # subscriber no longer in state, skip
    )
```

### ShardState Changes

```roc
ShardState := {
    shard_id : ShardId,
    shard_count : U32,
    config : ShardConfig,
    namespace : NamespaceId,
    nodes : Dict QuineId NodeEntry,
    lru_entries : Dict QuineId LruEntry,
    pending_effects : List Effect,
    request_counter : U64,
    backpressure : BackpressureSignal,
    ## Phase 4 additions:
    part_index : Dict StandingQueryPartId MvStandingQuery,
    running_queries : Dict StandingQueryId RunningQuery,
    sq_result_buffer : List StandingQueryResult,
    sq_config : SqConfig,
}

RunningQuery : {
    id : StandingQueryId,
    query : MvStandingQuery,
    include_cancellations : Bool,
}
```

### Codec Changes

The codec package needs extensions for SQ message types:

- `encode_sq_command / decode_sq_command` for SqCommand variants
- `encode_mv_standing_query / decode_mv_standing_query` for the AST
- `encode_sq_result / decode_sq_result` for SubscriptionResult
- `encode_sq_state / decode_sq_state` for persistence

### Effect Interpreter Changes (graph-app.roc)

`execute_effect!` gains a case for `EmitSqResult`:

```roc
EmitSqResult({ query_id, result }) ->
    # Buffer in shard state or send via host function
    Effect.emit_sq_result!(query_id, result)
```

This requires a new host function for delivering SQ results to consumers.

---

## Minimal Expression Evaluator

### Expr AST

```roc
Expr : [
    Literal QuineValue,
    Variable Str,                              # lookup in QueryContext
    Property { expr : Expr, key : Str },       # e.g. n.name
    Comparison { left : Expr, op : CompOp, right : Expr },
    BoolOp { left : Expr, op : BoolLogic, right : Expr },
    Not Expr,
    IsNull Expr,
    InList { elem : Expr, list : Expr },
    FnCall { name : Str, args : List Expr },   # id(), labels()
]

CompOp : [Eq, Neq, Lt, Gt, Lte, Gte]
BoolLogic : [And, Or]
```

### Evaluator

```roc
eval : Expr, QueryContext, ExprContext -> Result QuineValue [EvalError Str]

ExprContext : {
    node_id : QuineId,
    labels_property_key : Str,
    properties : Dict Str PropertyValue,
}
```

The evaluator is total — it returns `EvalError` rather than crashing. Unknown
functions or type mismatches produce errors.

### Supported Functions

| Function | Args | Returns | Notes |
|----------|------|---------|-------|
| `id` | 0 | QuineValue.Id | Node's own ID |
| `labels` | 0 | QuineValue.List | Node's labels as list of strings |

Phase 5 adds: `type()`, `coalesce()`, `toString()`, `size()`, `keys()`,
`properties()`, string functions, math functions, aggregations.

---

## Package & Module Layout

```
packages/
  graph/
    standing/                  # New Phase 4 package
      ast/
        MvStandingQuery.roc    # AST types, query_part_id, indexable_subqueries
        ValueConstraint.roc    # ValueConstraint, LabelsConstraint
      state/
        SqPartState.roc        # Tagged union of all state types
        UnitState.roc          # on_node_events, read_results for UnitState
        CrossState.roc         # Cross product logic
        LocalPropertyState.roc
        LabelsState.roc
        LocalIdState.roc
        AllPropertiesState.roc
        SubscribeAcrossEdgeState.roc
        EdgeSubscriptionReciprocalState.roc
        FilterMapState.roc
        StateDispatch.roc      # Routes to correct state handler by variant
      index/
        WatchableEventIndex.roc
      result/
        ResultDiff.roc         # generate_result_reports, ResultsReporter
        StandingQueryResult.roc
      messages/
        SqMessages.roc         # SqCommand, SqMsgSubscriber, SubscriptionResult
      main.roc
    types/                     # Extended
    shard/                     # Extended
    codec/                     # Extended
    routing/                   # Unchanged
    ops/                       # Extended with SQ registration API
  expr/                        # New Phase 4 package
    ast/
      Expr.roc                 # Expr, CompOp, BoolLogic
    eval/
      Eval.roc                 # eval function
    main.roc
  core/                        # Extended: NodeSnapshot gets sq_snapshot
```

### Dependency Flow

```
graph/standing  ->  graph/types  ->  core/{id, model}
      |                  ^
      +->  expr/         |
      |                  |
graph/shard  (extended)  |
      |                  |
      +->  graph/standing
```

`graph/ops/` remains the only module external code imports. It gains SQ
registration functions.

---

## Test Strategy

### Unit Tests (pure functions, per-state-type)

Each state type gets its own test module mirroring the Scala test suite:

- **UnitState**: always returns one empty-row result
- **CrossState**: cartesian product semantics, lazy subscription emission,
  partial results (None until all subqueries report)
- **LocalPropertyState**: property set/remove/change, constraint matching
  (Equal, NotEqual, Any, None, Unconditional, Regex, ListContains),
  aliased vs. non-aliased result reporting, no-change deduplication
- **LabelsState**: label set/change, Contains/Unconditional constraints,
  aliased vs. non-aliased
- **LocalIdState**: returns node ID, format_as_string option
- **AllPropertiesState**: property change triggers, deduplication
- **SubscribeAcrossEdgeState**: edge add -> create subscription, edge remove ->
  cancel subscription, result caching per edge, result accumulation
- **EdgeSubscriptionReciprocalState**: reciprocal edge verification,
  currentlyMatching transitions, cached result relay
- **FilterMapState**: condition filtering, column projection, result caching

### WatchableEventIndex Tests

- Register/unregister for each event type
- Initial events from existing state
- Lookup for PropertySet, PropertyRemoved, EdgeAdded, EdgeRemoved
- AnyPropertyChange receives all property events
- EdgeChange(AnyLabel) receives all edge events

### Result Diffing Tests

- Empty -> non-empty (all positive)
- Non-empty -> empty (all cancellations)
- Partial overlap (some added, some removed, some unchanged)
- Cancellation suppression when `include_cancellations = false`

### Expression Evaluator Tests

- Literal evaluation
- Variable lookup (present, missing)
- Property access
- Each comparison operator
- Boolean logic (and, or, not)
- IS NULL / IS NOT NULL
- IN list membership
- id() and labels() functions
- Type mismatch errors

### Integration Tests (multi-node scenarios on platform)

- **Single-node property match**: register SQ for `n.name = "Alice"`, set
  property, verify result emitted
- **Cross-edge subscription**: register SQ matching `(a)-[:KNOWS]->(b)`,
  add edge, verify subscription propagation and result
- **Edge removal cancellation**: match, then remove edge, verify cancellation
- **Cross product**: SQ with multiple subqueries, verify cartesian product
- **FilterMap**: SQ with WHERE clause, verify filtering
- **Result diffing**: property changes that alter SQ results, verify only
  diffs emitted
- **Backpressure**: fill result buffer, verify SqBufferFull signal
- **Sleep/wake round-trip**: SQ state survives node sleep and wake

### Smoke Test App

`app/phase-4-smoke.roc`: registers an SQ, creates nodes with matching
properties/edges, verifies results stream correctly.

---

## Build Sequence

Phase 4 is large. Recommended sub-phase ordering:

### Phase 4a: AST + State + Index (pure, no platform needed)
1. `MvStandingQuery` AST types + `query_part_id` computation
2. `ValueConstraint`, `LabelsConstraint`
3. `WatchableEventIndex` (register, unregister, lookup)
4. Leaf states: `UnitState`, `LocalIdState`, `LocalPropertyState`, `LabelsState`,
   `AllPropertiesState`
5. `ResultDiff` (generate_result_reports)
6. Tests for all of the above (~150-200 tests estimated)

### Phase 4b: Composite States + Expressions
1. `CrossState` (cartesian product, lazy subscriptions)
2. `SubscribeAcrossEdgeState` + `EdgeSubscriptionReciprocalState`
3. `FilterMapState`
4. Minimal `Expr` AST + evaluator
5. Tests for all of the above (~80-120 tests)

### Phase 4c: Graph Layer Integration
1. Extend `NodeState` with `sq_states` and `watchable_event_index`
2. Extend `NodeMessage` with `SqCmd`
3. Extend `Effect` with `EmitSqResult`
4. Extend `dispatch_node_msg` with post-mutation SQ dispatch
5. Add `handle_sq_command` to Dispatch
6. Extend `NodeSnapshot` with SQ state
7. Extend ShardState with part_index, running_queries, result buffer
8. Codec extensions for SQ messages and state
9. Tests for integration

### Phase 4d: Platform Wiring
1. Extend `graph-app.roc` effect interpreter for `EmitSqResult`
2. Add host function for SQ result delivery
3. SQ registration via shard messages
4. Backpressure propagation
5. Integration tests on platform
6. Smoke test app

---

## Deferred Work

| Item | Deferred to | Notes |
|------|-------------|-------|
| DGB/v1 standing query system | Never (unless compatibility required) | MVSQ subsumes |
| QuinePattern system | Post-Phase 7 | Evolving upstream |
| OnNodeUpdate persistence | Post-Phase 4 | If durability requirements demand it |
| SQ metrics (result rates, state sizes) | Phase 7 (metrics) | |
| Cypher MATCH -> MVSQ compiler | Phase 5 | Phase 4 tests construct AST directly |
| Full Cypher expression evaluator | Phase 5 | Phase 4 has minimal subset |
| Output sink integration | Phase 6 | Phase 4 delivers to shard buffer |
| SQ REST API | Phase 7 | Phase 4 has programmatic registration |
| emitSubscriptionsLazily optimization tuning | Post-Phase 4 | Core logic implemented, profiling later |
| SQ state compaction / garbage collection | Post-Phase 4 | |

---

## Open Questions Resolved

| Question | Resolution |
|----------|------------|
| Unify on single SQ system? | Yes — MVSQ only |
| Global part ID registry location? | Shard-level Dict, one copy per shard |
| State persistence strategy? | OnNodeSleep (serialized in NodeSnapshot) |
| Extend NodeChangeEvent? | No — derive events from mutations |
| EdgeSubscriptionReciprocal as separate type? | Yes — keeps the protocol clean |
| Expression evaluator scope? | Minimal subset for FilterMap |
| Result group semantics? | Preserved — group-at-a-time with diffing |
| How to handle recursive AST hashing? | Iterative traversal, no stack overflow risk for practical query depths |
| Labels implementation? | Stored as property (labels_property_key), consistent with Scala |

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Cross-edge subscription races | Results may be temporarily inconsistent | Single-threaded-per-shard model eliminates intra-shard races; cross-shard races are handled by eventual consistency (same as Scala) |
| Expr evaluator insufficient for real workloads | FilterMap may not support some patterns | Subset is well-scoped; unsupported patterns error cleanly |
| SQ state memory pressure | Many SQs on many nodes = high memory | OnNodeSleep eviction frees SQ state; backpressure limits result accumulation |
| Part ID collisions | Two different queries share state incorrectly | FNV-1a over canonical encoding; same approach as Scala's Murmur3-128; collision probability negligible |
| Roc recursive tagged union limits | Deep MVSQ ASTs may hit recursion limits | Practical query depths are < 10; test with deep patterns |
