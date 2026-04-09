# Standing Queries

## What Happens Here

Standing queries are Quine's most distinctive feature: an incremental, distributed graph pattern matching engine. Unlike traditional queries that run once against a snapshot, a standing query is registered once and then continuously monitors the graph for matches as data arrives. When a node's state changes (property set, edge added), only the standing queries relevant to that change are re-evaluated, and only the affected portion of the pattern is recomputed.

There are three standing query systems in the codebase, reflecting an evolutionary history:

1. **DomainGraphBranch/DistinctId (DGB/v1)**: The original system. Patterns are defined as `DomainGraphBranch` trees. Each node tracks whether it matches the root of a DGB pattern, and propagates boolean match/no-match notifications to subscribers. Results are just the node ID of the root match. This system is still in production use.

2. **MultipleValues (SQv4/MVSQ)**: The current primary system. Patterns are defined as `MultipleValuesStandingQuery` AST trees. Each node holds per-query-part state objects that cache intermediate results. Results are rows of named values (like SQL result sets), and the system supports cross-products, filtering, mapping, and property extraction. This is what Cypher `MATCH ... RETURN` standing queries compile to.

3. **QuinePattern**: A newer system under active development. Uses a query plan compiled from a pattern language. Has both Eager and Lazy runtime modes (Lazy supports retractions). Maintained in a separate collection (`quinePatternQueries`) and uses its own behavior trait.

### The Core Algorithm: Incremental Pattern Matching

The fundamental insight is: **a graph pattern decomposes into per-node responsibilities, and each node independently tracks its own portion of the pattern**. When a node's state changes, only the local state is re-evaluated, and results propagate incrementally to subscribers.

#### How It Works (MultipleValues / SQv4)

Consider a Cypher standing query: `MATCH (a:Person {name: "Alice"})-[:KNOWS]->(b) RETURN a.name, id(b)`

This compiles into an MVSQ AST tree:

```
FilterMap(condition = labels(a) contains "Person")
  Cross([
    LocalProperty(propKey = 'name, constraint = Equal("Alice"), aliasedAs = 'a.name),
    SubscribeAcrossEdge(edgeName = Some('KNOWS), direction = Some(Outgoing), andThen =
      LocalId(aliasedAs = 'b, formatAsString = false)
    )
  ])
```

When registered, this query propagates to every node. On each node:

1. **State creation**: The node creates a `MultipleValuesStandingQueryState` instance for each query part that applies to it. For the root node, this includes a `CrossState`, a `LocalPropertyState`, and a `SubscribeAcrossEdgeState`.

2. **Event registration**: Each state registers which events it cares about via `relevantEventTypes`. The `LocalPropertyState` for `name` registers `WatchableEventType.PropertyChange('name)`. The `SubscribeAcrossEdgeState` registers `WatchableEventType.EdgeChange(Some('KNOWS))`.

3. **Initial state evaluation**: When the state is created, the `StandingQueryWatchableEventIndex.registerStandingQuery` method returns synthetic initial events representing existing node state (e.g., if the property already exists, it returns a `PropertySet` event). The state processes these to initialize.

4. **Incremental updates**: When a node change occurs (e.g., a property is set), `AbstractNodeActor.runPostActions` consults the `StandingQueryWatchableEventIndex` to find which standing query states care about the event. Only those states receive the event via `onNodeEvents`.

5. **Cross-edge propagation**: When a `SubscribeAcrossEdgeState` sees a matching edge added, it creates an `EdgeSubscriptionReciprocal` query and sends it to the remote node. The remote node creates an `EdgeSubscriptionReciprocalState` that verifies the reciprocal half-edge exists, then subscribes to the `andThen` subquery (e.g., `LocalId`) on itself.

6. **Result accumulation**: Results flow back up the tree. `LocalId` on node B produces `{b: QuineId(B)}`. This flows to the `EdgeSubscriptionReciprocalState`, which relays it back to the `SubscribeAcrossEdgeState` on node A. The `CrossState` on A combines it with the `LocalProperty` result to produce `{a.name: "Alice", b: QuineId(B)}`. The `FilterMap` checks the label constraint and, if satisfied, reports to the `GlobalSubscriber`.

7. **Result diffing**: The `MultipleValuesResultsReporter` at the top level diffs new result groups against previously-reported results, emitting only new matches (and optionally cancellations for no-longer-matching results).

#### How It Works (DomainGraphBranch / DistinctId)

The DGB system is simpler but less expressive:

1. **Pattern decomposition**: A `DomainGraphBranch` (a recursive tree of `SingleBranch` nodes, each with local property predicates and edges to child branches) is decomposed into `DomainGraphNode` instances, each stored by a numeric ID in the `DomainGraphNodeRegistry`.

2. **Subscription propagation**: The root node receives a `CreateDomainNodeSubscription` for the root DGN ID. It tests local properties against the `DomainNodeEquiv` predicate, then for each edge in the pattern, subscribes to the child DGN on the remote node across that edge.

3. **Boolean results**: Each node reports `true` (matches) or `false` (doesn't match) back to its subscriber. The parent combines child results with its own local match to determine its overall match status.

4. **Index structure**: Each node maintains a `DomainNodeIndex` (downstream: `Map[QuineId, Map[DomainGraphNodeId, Option[Boolean]]]`) tracking what remote nodes have reported for each DGN, and a `SubscribersToThisNode` (upstream: `Map[DomainGraphNodeId, DistinctIdSubscription]`) tracking who wants to know about matches at this node.

### Standing Query Registration Flow

1. User calls `createStandingQuery(name, pattern, outputs)` on `NamespaceStandingQueries`.
2. A `StandingQueryInfo` is created with the pattern, queue configuration, and a `StandingQueryId` (UUID).
3. A `RunningStandingQuery` is created with a bounded Pekko source queue and a `BroadcastHub` for result fan-out.
4. The query is added to the `NamespaceSqIndex`, which atomically indexes both the top-level query and all MVSQ sub-parts by their `MultipleValuesStandingQueryPartId`.
5. The query is persisted via `persistStandingQuery`.
6. On each node wake-up, `syncStandingQueries` (called from `NodeActor` constructor) sends `CreateMultipleValuesStandingQuerySubscription` messages to itself for any newly-registered queries.
7. `propagateStandingQueries` can be explicitly called to walk all node IDs and send `UpdateStandingQueriesWake`/`NoWake` to each, forcing them to sync.

### Standing Query Cancellation Flow

1. User calls `cancelStandingQuery(standingQueryId)`.
2. The `NamespaceSqIndex` is atomically updated to remove the query and rebuild the part index.
3. The `RunningStandingQuery` output queue is completed (terminating the stream).
4. For DGB queries, the `DomainGraphNodePackage` is unregistered from the `DomainGraphNodeRegistry`.
5. Nodes discover the cancellation on their next sync (next wake-up or next `UpdateStandingQueries` message) and remove local state.

### Result Delivery

When a standing query matches (or un-matches):

1. **MVSQ**: The root state's `reportUpdatedResults` is called. For `GlobalSubscriber`s, the `MultipleValuesResultsReporter.applyAndEmitResults` diffs the new result group against the last-reported group, producing `StandingQueryResult` instances (positive matches and optionally cancellations).
2. **DGB**: A `DomainNodeSubscriptionResult(result=true)` arrives at the root subscriber (a `StandingQueryId`). `NamespaceStandingQueries.reportStandingResult` converts it to a `StandingQueryResult`.
3. The result is offered to the `RunningStandingQuery`'s bounded source queue.
4. Results flow through the `BroadcastHub` to all attached output sinks (e.g., Kafka, webhooks, SSE endpoints).
5. An `AtomicInteger` tracks buffer size. When it reaches `queueBackpressureThreshold`, the `ingestValve` is closed, backpressuring all ingest sources. When the buffer drains below the threshold, the valve reopens.

### Per-Node State for Standing Queries

Each node maintains:

- **`multipleValuesStandingQueries`**: `Map[(StandingQueryId, MultipleValuesStandingQueryPartId), (Subscription, State)]`. The subscription tracks who wants results; the state tracks the incremental computation.
- **`multipleValuesResultReporters`**: `Map[StandingQueryId, MultipleValuesResultsReporter]`. One per top-level query that has a `GlobalSubscriber` on this node. Tracks last-reported results for diffing.
- **`domainGraphSubscribers`** (`SubscribersToThisNode`): `Map[DomainGraphNodeId, DistinctIdSubscription]`. Tracks which DGB patterns are being tested against this node and who to notify.
- **`domainNodeIndex`** (`DomainNodeIndex`): `Map[QuineId, Map[DomainGraphNodeId, Option[Boolean]]]`. Tracks results from downstream nodes for DGB edge subscriptions.
- **`domainGraphNodeParentIndex`** (`NodeParentIndex`): `Map[DomainGraphNodeId, Set[DomainGraphNodeId]]`. Efficiently routes a child DGN's result to its parent DGNs.
- **`watchableEventIndex`** (`StandingQueryWatchableEventIndex`): Maps `PropertyChange(key)` and `EdgeChange(label)` events to the set of standing query subscribers interested in that event. This is the critical dispatch index.
- **`pendingMultipleValuesWrites`**: Buffered state updates when using `PersistenceSchedule.OnNodeSleep`.

All of this state is serialized into the `NodeSnapshot` on sleep and restored on wake.

## Key Types and Structures

### Top-Level Standing Query Management
| Type | Location | Role |
|------|----------|------|
| `StandingQueryId` | `graph/StandingQueryId.scala` | UUID wrapper identifying a top-level standing query |
| `MultipleValuesStandingQueryPartId` | `graph/StandingQueryId.scala` | UUID wrapper identifying a sub-part of an MVSQ |
| `StandingQueryInfo` | `graph/StandingQueryInfo.scala` | Persisted metadata: name, ID, pattern, queue config |
| `StandingQueryPattern` | `graph/StandingQueryInfo.scala` | Sealed: `DomainGraphNodeStandingQueryPattern`, `MultipleValuesQueryPattern`, `QuinePatternQueryPattern` |
| `PatternOrigin` | `graph/StandingQueryInfo.scala` | How the user specified the query (Cypher, direct DGB, etc.) |
| `RunningStandingQuery` | `graph/StandingQueryInfo.scala` | Runtime state: results queue, broadcast hub, metrics, start time |
| `StandingQueryOpsGraph` | `graph/StandingQueryOpsGraph.scala` | Trait mixed into `GraphService` providing SQ lifecycle API |
| `NamespaceStandingQueries` | `graph/StandingQueryOpsGraph.scala` | Per-namespace SQ management: create, cancel, list, propagate |
| `NamespaceSqIndex` | `graph/NamespaceSqIndex.scala` | Atomic index: `Map[StandingQueryId, RunningStandingQuery]` + `Map[PartId, MVSQ]` |
| `DomainGraphNodeRegistry` | `graph/DomainGraphNodeRegistry.scala` | In-memory registry: `DomainGraphNodeId -> (DomainGraphNode, Set[StandingQueryId])` |

### MultipleValues Standing Query AST (the pattern definition)
| Type | Location | Role |
|------|----------|------|
| `MultipleValuesStandingQuery` | `graph/cypher/MultipleValuesStandingQuery.scala` | Sealed abstract: the MVSQ AST node |
| `UnitSq` | same | Produces exactly one empty result (identity for Cross) |
| `Cross` | same | Cartesian product of subqueries (with optional lazy subscription) |
| `LocalProperty` | same | Watches a property key with a `ValueConstraint` (Equal, NotEqual, Regex, Any, None, Unconditional, ListContains) |
| `Labels` | same | Watches node labels with a `LabelsConstraint` (Contains, Unconditional) |
| `LocalId` | same | Returns the node's own ID |
| `AllProperties` | same | Returns all properties as a map |
| `SubscribeAcrossEdge` | same | Watches for edges matching a pattern, subscribes `andThen` on remote node |
| `EdgeSubscriptionReciprocal` | same | Verifies the reciprocal half-edge exists, then subscribes to `andThen` locally |
| `FilterMap` | same | Filters results with a condition expression, maps with new column expressions |

### MultipleValues Standing Query State (per-node computation)
| Type | Location | Role |
|------|----------|------|
| `MultipleValuesStandingQueryState` | `graph/cypher/MultipleValuesStandingQueryState.scala` | Sealed abstract: mutable state for one query part on one node |
| `UnitState` | same | Always returns one empty-row result |
| `CrossState` | same | Caches per-subquery results, computes Cartesian product |
| `LocalPropertyState` | same | Tracks last-reported property value, emits on change |
| `LabelsState` | same | Tracks last-reported labels, emits on change |
| `LocalIdState` | same | Pre-computes node ID result during rehydrate |
| `AllPropertiesState` | same | Tracks last-reported properties map, emits on change |
| `SubscribeAcrossEdgeState` | same | `Map[HalfEdge, Option[Seq[QueryContext]]]` -- per-edge result cache |
| `EdgeSubscriptionReciprocalState` | same | `currentlyMatching: Boolean` + `cachedResult: Option[...]` |
| `FilterMapState` | same | `keptResults: Option[Seq[QueryContext]]` -- cached filtered results |

### State Effect Handlers
| Type | Location | Role |
|------|----------|------|
| `MultipleValuesStandingQueryLookupInfo` | `graph/cypher/MultipleValuesStandingQueryState.scala` | Read-only: `lookupQuery(partId)`, `executingNodeId`, `idProvider` |
| `MultipleValuesInitializationEffects` | same | Init-time: `createSubscription(onNode, query)` |
| `MultipleValuesStandingQueryEffects` | same | Runtime: `createSubscription`, `cancelSubscription`, `reportUpdatedResults`, `currentProperties` |
| `MultipleValuesResultsReporter` | `graph/cypher/MultipleValuesResultsReporter.scala` | Diffs result groups, emits new matches and cancellations |
| `MultipleValuesStandingQueryPartSubscription` | `graph/behavior/MultipleValuesStandingQueryBehavior.scala` | Record: `forQuery` (part ID) + `globalId` (SQ ID) + `subscribers` (mutable set) |

### DomainGraphBranch / DistinctId Types
| Type | Location | Role |
|------|----------|------|
| `DomainGraphBranch` | `model/DomainGraphBranch.scala` | Sealed: recursive pattern tree (by-value). `SingleBranch`, `Or`, `And`, `Not`, `Mu`, `MuVar` |
| `DomainGraphNode` | `model/DomainGraphNode.scala` | Sealed: persistent (by-ID) form. `Single`, `Or`, `And`, `Not`, `Mu`, `MuVar` |
| `DomainGraphNodeId` | `model/DomainGraphNode.scala` | `Long` -- numeric ID for a DGN |
| `DomainNodeEquiv` | `model/DomainNodeEquiv.scala` | Local node predicate: class name, property predicates, circular edges |
| `DomainGraphEdge` | `model/DomainGraphNode.scala` | Edge pattern in a DGN: `GenericEdge` + direction + child DGN ID + constraints |
| `IdentifiedDomainGraphNode` | `model/DomainGraphNode.scala` | Tuple of `DomainGraphNodeId` + `DomainGraphNode` |
| `DomainNodeIndex` | `graph/behavior/DomainNodeIndexBehavior.scala` | Downstream cache: `Map[QuineId, Map[DgnId, Option[Boolean]]]` |
| `SubscribersToThisNode` | `graph/behavior/DomainNodeIndexBehavior.scala` | Upstream subscriptions: `Map[DgnId, DistinctIdSubscription]` |
| `NodeParentIndex` | `graph/behavior/DomainNodeIndexBehavior.scala` | Child-to-parent DGN routing: `Map[DgnId, Set[DgnId]]` |
| `DistinctIdSubscription` | `graph/behavior/DomainNodeIndexBehavior.scala` | `subscribers: Set[Notifiable]` + `lastNotification: Option[Boolean]` + `relatedQueries: Set[StandingQueryId]` |

### Event Dispatch
| Type | Location | Role |
|------|----------|------|
| `WatchableEventType` | `graph/WatchableEventType.scala` | `PropertyChange(key)`, `EdgeChange(labelConstraint)`, `AnyPropertyChange` |
| `StandingQueryWatchableEventIndex` | `graph/WatchableEventType.scala` | Per-node index: maps events to interested subscribers for efficient dispatch |
| `EventSubscriber` | `graph/WatchableEventType.scala` | Sealed: `StandingQueryWithId` (MVSQ) or `DomainNodeIndexSubscription` (DGB) |

### Messages
| Type | Location | Role |
|------|----------|------|
| `CreateMultipleValuesStandingQuerySubscription` | `graph/messaging/StandingQueryMessage.scala` | Subscribe to an MVSQ part on a node |
| `CancelMultipleValuesSubscription` | same | Cancel a subscription |
| `NewMultipleValuesStateResult` | same | Deliver a result group from one node to another |
| `MultipleValuesStandingQuerySubscriber` | same | Sealed: `NodeSubscriber(qid, globalId, partId)` or `GlobalSubscriber(sqId)` |
| `CreateDomainNodeSubscription` | same | Subscribe to a DGB pattern on a node |
| `DomainNodeSubscriptionResult` | same | Boolean match result from a DGB subscription |
| `CancelDomainNodeSubscription` | same | Cancel a DGB subscription |
| `UpdateStandingQueriesWake`/`NoWake` | same | Trigger SQ sync on a node (with or without waking it) |

### Results
| Type | Location | Role |
|------|----------|------|
| `StandingQueryResult` | `graph/StandingQueryResult.scala` | Final result: `Meta(isPositiveMatch)` + `Map[String, QuineValue]` |
| `StandingQueryResult.WithQueueTimer` | same | Result wrapped with a metrics timer context |
| `SqResultLike` | `graph/messaging/StandingQueryMessage.scala` | Trait for messages convertible to `StandingQueryResult` |
| `Notifiable` | `graph/package.scala` | `Either[QuineId, StandingQueryId]` -- a DGB result subscriber |

## Dependencies

### Internal (other stages/modules)

- **Node Model** (`graph/NodeActor.scala`, `graph/AbstractNodeActor.scala`): Standing query state lives inside nodes. `runPostActions` is the hook that dispatches node change events to standing query states. The `NodeSnapshot` includes `subscribersToThisNode` and `domainNodeIndex`.
- **Graph Structure** (`graph/StandingQueryOpsGraph.scala`, `graph/BaseGraph.scala`): `StandingQueryOpsGraph` is a trait mixed into `GraphService` that provides the top-level SQ lifecycle API. `NamespaceSqIndex` is the global registry. `relayTell`/`relayAsk` are used for cross-node subscription messages.
- **Cypher** (`graph/cypher/`): The MVSQ AST reuses Cypher expression types (`Expr`, `Value`, `QueryContext`). `FilterMapState` evaluates Cypher expressions on each result row. The Cypher compiler produces the `MultipleValuesStandingQuery` AST from `MATCH ... RETURN` patterns.
- **Persistence** (`persistor/`): `StandingQueryInfo` is persisted/restored on startup. `MultipleValuesStandingQueryState` can be persisted per-update, on-sleep, or never (`PersistenceSchedule`). `DomainGraphNode`s are persisted by the `DomainGraphNodeRegistry`. `DomainIndexEvent`s are journaled as `NodeEvent`s.
- **Pekko Streams** (`org.apache.pekko.stream`): Result delivery uses `BoundedSourceQueue` -> `BroadcastHub` -> per-output `Sink`. Backpressure uses `SharedValve` (the `ingestValve`).
- **Metrics** (`graph/metrics/HostQuineMetrics`): Standing query result rates, dropped counts, queue timers, state sizes, result hash codes.

### External (JVM libraries)

- **Apache Pekko Actors**: Message delivery between nodes for subscription creation, cancellation, and result propagation. All SQ state mutations happen within the node actor's single-threaded `receive`.
- **Apache Pekko Streams**: `BoundedSourceQueue`, `BroadcastHub`, `Source`, `Sink`, `UniqueKillSwitch` for result streaming infrastructure.
- **Guava Hashing** (`com.google.common.hash`): Murmur3-128 for `MultipleValuesStandingQueryPartId` generation (hashing the AST to produce deterministic UUIDs) and for `StandingQueryResult.dataHashCode` (order-agnostic result checksumming).
- **Cats** (`cats.implicits`): `sequence` for `Option[List[...]] -> List[Option[...]]` in `CrossState.generateCrossProductResults`. `NonEmptyList` for `GraphQueryPattern.nodes`.
- **Circe** (`io.circe`): JSON serialization of `StandingQueryResult` for API responses.
- **Dropwizard Metrics** (`com.codahale.metrics`): `Timer`, `Meter`, `Counter` for result queue latency, result rates, and dropped result counts.

### Scala-Specific Idioms

- **Sealed hierarchy with pattern matching**: `MultipleValuesStandingQuery` (8 variants), `MultipleValuesStandingQueryState` (9 variants), `StandingQueryPattern` (3 variants), `WatchableEventType` (3 variants), `DomainGraphBranch` (6 variants). All use exhaustive pattern matching.
- **Abstract type member**: `MultipleValuesStandingQuery.State <: MultipleValuesStandingQueryState` and the inverse `MultipleValuesStandingQueryState.StateOf <: MultipleValuesStandingQuery`. This is a type-level pairing of query AST to state, enforced by the `createState()` factory method.
- **Mutable state within actor**: `MultipleValuesStandingQueryState` subclasses use `var` fields (`currentlyMatching`, `cachedResult`, `edgeResults`, `keptResults`, `lastReportedProperties`, etc.) that are safe because they are only accessed within the node actor's single-threaded message processing.
- **Late initialization**: `_query` in `MultipleValuesStandingQueryState` is `null` until `rehydrate()` is called. This avoids serializing the query AST with every state instance.
- **`mutable.Map` and `mutable.Set`**: Per-node SQ state uses mutable collections extensively for performance (these are hot paths).
- **Implicit parameters**: `LogConfig` and `QuineIdProvider` are threaded implicitly through state methods.
- **Trait mixin composition**: `MultipleValuesStandingQueryBehavior` and `DomainNodeIndexBehavior` are mixed into `NodeActor` to provide SQ handling capabilities.
- **`AtomicInteger` for backpressure coordination**: The `inBuffer` counter in `runStandingQuery` uses `getAndIncrement`/`getAndDecrement` to determine exactly when to open/close the ingest valve. The atomicity ensures the threshold is crossed exactly once in each direction.

## Essential vs. Incidental Complexity

### Essential (must port)

1. **Incremental per-node pattern matching**: The core algorithm where each node holds state for its portion of each standing query pattern, re-evaluates only on relevant changes, and propagates results incrementally. This is the defining feature of Quine.

2. **The MVSQ AST and state machines**: The `MultipleValuesStandingQuery` hierarchy (Cross, LocalProperty, Labels, LocalId, AllProperties, SubscribeAcrossEdge, EdgeSubscriptionReciprocal, FilterMap) and their corresponding state implementations. Each state type has specific semantics for initialization, event handling, subscription result handling, and result reading.

3. **Cross-edge subscription protocol**: The `SubscribeAcrossEdge` -> `EdgeSubscriptionReciprocal` -> `andThen` chain. When a matching edge is found, the subscribing node creates a reciprocal query on the remote node. The remote node verifies the reciprocal half-edge and then subscribes to the continuation query locally. Results flow back. Edge removal triggers cancellation.

4. **The `StandingQueryWatchableEventIndex`**: The per-node index that maps `PropertyChange(key)` and `EdgeChange(label)` events to interested subscribers. This enables O(1) dispatch to relevant query states rather than checking all states on every event.

5. **Result diffing and cancellation**: The `MultipleValuesResultsReporter` that tracks last-reported results and computes the diff (new matches, cancelled matches) when a result group changes. This is essential for the "standing" semantics where consumers see incremental updates.

6. **Cross-product computation**: The `CrossState` that lazily accumulates results from multiple subqueries and computes their Cartesian product. The `emitSubscriptionsLazily` optimization avoids subscribing to later subqueries until earlier ones produce results.

7. **DGB boolean propagation**: The DistinctId system where each node reports `true`/`false` for whether it matches a DGB pattern, combining local property tests with downstream edge subscription results. The `DomainNodeIndex` caches downstream results; `SubscribersToThisNode` tracks who to notify.

8. **Global part ID registry**: The `NamespaceSqIndex.partIndex` that maps `MultipleValuesStandingQueryPartId` -> `MultipleValuesStandingQuery` globally. Nodes look up query definitions by part ID when creating states, avoiding the need to serialize the full query AST with every state.

9. **Backpressure from results to ingest**: When standing query result buffers fill, ingest must slow down. The threshold-based valve mechanism is essential for production stability.

10. **Query registration and propagation**: The protocol for registering a new standing query, persisting it, and propagating it to all nodes (via `UpdateStandingQueries` messages or on-wake sync).

### Incidental (rethink for Roc)

1. **Pekko actor message dispatch**: All SQ messages (`CreateMultipleValuesStandingQuerySubscription`, `NewMultipleValuesStateResult`, etc.) are dispatched through Pekko's actor mailbox. The essential concept is "send a subscription/result to a node"; the message routing mechanism is incidental.

2. **Mutable state within sealed case classes**: The `MultipleValuesStandingQueryState` subclasses use `var` fields for performance within the single-threaded actor context. In Roc, these would be explicit state records threaded through update functions.

3. **Late-init `_query` field**: The null-initialized `_query` that is set by `rehydrate()` exists to avoid serializing the query AST. In Roc, the state could simply hold the part ID and look up the query on demand, or the query could be passed as a parameter.

4. **`BroadcastHub` and `BoundedSourceQueue`**: Pekko Streams infrastructure for result delivery. The essential need is: a bounded buffer that fans out to multiple consumers with backpressure. Any pub-sub mechanism suffices.

5. **`AtomicInteger` for valve coordination**: The precise counting mechanism for backpressure thresholds exists because the queue and the valve are in different async contexts. In a single-threaded-per-node model, simpler mechanisms may work.

6. **`UniqueKillSwitch` per output**: Each output sink has a kill switch for independent cancellation. This is Pekko Streams lifecycle management.

7. **DomainGraphBranch / DomainGraphNode duality**: The by-value (`DomainGraphBranch`) vs by-ID (`DomainGraphNode`) representations exist because the pattern needs to be both traversable (by-value) and referenceable across nodes (by-ID). In Roc, a single representation with explicit ID references would suffice.

8. **`DomainGraphNodeRegistry` with reference counting**: The registry uses `ConcurrentHashMap.compute` with reference counting to know when a DGN can be removed. In Roc, this simplifies to a `Dict` with a reference count field.

9. **Three separate SQ systems**: The DGB, MVSQ, and QuinePattern systems coexist due to historical evolution. A Roc port could unify on a single system (likely MVSQ-like) from the start.

10. **`Notifiable` as `Either[QuineId, StandingQueryId]`**: The DGB system routes results either to another node (Left) or to the top-level query (Right). This type encoding is Scala-specific.

## Roc Translation Notes

### Maps Naturally

- **MVSQ AST as tagged union**:
  ```
  MultipleValuesStandingQuery : [
      UnitSq,
      Cross { queries : List MultipleValuesStandingQuery, emitSubscriptionsLazily : Bool },
      LocalProperty { propKey : Str, constraint : ValueConstraint, aliasedAs : Result Str [NoAlias] },
      Labels { aliasedAs : Result Str [NoAlias], constraint : LabelsConstraint },
      LocalId { aliasedAs : Str, formatAsString : Bool },
      AllProperties { aliasedAs : Str },
      SubscribeAcrossEdge { edgeName : Result Str [AnyEdge], edgeDirection : Result EdgeDirection [AnyDirection], andThen : MultipleValuesStandingQuery },
      EdgeSubscriptionReciprocal { halfEdge : HalfEdge, andThenId : PartId },
      FilterMap { condition : Result Expr [NoFilter], toFilter : MultipleValuesStandingQuery, dropExisting : Bool, toAdd : List (Str, Expr) },
  ]
  ```

- **ValueConstraint as tagged union**:
  ```
  ValueConstraint : [
      Equal Value,
      NotEqual Value,
      Unconditional,
      Any,
      None,
      Regex Str,
      ListContains (Set Value),
  ]
  ```

- **WatchableEventType as tagged union**:
  ```
  WatchableEventType : [
      PropertyChange Str,
      EdgeChange (Result Str [AnyLabel]),
      AnyPropertyChange,
  ]
  ```

- **StandingQueryResult as record**: `{ isPositiveMatch : Bool, data : Dict Str QuineValue }`

- **PartId computation**: Hash the MVSQ AST deterministically to a UUID. This is a pure function over the tagged union.

- **Result diffing**: `generateResultReports` is a pure function: `(oldResults, newResults, includeCancellations) -> List StandingQueryResult`. Trivially portable.

- **WatchableEventIndex**: A record of `Dict`s mapping event types to subscriber sets. Pure data structure with register/unregister/lookup operations.

### Needs Different Approach

- **Per-node mutable SQ state**: The `MultipleValuesStandingQueryState` instances use mutable fields (`var`, `mutable.Map`) within the actor's single-threaded context. In Roc, each state type becomes an immutable record, and update functions return a new state:
  ```
  onNodeEvents : LocalPropertyState, List NodeChangeEvent, EffectHandler -> { state : LocalPropertyState, changed : Bool }
  ```
  The node holds `Dict (StandingQueryId, PartId) SqPartState` where `SqPartState` is a tagged union of all state types.

- **Effect handlers as trait implementations**: `MultipleValuesStandingQueryEffects` is a trait with methods like `createSubscription`, `cancelSubscription`, `reportUpdatedResults`. In Roc, this becomes a record of functions passed to state update functions, or the update functions return a list of effects to be executed by the node:
  ```
  SqEffect : [
      CreateSubscription { onNode : QuineId, query : MultipleValuesStandingQuery },
      CancelSubscription { onNode : QuineId, queryId : PartId },
      ReportResults (List QueryContext),
  ]
  ```

- **Cross-node subscription via messages**: `SubscribeAcrossEdge` sends `CreateMultipleValuesStandingQuerySubscription` to remote nodes via `relayTell`. In Roc, this becomes an effect that the node runtime executes, delivering a subscription message to the target node's message queue.

- **BroadcastHub for result fan-out**: Replace with a bounded channel that multiple consumers can read from, or a simple list of callback functions that the result queue invokes.

- **Backpressure via valve**: Replace the `AtomicInteger` + `SharedValve` with a bounded channel. When the channel is full, producers (nodes emitting results) receive a backpressure signal. Ingest sources check a global backpressure flag before producing more data.

- **DGB system**: Consider whether to port the DGB system at all. It is less expressive than MVSQ and exists primarily for backward compatibility. If the Roc port starts fresh, MVSQ alone may suffice for all use cases.

- **QueryContext / Expr evaluation in FilterMap**: `FilterMapState` evaluates Cypher `Expr`s at runtime against `QueryContext` rows. This requires porting the Cypher expression evaluator (at least the subset used in standing queries: comparisons, property access, function calls).

### Open Questions

1. **Should the Roc port unify on a single standing query system?** The MVSQ system subsumes most of the DGB system's capabilities. Porting only MVSQ would significantly reduce complexity. The QuinePattern system is still evolving and may eventually replace MVSQ.

2. **How to handle the global part ID registry?** The `NamespaceSqIndex.partIndex` is a graph-level lookup that nodes access during state creation. In Roc, this could be: (a) a graph-level `Dict` passed to nodes, (b) a service that nodes query, or (c) the full query AST embedded in the subscription message (trading memory for simplicity).

3. **What is the right state persistence strategy?** The three options (OnNodeUpdate, OnNodeSleep, Never) trade durability for performance. The Roc port needs to decide which to support. OnNodeSleep is simplest (just serialize state as part of the node snapshot). OnNodeUpdate requires per-state-change persistence, which is more complex but more durable.

4. **How to handle the `emitSubscriptionsLazily` optimization in CrossState?** This optimization avoids subscribing to later subqueries until earlier ones produce results, which reduces wasted work for queries where the first subquery is highly selective. In Roc, the state update function would return a "subscribe to next subquery" effect conditionally.

5. **How to handle result group semantics?** MVSQ results are reported as complete groups (all rows for a state at once), not individual rows. The diffing logic in `MultipleValuesResultsReporter` depends on this. The Roc port needs to preserve this group-at-a-time semantics.

6. **What subset of Cypher expressions is needed for FilterMap?** The standing query system only uses a subset of Cypher expressions (property access, comparisons, boolean logic, function calls like `id()` and `labels()`). Identifying this subset would scope the expression evaluator that needs to be ported.

7. **How to handle the recursive structure of the MVSQ AST?** `Cross` contains a list of `MultipleValuesStandingQuery`, `SubscribeAcrossEdge` contains an `andThen` child, `FilterMap` contains a `toFilter` child. In Roc, recursive tagged unions are natural, but the `queryPartId` computation (hashing the entire subtree) needs care to avoid stack overflow on deep patterns.

8. **Should EdgeSubscriptionReciprocal remain a separate type?** It is synthetically created by `SubscribeAcrossEdgeState` and not globally indexed. It could potentially be inlined into the edge subscription protocol rather than being a full AST node.

9. **How to test the incremental matching algorithm?** The algorithm's correctness depends on subtle interactions between event dispatch, state updates, subscription creation, and result propagation. A comprehensive test suite should cover: single-node property matches, cross-edge subscriptions, edge removal and cancellation, Cross product semantics, FilterMap evaluation, result diffing, and backpressure behavior.

10. **How to handle the DomainNodeEquiv local test?** The DGB system tests local node properties against a `DomainNodeEquiv` predicate using `NodeLocalComparisonFunc` (e.g., `EqualSubset`). If the DGB system is ported, these comparison functions need equivalents in Roc.
