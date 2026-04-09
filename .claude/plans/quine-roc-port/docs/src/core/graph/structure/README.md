# Graph Structure

## What Happens Here

The graph structure layer defines how nodes are organized, addressed, and managed at the system level. It sits between the single-node model (Task 1) and the application-facing API. The core architecture is: **one `GraphService` object composes multiple traits to assemble the graph's API surface, delegates node management to a fixed number of `GraphShardActor`s, each of which owns a partition of the node space.**

### Organizational Hierarchy: GraphService -> Shards -> Nodes

The concrete graph implementation is `GraphService` (in `quine-core/.../graph/GraphService.scala`). It is the single class that unifies all graph capabilities:

```
class GraphService(...)
    extends StaticShardGraph       // shard topology, message routing, shutdown
    with LiteralOpsGraph           // direct property/edge CRUD
    with AlgorithmGraph            // graph algorithms (random walks)
    with CypherOpsGraph            // Cypher query execution
    with StandingQueryOpsGraph     // standing query lifecycle
    with QuinePatternOpsGraph      // Quine pattern matching hooks
```

On construction, `GraphService`:
1. Calls `initializeShards()` (from `StaticShardGraph`) to create `shardCount` shard actors
2. Loads domain graph nodes and standing queries from the persistor
3. Registers standing queries on the in-memory registry
4. Marks itself as ready via `_isReady = true`

### Shard Topology (StaticShardGraph)

`StaticShardGraph` (in `quine-core/.../graph/StaticShardGraph.scala`) implements the shard layer:

- The number of shards is fixed at construction time (`shardCount`, default 4).
- `initializeShards()` creates an `ArraySeq[LocalShardRef]` of exactly `shardCount` entries.
- Each shard is a Pekko actor (`GraphShardActor`) created via `system.actorOf(...)` with a dedicated shard dispatcher (`pekko.quine.graph-shard-dispatcher`) and a custom shard mailbox (`pekko.quine.shard-mailbox`).
- Each `LocalShardRef` wraps the shard's `ActorRef`, its `shardId`, and a reference to the shard's `nodesMap` (a `concurrent.Map[NamespaceId, concurrent.Map[SpaceTimeQuineId, NodeState]]`).

### QuineId -> Shard Routing

When a message needs to reach a node, the routing path is:

1. `idProvider.nodeLocation(qid)` computes a `QuineGraphLocation(hostIdx: Option[Int], shardIdx: Int)`.
   - The default implementation (`defaultNodeDistribution`) hashes the QuineId bytes to 4 bytes and converts to an `Int`.
   - Some providers (e.g., `WithExplicitPositions`) override this to extract the shard index from the ID itself.
2. `Math.floorMod(shardIdx, shards.length)` maps the shard index to an actual shard in the local array.
3. The message is delivered to the shard, which looks up or creates the node actor.

This is implemented in `StaticShardGraph.relayTell` and `StaticShardGraph.relayAsk`:

**relayTell (fire-and-forget)**:
1. Compute the target shard from the QuineId.
2. Attempt a fast path: `shard.withLiveActorRef(qidAtTime, _.tell(message, sender))` -- this acquires a read lock on the node's `actorRefLock`, sends the message directly to the node actor, and releases the lock. This avoids routing through the shard actor entirely.
3. If the fast path fails (node is asleep or waking), enqueue the message into the node's external message queue and send a `WakeUp` message to the shard actor.

**relayAsk (request-response)**:
1. Create a temporary `ExactlyOnceAskNodeActor` to hold the `Promise[Resp]`.
2. Attempt the same fast path as `relayTell`.
3. If the fast path fails, enqueue and wake up.
4. The temporary actor handles timeout, deduplication (for remote nodes), and response routing.

### GraphShardActor: Node Lifecycle Manager

`GraphShardActor` (in `quine-core/.../graph/GraphShardActor.scala`) is the Pekko actor that manages a partition of the node space. Its key responsibilities:

**Node State Tracking**: Maintains `namespacedNodes: concurrent.Map[NamespaceId, concurrent.Map[SpaceTimeQuineId, NodeState]]` where `NodeState` is either:
- `WakingNode` -- the shard has started rehydrating this node from persistence but the actor is not yet live.
- `LiveNode(costToSleep, actorRef, actorRefLock, wakefulState)` -- the actor is running.

**Node Wake-Up** (handling `WakeUp` message):
1. Check if the node is already awake (`getAwakeNode`).
2. If nonexistent, check the hard in-memory limit.
3. Set the node to `WakingNode` in the nodes map.
4. Call `nodeStaticSupport.readConstructorRecord(id, snapshotOpt, graph)` to asynchronously load the node's state from persistence.
5. On success, send `NodeStateRehydrated` to self, which creates the Pekko actor via `context.actorOf(props, name = id.toInternalString)`.
6. Record the `LiveNode` in the nodes map and update the LRU.

**Node Sleep (Memory Eviction)**:
1. Every 10 seconds, `CheckForInactiveNodes` triggers `inMemoryActorList.doExpiration()`.
2. The LRU (`ExpiringLruSet.SizeAndTimeBounded`) evicts nodes exceeding the soft limit, calling `sleepActor` for each.
3. `sleepActor` atomically transitions the node's `wakefulState` from `Awake` to `ConsideringSleep` and sends the node a `GoToSleep` message.
4. The node (via `GoToSleepBehavior`) decides whether to actually sleep based on the deadline and recent activity.
5. If the node sleeps, it persists its snapshot, acquires a write lock on `actorRefLock` (permanently), and calls `context.stop(self)`.
6. The shard receives `SleepOutcome.SleepSuccess` or `SleepOutcome.SleepFailed` and updates its bookkeeping.

**In-Memory Limits**: The shard supports both a `softLimit` (target capacity -- LRU eviction starts) and a `hardLimit` (absolute max -- new wake-ups are delayed).

**Message Deduplication**: A basic LRU cache of the last 10,000 `DeliveryRelay` dedup IDs prevents duplicate cross-host messages.

**Namespace Management**: The shard handles `CreateNamespace` and `DeleteNamespace` messages, adding/removing entries in `namespacedNodes`.

### Graph Public API Surface (Trait Mixins)

Each trait mixed into `GraphService` adds a domain of operations:

**BaseGraph** (the foundation trait): Defines the core graph contract:
- `system: ActorSystem`, `idProvider: QuineIdProvider`, `namespacePersistor: PrimePersistor`
- `relayTell` / `relayAsk` -- message routing
- `shards`, `shardFromNode` -- shard access
- `enumerateAllNodeIds` -- node enumeration (persistence + in-memory)
- `createNamespace` / `deleteNamespace` / `getNamespaces`
- `effectOrder: EventEffectOrder` -- memory-first vs persistor-first
- Node type parameters: `type Node <: AbstractNodeActor`, `type Snapshot`, `type NodeConstructorRecord`
- Configuration: `labelsProperty`, `declineSleepWhenWriteWithinMillis`, `declineSleepWhenAccessWithinMillis`, `maxCatchUpSleepMillis`

**StaticShardGraph** (shard topology): Implements `relayTell`, `relayAsk`, `shardFromNode`, `shutdown`, shard initialization.

**LiteralOpsGraph** (direct property/edge manipulation): Provides `literalOps(namespace)` returning a `LiteralOps` instance with:
- `getProps`, `setProp`, `removeProp`, `setLabels`
- `getHalfEdges`, `getHalfEdgesFiltered`, `addEdge`, `removeEdge`, `getEdges`
- `purgeNode`, `deleteNode`, `logState`, `nodeIsInteresting`
- All operations work by sending messages to node actors via `relayAsk`.
- Edge operations (add/remove) send messages to both endpoints in parallel.

**AlgorithmGraph** (graph algorithms): Provides `algorithms.randomWalk(...)` and `algorithms.saveRandomWalks(...)`, implementing Node2Vec-style random walks with configurable return/in-out parameters.

**CypherOpsGraph** (Cypher query execution): Provides `cypherOps.query(...)` and `cypherOps.continueQuery(...)`. Uses interpreters (`ThoroughgoingInterpreter` for current time, `AtTimeInterpreter` for historical) and a `skipOptimizerCache` (Caffeine cache of `SkipOptimizingActor`s).

**StandingQueryOpsGraph** (standing query lifecycle): Provides per-namespace `NamespaceStandingQueries` with:
- `createStandingQuery`, `cancelStandingQuery`, `listStandingQueries`
- `propagateStandingQueries` -- propagate SQ registration to all nodes
- `reportStandingResult` -- enqueue results for output
- Result distribution via `BroadcastHub` with backpressure through `SharedValve` (the `ingestValve`).
- `DomainGraphNodeRegistry` for managing the pattern tree.
- A consolidated `NamespaceSqIndex` that atomically maps standing query IDs to `RunningStandingQuery` instances and part IDs to `MultipleValuesStandingQuery` parts.

**QuinePatternOpsGraph** (Quine pattern matching hooks): Provides `getRegistry` and `getLoader` actor refs, plus `onNodeCreated` hooks that notify registered `NodeWakeHook`s when new nodes are created. Has a self-type dependency on `StandingQueryOpsGraph`.

### Node Creation vs. Lookup

There is no explicit "create node" operation. Nodes are created implicitly:
1. A message is sent to a `SpaceTimeQuineId` that doesn't correspond to an existing node actor.
2. The shard creates a new actor by loading from persistence (which returns an empty snapshot if the node has never existed).
3. The node actor starts with empty properties and edges if new, or restored state if previously persisted.

This means every `QuineId` "exists" in the sense that it can receive messages; the distinction is whether it has any data.

### Namespace Model

Namespaces (`NamespaceId = Option[Symbol]`, where `None` is the default namespace) provide logical partitioning of the graph:
- Each shard maintains a separate `concurrent.Map` of nodes per namespace.
- Standing queries are scoped to namespaces.
- Persistence is namespaced via `namespacePersistor(namespace)`.
- A `namespaceCache` (concurrent set) provides fast existence checks.
- Creating/deleting a namespace is a coordinated operation: the graph updates the cache, the persistor, standing query registries, and all shards.

## Key Types and Structures

### Graph Organization
| Type | Location | Role |
|------|----------|------|
| `GraphService` | `graph/GraphService.scala` | Concrete graph: composes all traits, owns shard array |
| `BaseGraph` | `graph/BaseGraph.scala` | Foundation trait: message routing, shard access, configuration |
| `StaticShardGraph` | `graph/StaticShardGraph.scala` | Fixed shard topology, `relayTell`/`relayAsk` implementation |
| `GraphShardActor` | `graph/GraphShardActor.scala` | Per-shard Pekko actor: node lifecycle, LRU, sleep/wake |
| `LocalShardRef` | `graph/messaging/LocalShardRef.scala` | Wrapper: shard `ActorRef` + `shardId` + `nodesMap` |
| `ShardRef` | `graph/messaging/ShardRef.scala` | Abstract: `quineRef`, `shardId`, `isLocal` |
| `InMemoryNodeLimit` | `graph/GraphShardActor.scala` | `softLimit` (LRU target) + `hardLimit` (absolute max) |

### Node State (within shard)
| Type | Location | Role |
|------|----------|------|
| `NodeState` | `graph/GraphShardActor.scala` | `WakingNode` or `LiveNode(costToSleep, actorRef, lock, state)` |
| `WakefulState` | `graph/GraphShardActor.scala` | `Awake`, `ConsideringSleep`, `GoingToSleep` |
| `LivenessStatus` | `graph/GraphShardActor.scala` | `AlreadyAwake`, `WakingUp`, `IncompleteActorShutdown`, `Nonexistent` |
| `CostToSleep` | referenced in `NodeState.LiveNode` | `AtomicLong`: higher = more expensive to evict |

### Messaging
| Type | Location | Role |
|------|----------|------|
| `QuineRef` | `graph/messaging/QuineRef.scala` | Sealed: `SpaceTimeQuineId` or `WrappedActorRef` |
| `QuineMessage` | `graph/messaging/QuineMessage.scala` | Base class for all graph messages |
| `AskableQuineMessage[Resp]` | `graph/messaging/QuineMessage.scala` | Messages expecting a response |
| `ExactlyOnceAskNodeActor` | `graph/messaging/ExactlyOnceAskNodeActor.scala` | Temp actor for request-response with timeout |
| `NodeActorMailbox` | `graph/messaging/NodeActorMailbox.scala` | Priority mailbox: `GoToSleep` is lower priority than other messages |

### Shard Control Messages
| Type | Location | Role |
|------|----------|------|
| `GoToSleep` | `graph/GraphShardActor.scala` | Shard -> node: please consider sleeping |
| `ProcessMessages` | `graph/GraphShardActor.scala` | Shard -> node: ensure dispatcher processes your mailbox |
| `SleepOutcome` | `graph/GraphShardActor.scala` | Node -> shard: `SleepSuccess` or `SleepFailed` |
| `StillAwake` | `graph/GraphShardActor.scala` | Node -> shard: I refused sleep, put me back in LRU |
| `WakeUp` | `graph/GraphShardActor.scala` | Internal to shard: wake this node (with retry logic) |
| `NodeStateRehydrated` | `graph/GraphShardActor.scala` | Internal to shard: persistence load completed |

### API Surface Traits
| Type | Location | Role |
|------|----------|------|
| `LiteralOpsGraph` | `graph/LiteralOpsGraph.scala` | Direct property/edge CRUD operations |
| `AlgorithmGraph` | `graph/AlgorithmGraph.scala` | Graph algorithms (random walks) |
| `CypherOpsGraph` | `graph/CypherOpsGraph.scala` | Cypher query execution |
| `StandingQueryOpsGraph` | `graph/StandingQueryOpsGraph.scala` | Standing query lifecycle management |
| `QuinePatternOpsGraph` | `graph/quinepattern/QuinePatternOpsGraph.scala` | Quine pattern matching hooks |

### Dispatchers
| Type | Location | Role |
|------|----------|------|
| `QuineDispatchers` | `util/QuineDispatchers.scala` | Three Pekko dispatchers: shard, node, blocking |

## Dependencies

### Internal (other stages/modules)

- **Node Model** (`graph/NodeActor.scala`, `graph/AbstractNodeActor.scala`): The graph creates and manages node actors. `StaticNodeSupport` provides the bridge between the graph and node construction.
- **Persistence** (`persistor/PrimePersistor`, `NamespacedPersistenceAgent`): The graph owns the `namespacePersistor` and threads it to nodes. Shard wake-up reads from persistence; sleep writes snapshots.
- **Standing Queries** (`graph/StandingQueryOpsGraph.scala`, `graph/DomainGraphNodeRegistry`): Standing query registration, result distribution, and DGN registry are graph-level concerns.
- **Cypher** (`graph/cypher/`): Query interpreters (`ThoroughgoingInterpreter`, `AtTimeInterpreter`) are created by `CypherOpsGraph`.
- **Metrics** (`graph/metrics/HostQuineMetrics`): The graph owns the metrics registry and distributes it to shards and nodes.

### External (JVM libraries)

- **Apache Pekko** (`org.apache.pekko`): The actor system, dispatchers, mailboxes, stream materializer, and `Props`/`ActorRef` abstractions. This is the foundational concurrency framework.
- **Pekko Streams** (`org.apache.pekko.stream`): `Source`, `Sink`, `Flow`, `BroadcastHub` for standing query result distribution, node enumeration, Cypher query results.
- **Caffeine** (`com.github.benmanes.caffeine`): LRU cache for `CypherOpsGraph.skipOptimizerCache` (via Scaffeine wrapper).
- **Dropwizard Metrics** (`com.codahale.metrics`): `Timer`, `Counter`, `MetricRegistry` for operational metrics throughout the graph.
- **Typesafe Config** (`com.typesafe.config`): Actor system configuration.

### Scala-Specific Idioms

- **Trait linearization / mixin composition**: `GraphService` composes 6 traits via `extends ... with ... with ...`. The order matters for initialization. This is Scala's mechanism for composing capabilities without multiple inheritance issues.
- **Abstract type members**: `BaseGraph` uses `type Node <: AbstractNodeActor`, `type Snapshot <: AbstractNodeSnapshot`, `type NodeConstructorRecord <: Product` to allow `GraphService` to fix the concrete types.
- **Self-type annotation**: `QuinePatternOpsGraph extends BaseGraph { this: StandingQueryOpsGraph => }` requires that any class mixing in `QuinePatternOpsGraph` also mix in `StandingQueryOpsGraph`.
- **`concurrent.Map` from JVM**: Scala wrappers around `ConcurrentHashMap` for thread-safe shard/node bookkeeping.
- **`AtomicReference[WakefulState]`**: Shared between shard actor and node actor for lock-free state machine transitions. Both actors can `updateAndGet` atomically.
- **`StampedLock` for actor ref safety**: Read locks during message send, permanent write lock on sleep. This is a JVM concurrency primitive for the "actor dying while someone sends to it" race condition.
- **Implicit parameters**: `Timeout`, `ResultHandler[Resp]`, `ExecutionContext` are threaded implicitly through the `relayAsk` call chain.
- **`requireBehavior[C, T]`**: Runtime check (via `ClassTag` reflection) that the graph's node type supports the needed behavior trait. A compile-time check would be preferable but is not currently implemented.

## Essential vs. Incidental Complexity

### Essential (must port)

1. **Shard-based node partitioning**: Nodes are partitioned across a configurable number of shards. This enables bounded memory per shard, parallel node management, and (in clustered mode) distributed placement. The QuineId -> shard mapping via hashing is the essential routing mechanism.

2. **Implicit node existence**: Any `QuineId` can be addressed without explicit creation. The system lazily materializes nodes on first message delivery. This is fundamental to how Quine ingests data -- nodes spring into existence as data arrives.

3. **Node sleep/wake lifecycle**: Nodes must be evictable from memory and restorable from persistence. This is what makes Quine capable of handling graphs larger than RAM. The essential state machine is: Awake -> ConsideringSleep -> GoingToSleep -> Asleep (and back).

4. **In-memory node limits**: Soft limits (target capacity with LRU eviction) and hard limits (absolute max, blocking wake-ups) are essential for memory management in production deployments.

5. **Request-response messaging to nodes**: The graph needs the ability to send a message to any node (by QuineId) and receive a typed response. This is the `relayAsk` pattern -- it abstracts over whether the node is awake, asleep, local, or remote.

6. **Fire-and-forget messaging**: The `relayTell` pattern for messages that don't need responses (standing query propagation, edge reciprocal updates).

7. **Fast-path direct delivery**: When a node is already awake and local, bypass the shard actor entirely and send directly to the node's actor ref. This is a critical performance optimization.

8. **Node enumeration**: The ability to enumerate all node IDs (from persistence + in-memory awake nodes) for operations like standing query propagation and graph-wide algorithms.

9. **Namespace isolation**: Logical partitioning of the graph into namespaces, each with its own node space, standing queries, and persistence.

10. **Graph API composition**: The trait-based composition that assembles the graph's public API from domain-specific modules (literal ops, Cypher, standing queries, algorithms).

### Incidental (rethink for Roc)

1. **Pekko actor system infrastructure**: `ActorSystem`, `ActorRef`, `Props`, `Materializer`, dispatcher configuration, mailbox types. These are the JVM-specific mechanism for concurrency. The essential concept is "shards and nodes process messages sequentially" -- but the implementation is entirely Pekko-specific.

2. **`StampedLock` for actor ref liveness**: This exists solely because Pekko actors can be stopped while someone holds a reference to them. In a system where the runtime manages node references, this race condition doesn't exist.

3. **ExactlyOnceAskActor**: Temporary Pekko actors created per `relayAsk` call. This is Pekko's pattern for request-response (actors don't have built-in request-response semantics). A runtime with native request-response support wouldn't need this.

4. **Custom mailbox with priority**: `NodeActorMailbox` implements a priority queue where `GoToSleep` messages have lower priority. This is Pekko-specific plumbing for the sleep/wake protocol.

5. **`concurrent.Map` wrappers around `ConcurrentHashMap`**: JVM concurrency primitives. The essential need is a thread-safe map of node IDs to node states.

6. **Trait linearization specifics**: The `extends ... with ... with ...` chain and the `initializeNestedObjects()` hack for lazy val initialization ordering are Scala-specific.

7. **`requireBehavior` runtime type checks**: These exist because Scala's type system couldn't express at compile time that "if the graph has `LiteralOpsGraph`, the node type must implement `LiteralCommandBehavior`." In Roc, this would be a module-level type constraint.

8. **Dispatcher configuration**: Three separate dispatchers (shard, node, blocking) are Pekko-specific thread pool management. The essential need is: shard operations shouldn't block node operations, and blocking I/O shouldn't block compute.

9. **MasterStream / SharedValve / ValveFlow**: Pekko Streams infrastructure for ingest backpressure. The essential concept is backpressure signaling when standing query buffers fill.

10. **Metric registry integration**: `HostQuineMetrics`, `Timer.Context`, counter increments interspersed throughout the code. Important operationally but not structurally.

## Roc Translation Notes

### Maps Naturally

- **QuineId -> shard routing**: A pure function `shardForNode : QuineId, U32 -> U32` that hashes the ID and mods by shard count. Trivially portable.

- **In-memory node limits**: `InMemoryNodeLimit { softLimit : U32, hardLimit : U32 }` as a record.

- **Namespace model**: `NamespaceId` as an opaque type (effectively `Result Str [Default]`), with a `Dict NamespaceId (...)` for per-namespace state.

- **Graph API as module composition**: Each trait becomes a Roc module exporting functions that take a graph handle. No trait linearization needed.

- **LiteralOps operations**: Pure request-response functions: `getProps : GraphHandle, NamespaceId, QuineId -> Task (Dict Str PropertyValue)`.

- **Node state tracking**: The shard's `NodeState` maps to a Roc tagged union:
  ```
  NodeState : [
      Waking,
      Live { costToSleep : I64, ... },
  ]
  ```

### Needs Different Approach

- **Shard actors**: Instead of Pekko actors, shards could be Roc tasks (or threads) with message channels. Each shard owns a `Dict SpaceTimeQuineId NodeState` and processes shard-level messages sequentially.

- **Node actors**: The fundamental challenge. Each node is a concurrent entity that processes messages sequentially. Options for Roc:
  - A per-node message queue with a shard-managed event loop that processes one node's messages at a time.
  - A platform-level actor abstraction (the Roc platform provides the message dispatch).
  - A synchronous model where node "messages" become function calls protected by per-node locks.

- **Fast-path direct delivery**: The `withLiveActorRef` + `StampedLock` pattern for bypassing the shard on the hot path. In Roc, this might become: check if the node is in the cache, and if so, enqueue directly into its message queue without going through the shard.

- **Sleep/wake persistence integration**: The GoToSleepBehavior calls `persistor.persistSnapshot(...)` asynchronously, then acquires a write lock and stops the actor. In Roc, this becomes a state machine where the shard handles the persistence future and the node handle becomes invalid after sleep.

- **ExactlyOnceAsk pattern**: Instead of creating a temporary actor per ask, Roc would use a `Task` with a timeout: `relayAsk : QuineRef, Msg -> Task Resp`.

- **BroadcastHub for standing query results**: Pekko Streams `BroadcastHub` distributes results to multiple consumers. In Roc, this could be a fan-out channel or pub-sub mechanism provided by the platform.

- **Backpressure via SharedValve**: The `ingestValve` that closes when standing query buffers fill. In Roc, this is a backpressure signal from the output stage to the ingest stage, likely implemented via channel capacity.

### Open Questions

1. **What is the Roc concurrency unit for nodes?** The entire architecture depends on the answer. If Roc provides lightweight tasks/fibers, each node could be a task with a message channel. If not, a scheduler that multiplexes node processing across a thread pool is needed.

2. **How to handle the shard actor's concurrent map access?** The `nodesMap` is accessed both from the shard actor (on-thread) and from `LocalShardRef.withLiveActorRef` (off-thread, for the fast path). This requires thread-safe data structures or explicit synchronization.

3. **Should the shard layer be preserved or simplified?** In a single-host Roc deployment, shards primarily serve as node LRU managers and parallelism units. Could this be a single "node manager" with a concurrent hash map, or is the shard partitioning essential for performance?

4. **How to implement the LRU eviction policy?** The `ExpiringLruSet.SizeAndTimeBounded` with the `costToSleep` callback is a custom LRU. Roc would need either a library or custom implementation.

5. **How to handle the "temporary actor per ask" pattern?** `ExactlyOnceAskNodeActor` manages a `Promise`, timeout, and deduplication. In Roc, this likely becomes a `Task` with `Task.timeout`, but the deduplication for remote delivery needs its own mechanism.

6. **Should namespaces be a first-class Roc concept or a thin layer?** Namespaces add complexity everywhere (every map is `Dict NamespaceId (Dict SpaceTimeQuineId ...)`) but provide useful isolation. The port could simplify by treating the default namespace as the only namespace initially.

7. **How to compose the graph API?** Scala uses trait mixins; Roc has no trait system. Options: a single large module, a record of function references (vtable-style), or separate modules that each take a graph handle parameter.

8. **What replaces the `requireBehavior` runtime check?** In Roc, if the graph API is composed from modules, the type system should statically guarantee that a graph supporting Cypher also supports the node behaviors Cypher needs. This might be a module functor or a capability token pattern.
