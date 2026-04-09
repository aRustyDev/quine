# Graph Node Model

## What Happens Here

The graph node model defines the atom of Quine's streaming graph: what a node IS, what data it holds, how it connects to other nodes, and how its state changes over time. Every node in the graph is an independent computational unit (implemented as a Pekko actor) identified by a `QuineId`, holding key-value properties, connected via half-edges, and maintaining a time-indexed journal of state changes.

### Identity: QuineId and SpaceTimeQuineId

A `QuineId` (defined in the external `com.thatdot:quine-id` library, imported as `com.thatdot.common.quineid.QuineId`) is fundamentally a wrapper around `Array[Byte]`. It provides `QuineId(bytes)` for construction, `.array` for access, and `.toInternalString` / `.fromInternalString` for hex-encoded string round-tripping. The raw byte array design is deliberate: it lets Quine accommodate any ID scheme (UUIDs, longs, strings) through pluggable `QuineIdProvider` implementations.

A `SpaceTimeQuineId` (in `quine-core/.../graph/messaging/QuineRef.scala`) extends identity across three dimensions:
- `id: QuineId` -- which node
- `namespace: NamespaceId` -- which logical graph partition
- `atTime: Option[Milliseconds]` -- `None` for the "current" (live) node, `Some(t)` for a historical snapshot at time `t`

This is the full address of a node in the system. Every live actor in the graph corresponds to exactly one `SpaceTimeQuineId`.

### QuineIdProvider: Pluggable ID Schemes

`QuineIdProvider` (in `quine-core/.../model/QuineIdProvider.scala`) is the abstraction that maps between user-facing ID types and internal `QuineId` byte arrays. It defines:
- `newCustomId()` -- generate a fresh node ID (must be thread-safe, cluster-unique)
- `customIdToBytes` / `customIdFromBytes` -- serialize/deserialize the custom type
- `customIdToString` / `customIdFromString` -- human-readable round-trip
- `valueToQid` / `qidToValue` -- convert between `QuineValue` and `QuineId` (used by query languages)
- `hashedCustomId(bytes)` -- deterministic ID generation from content
- `nodeLocation(qid)` -- determine which shard a node lives on

Concrete implementations in `quine-core/.../graph/QuineIdProviders.scala`:
- `IdentityIdProvider` -- QuineId IS the custom type (no conversion)
- `QuineUUIDProvider` -- UUID-based IDs (128 bits)
- `QuineIdLongProvider` -- sequential 64-bit integer IDs
- `QuineIdRandomLongProvider` -- random 53-bit integers (JS-safe)
- `Uuid3Provider`, `Uuid4Provider`, `Uuid5Provider` -- strict UUID version providers
- `NameSpacedUuidProvider` -- namespace-prefixed UUIDs (deprecated)
- `WithExplicitPositions` -- wrapper adding position-awareness to any provider

### Node Data: Properties

Properties are key-value pairs stored as `Map[Symbol, PropertyValue]`.

`PropertyValue` (in `quine-core/.../model/PropertyValue.scala`) is a sealed abstract class with a lazy serialization strategy. It exists in one of two states:
- `Deserialized` -- holds a `QuineValue`, lazily computes serialized bytes
- `Serialized` -- holds `Array[Byte]` (MessagePack format), lazily deserializes to `QuineValue`

This design optimizes the common case: when a node wakes from persistence, its properties arrive as bytes and may never be read. Deserialization is deferred until a query actually accesses the value. Serialization is cached for persistence.

`QuineValue` (in `quine-core/.../model/QuineValue.scala`) is the runtime value type, a sealed hierarchy:
- `Str(string: String)`
- `Integer(long: Long)` -- with small-integer cache (-128 to 127)
- `Floating(double: Double)`
- `True`, `False` -- singleton boolean values
- `Null`
- `Bytes(bytes: Array[Byte])`
- `List(list: Vector[QuineValue])`
- `Map(map: SortedMap[String, QuineValue])`
- `DateTime(instant: OffsetDateTime)`
- `Duration(duration: JavaDuration)`
- `Date(date: LocalDate)`
- `LocalTime(time: java.time.LocalTime)`
- `Time(time: OffsetTime)`
- `LocalDateTime(localDateTime: JavaLocalDateTime)`
- `Id(id: QuineId)` -- a node reference as a value

`QuineType` mirrors this hierarchy as a flat enum for runtime type checking without the data payload.

Serialization uses MessagePack with custom extension types for temporal values and IDs (extension bytes 32-38).

Labels are stored as a special property (a `QuineValue.List` of `QuineValue.Str` values under a configurable key `graph.labelsProperty`).

### Node Connections: HalfEdge

`HalfEdge` (in `quine-core/.../model/HalfEdge.scala`) represents one side of an edge:
```
HalfEdge(edgeType: Symbol, direction: EdgeDirection, other: QuineId)
```

`EdgeDirection` (in `quine-core/.../model/EdgeDirection.scala`) is a sealed hierarchy:
- `Outgoing` (index 0)
- `Incoming` (index 1)
- `Undirected` (index 2)

Each has a `reverse` method (`Outgoing.reverse = Incoming`, `Undirected.reverse = Undirected`).

**Why half-edges?** An edge in Quine exists if and only if both endpoints hold reciprocal half-edges. If node A has `HalfEdge(:KNOWS, Outgoing, B)`, then node B must have `HalfEdge(:KNOWS, Incoming, A)`. This design is essential for a distributed graph: each node stores only its own half of every edge, so no global edge table is needed. The `reflect(thisNode)` method on `HalfEdge` produces the reciprocal for the other endpoint.

`GenericEdge` (in `DomainGraphBranch.scala`) is a label+direction pair without the remote endpoint: `GenericEdge(edgeType: Symbol, direction: EdgeDirection)`. It represents an edge pattern rather than a concrete connection.

### State Changes: NodeEvent and NodeChangeEvent

Events represent mutations to node state. The hierarchy (in `quine-core/.../graph/NodeEvent.scala`):

```
sealed trait NodeEvent
  |
  +-- sealed abstract class NodeChangeEvent extends NodeEvent
  |     |
  |     +-- sealed abstract class PropertyEvent extends NodeChangeEvent
  |     |     +-- PropertySet(key: Symbol, value: PropertyValue)
  |     |     +-- PropertyRemoved(key: Symbol, previousValue: PropertyValue)
  |     |
  |     +-- sealed abstract class EdgeEvent extends NodeChangeEvent
  |           +-- EdgeAdded(edge: HalfEdge)
  |           +-- EdgeRemoved(edge: HalfEdge)
  |
  +-- sealed trait DomainIndexEvent extends NodeEvent
        +-- CreateDomainNodeSubscription(dgnId, replyTo: QuineId, relatedQueries)
        +-- CreateDomainStandingQuerySubscription(dgnId, replyTo: StandingQueryId, relatedQueries)
        +-- DomainNodeSubscriptionResult(from: QuineId, dgnId, result: Boolean)
        +-- CancelDomainNodeSubscription(dgnId, alreadyCancelledSubscriber: QuineId)
```

`NodeChangeEvent` (properties and edges) represents data mutations. `DomainIndexEvent` represents standing query subscription bookkeeping (not data mutations, but still journaled).

Events are timestamped via `NodeEvent.WithTime[E](event: E, atTime: EventTime)`.

`EventTime` (in `quine-core/.../graph/EventTime.scala`) packs three counters into a single 64-bit Long:
- **Top 42 bits**: wall-clock milliseconds since epoch
- **Middle 14 bits**: timestamp sequence number (disambiguates events in the same millisecond from different messages)
- **Bottom 8 bits**: event sequence number (disambiguates events from the same message)

This gives every event a globally unique, totally ordered timestamp.

### Node Snapshots

`NodeSnapshot` (in `quine-core/.../graph/NodeSnapshot.scala`) captures the full serializable state of a node:
- `time: EventTime`
- `properties: Map[Symbol, PropertyValue]`
- `edges: Iterable[HalfEdge]`
- `subscribersToThisNode` -- standing query subscription state
- `domainNodeIndex` -- index of which remote nodes this node has subscribed to

Snapshots are periodically persisted and used to avoid replaying the full event journal on wake-up.

### Node Lifecycle: WakefulState

A node's lifecycle is managed by the `WakefulState` sealed hierarchy (in `quine-core/.../graph/GraphShardActor.scala`):

1. **Awake** -- the actor is running and processing messages. Holds a `wakeTimer` context.
2. **ConsideringSleep** -- the shard has asked the node to sleep. The node has a deadline to decide. Holds `deadline`, `sleepTimer`, `wakeTimer`.
3. **GoingToSleep** -- the node has committed to sleeping. The actor ref lock is write-acquired (blocking all new messages), and the actor is being terminated. Holds a `shard: Promise[Unit]` and `sleepTimer`.

Transitions:
- A new node starts in `Awake` (created by `GraphShardActor`)
- The shard sends `GoToSleep`, transitioning from `Awake` to `ConsideringSleep`
- If a message arrives while `ConsideringSleep`, the node transitions back to `Awake`
- If the deadline expires, the node transitions to `GoingToSleep` and terminates
- On the next message to a sleeping node, the shard creates a new actor (back to `Awake`)

### Node Behavior: What a Node Can Do

`NodeActor` (in `quine-core/.../graph/NodeActor.scala`) extends `AbstractNodeActor` and defines the message dispatch in its `receive` method:
- `NodeControlMessage` -- lifecycle control (GoToSleep)
- `CypherQueryInstruction` -- Cypher query execution
- `LiteralCommand` -- direct property/edge manipulation
- `AlgorithmCommand` -- graph algorithms
- `DomainNodeSubscriptionCommand` -- standing query subscriptions (v1)
- `MultipleValuesStandingQueryCommand` -- standing query processing (v2)
- `UpdateStandingQueriesCommand` -- standing query registration/deregistration
- `QuinePatternCommand` -- pattern-based queries

The constructor performs initialization:
1. Initializes edge and property metric counters
2. Replays the journal (`PropertyEvent`, `EdgeEvent`, `DomainIndexEvent`) on top of the snapshot
3. Recomputes cost-to-sleep from edge count
4. Rebuilds the `StandingQueryWatchableEventIndex` and `NodeParentIndex`
5. Synchronizes standing queries with the graph (registers new ones, cleans up removed ones)
6. Stops the wake timer

`AbstractNodeActor` (in `quine-core/.../graph/AbstractNodeActor.scala`) provides the implementation of mutation operations:
- `processPropertyEvent` / `processPropertyEvents` -- apply property mutations
- `processEdgeEvent` / `processEdgeEvents` -- apply edge mutations
- `processDomainIndexEvent` -- apply standing query subscription changes
- `guardEvents` -- filters redundant events, timestamps remaining events, delegates to persistence+memory application
- `persistAndApplyEventsEffectsInMemory` -- handles the MemoryFirst vs PersistorFirst ordering
- `runPostActions` -- after state changes, notifies standing queries watching for relevant events
- `toSnapshotBytes` -- serializes full node state for persistence
- `persistSnapshot` -- writes snapshot to durable storage

The event effect ordering (`EventEffectOrder`) is configurable:
- **MemoryFirst**: apply to memory immediately, persist asynchronously with infinite retry
- **PersistorFirst**: persist first (pausing message processing), then apply to memory

### Edge Processing

`EdgeProcessor` (in `quine-core/.../graph/edges/EdgeProcessor.scala`) is an abstract class that manages edge state and persistence. Two implementations correspond to the two effect orderings:
- `MemoryFirstEdgeProcessor`
- `PersistorFirstEdgeProcessor`

Both maintain an in-memory edge collection, handle journaling, update metrics, and adjust the cost-to-sleep.

### Standing Query Integration

Nodes maintain a `StandingQueryWatchableEventIndex` that maps from watchable events (property changes, edge changes) to interested standing query subscribers. When a `NodeChangeEvent` occurs, `runPostActions` consults this index to notify only the relevant subscribers, avoiding unnecessary work.

### The Type Aliases in package.scala

`quine-core/.../model/package.scala` defines:
- `Properties = Map[Symbol, PropertyValue]`
- `QueryNode = DomainNodeEquiv` / `FoundNode = DomainNodeEquiv`
- `CircularEdge = (Symbol, IsDirected)` / `IsDirected = Boolean`

## Key Types and Structures

### Core Identity
| Type | Location | Role |
|------|----------|------|
| `QuineId` | external `com.thatdot:quine-id` | Opaque byte-array node identifier |
| `SpaceTimeQuineId` | `graph/messaging/QuineRef.scala` | Full node address: id + namespace + time |
| `QuineIdProvider` | `model/QuineIdProvider.scala` | Pluggable ID scheme abstraction |
| `Milliseconds` | `model/Milliseconds.scala` | Wall-clock timestamp (millis since epoch) |
| `EventTime` | `graph/EventTime.scala` | High-resolution event timestamp (42+14+8 bits) |

### Node Data
| Type | Location | Role |
|------|----------|------|
| `QuineValue` | `model/QuineValue.scala` | Sealed hierarchy of runtime values (15 variants) |
| `QuineType` | `model/QuineValue.scala` | Flat enum mirroring QuineValue variants |
| `PropertyValue` | `model/PropertyValue.scala` | Lazy-serializing value wrapper (Serialized or Deserialized) |

### Node Connections
| Type | Location | Role |
|------|----------|------|
| `HalfEdge` | `model/HalfEdge.scala` | One side of an edge: label + direction + remote node |
| `EdgeDirection` | `model/EdgeDirection.scala` | Outgoing, Incoming, Undirected |
| `GenericEdge` | `model/DomainGraphBranch.scala` | Edge pattern: label + direction (no endpoint) |

### State Changes
| Type | Location | Role |
|------|----------|------|
| `NodeEvent` | `graph/NodeEvent.scala` | Top-level sealed trait for all node events |
| `NodeChangeEvent` | `graph/NodeEvent.scala` | Property or edge mutations |
| `PropertyEvent` | `graph/NodeEvent.scala` | PropertySet, PropertyRemoved |
| `EdgeEvent` | `graph/NodeEvent.scala` | EdgeAdded, EdgeRemoved |
| `DomainIndexEvent` | `graph/NodeEvent.scala` | Standing query subscription bookkeeping |
| `NodeEvent.WithTime[E]` | `graph/NodeEvent.scala` | Timestamped event wrapper |

### Node State and Lifecycle
| Type | Location | Role |
|------|----------|------|
| `NodeSnapshot` | `graph/NodeSnapshot.scala` | Serializable full node state |
| `WakefulState` | `graph/GraphShardActor.scala` | Awake, ConsideringSleep, GoingToSleep |
| `NodeConstructorArgs` | `graph/NodeActor.scala` | Bundle of restoration data for constructing a node |
| `NodeActor` | `graph/NodeActor.scala` | Concrete Pekko actor for a graph node |
| `AbstractNodeActor` | `graph/AbstractNodeActor.scala` | Shared implementation of node behavior |
| `BaseNodeActor` | `graph/BaseNodeActor.scala` | Trait defining mutation API contract |
| `BaseNodeActorView` | `graph/BaseNodeActorView.scala` | Read-only view of node state |

### Domain Graph (Standing Query Pattern Model)
| Type | Location | Role |
|------|----------|------|
| `DomainGraphBranch` | `model/DomainGraphBranch.scala` | Sealed hierarchy: pattern tree for matching |
| `DomainGraphNode` | `model/DomainGraphNode.scala` | Persistent (by-ID) form of DomainGraphBranch |
| `DomainNodeEquiv` | `model/DomainNodeEquiv.scala` | Local node pattern: className + property predicates + circular edges |
| `NodeComponents` | `model/NodeComponents.scala` | Tree of matched results from a pattern query |
| `WatchableEventType` | `graph/WatchableEventType.scala` | EdgeChange, PropertyChange -- events SQs watch for |
| `StandingQueryWatchableEventIndex` | `graph/WatchableEventType.scala` | Index mapping events to interested SQ subscribers |

## Dependencies

### Internal (other stages/modules)

- **Persistence** (`quine-core/.../persistor/`): `NamespacedPersistenceAgent` for journal writes, snapshot persistence, and event retrieval. `PersistenceConfig` controls journal/snapshot behavior. `EventEffectOrder` (MemoryFirst vs PersistorFirst) affects mutation flow.
- **Standing Queries** (`quine-core/.../graph/behavior/`): `DomainNodeIndexBehavior`, `MultipleValuesStandingQueryBehavior`, `GoToSleepBehavior`, etc. -- mixed into `AbstractNodeActor` as traits.
- **Cypher** (`quine-core/.../graph/cypher/`): `CypherBehavior` for query execution, `MultipleValuesStandingQueryState`, `MultipleValuesResultsReporter`.
- **Graph Infrastructure** (`quine-core/.../graph/`): `BaseGraph`, `GraphShardActor`, `DomainGraphNodeRegistry`, `CostToSleep`.
- **Metrics** (`quine-core/.../graph/metrics/`): `HostQuineMetrics` for property sizes, edge counts, snapshot sizes, persistence timers.

### External (JVM libraries)

- **Apache Pekko** (`org.apache.pekko`): Actor system for node concurrency -- each node is a Pekko actor with a mailbox, lifecycle management, and message dispatch. `Actor`, `ActorRef`, `StampedLock` for actor ref safety.
- **Cats** (`cats-core`, `cats-data`): `NonEmptyList` for guaranteed-nonempty event batches, `Order` for `EventTime` ordering, `cats.implicits` for syntax.
- **MessagePack** (`org.msgpack:msgpack-core`): Binary serialization for `QuineValue` and `PropertyValue`. Custom extension types for temporal values and IDs.
- **Circe** (`io.circe`): JSON encoding/decoding for `QuineValue` (used in API layer).
- **Guava** (`com.google.common.hash`): Murmur3 hashing for `DomainGraphNode` ID computation.
- **memeid** (`memeid4s`): Strict UUID generation (v3, v4, v5) for ID providers.

### Scala-Specific Idioms

- **Sealed hierarchies with pattern matching**: `QuineValue`, `EdgeDirection`, `NodeChangeEvent`, `WakefulState`, `DomainGraphBranch` all use sealed traits/classes with exhaustive pattern matching. This is the Scala equivalent of tagged unions.
- **Implicit parameters**: `QuineIdProvider` is passed implicitly throughout the codebase (e.g., `def pretty(implicit idProvider: QuineIdProvider)`). This is essentially a type-class pattern for ID operations.
- **Type members and path-dependent types**: `QuineIdProvider` uses `type CustomIdType` and `type Aux[IdType]` for type-level abstraction of the underlying ID type.
- **Mixin traits for behavior**: `AbstractNodeActor` mixes in ~10 behavior traits (`CypherBehavior`, `GoToSleepBehavior`, etc.) to compose node capabilities.
- **`Symbol` as property/edge keys**: Scala's `Symbol` type (interned strings) is used for all property names and edge labels.
- **`var` with immutable `Map`**: Properties use `protected var properties: Map[Symbol, PropertyValue]` -- the variable is reassigned to a new immutable map on each mutation. This allows safe closure over the map reference by standing queries.
- **Lazy evaluation in `PropertyValue`**: Serialization and deserialization are lazily cached via null-check patterns (not `lazy val`, to avoid synchronization overhead).
- **`AtomicReference[WakefulState]`**: Thread-safe lifecycle state shared between the node actor and the shard actor.

## Essential vs. Incidental Complexity

### Essential (must port)

1. **QuineId as opaque byte array**: The identity model where nodes are addressed by arbitrary-length byte arrays is fundamental. The `QuineIdProvider` abstraction for pluggable ID schemes is a core feature.

2. **Half-edge model**: The design where each node stores only its half of every edge (with reciprocal halves on the other endpoint) is the key enabler for distributed graph storage. `HalfEdge(edgeType, direction, other)` and the `reflect` operation must be preserved.

3. **QuineValue type system**: The 15-variant value type (Str, Integer, Floating, True, False, Null, Bytes, List, Map, DateTime, Duration, Date, LocalTime, Time, LocalDateTime, Id) defines what data Quine can represent. This is the interpreter's value domain.

4. **Event-sourced state**: The `NodeChangeEvent` hierarchy (PropertySet, PropertyRemoved, EdgeAdded, EdgeRemoved) as the mechanism for state mutation is architecturally essential. It enables historical queries (replay events to any timestamp), standing queries (react to state changes), and append-only persistence.

5. **EventTime**: The 42+14+8 bit timestamp structure that gives every event a unique, totally ordered key within a node's journal. The three-component design (wall clock + message sequence + event sequence) is essential for correctness.

6. **Node state**: A node's state is: properties (`Map[Symbol, PropertyValue]`), edges (collection of `HalfEdge`), and standing query subscriptions. This is the data model that must be preserved.

7. **PropertyValue lazy serialization**: The optimization of deferring deserialization until access is essential for performance -- nodes may hold many properties that are never read during a query.

8. **Standing query event dispatch**: The `StandingQueryWatchableEventIndex` that maps specific property/edge changes to interested subscribers is essential for efficient incremental computation.

9. **Node lifecycle**: The concept of nodes that can sleep (be evicted from memory) and wake (be reconstructed from persistence) is fundamental to Quine's ability to handle graphs larger than memory.

10. **Snapshot + journal restoration**: Constructing a node from a snapshot plus journal replay is the core persistence/recovery mechanism.

### Incidental (rethink for Roc)

1. **Pekko actor mechanics**: The `Actor` trait, `receive` method, `ActorRef`, `context`, `sender()`, mailbox, `StampedLock` for actor ref safety -- all of this is the JVM concurrency framework. The essential concept is "each node processes messages sequentially" but the implementation mechanism is entirely Pekko-specific.

2. **Mixin trait composition**: The ~10 behavior traits mixed into `AbstractNodeActor` are a Scala organizational pattern. In Roc, node behavior would be composed differently (modules, function records, etc.).

3. **`Symbol` as key type**: Scala's `Symbol` is just an interned string. In Roc, `Str` with interning (or a dedicated key type) would suffice.

4. **MessagePack serialization**: The specific wire format for `QuineValue` is a persistence concern, not a core model concern. Roc would choose its own serialization.

5. **`AtomicReference` and `StampedLock`**: JVM concurrency primitives for thread-safe lifecycle management. Roc's concurrency model would handle this differently.

6. **`Future`-based async**: All mutation methods return `Future[Done.type]`. This is the JVM async model; Roc would use `Task` or similar.

7. **Implicit `QuineIdProvider`**: The implicit parameter threading is Scala's dependency injection pattern. In Roc, this would be an explicit parameter or module-level configuration.

8. **`var` with immutable map replacement**: The `properties = properties + (key -> value)` pattern for mutation-within-an-actor is a Scala/Pekko idiom. In Roc, this would be explicit state threading.

9. **Metrics integration**: The `HostQuineMetrics` calls interspersed throughout mutation code are operational concerns, not model concerns.

10. **DomainGraphBranch / DomainGraphNode duality**: The by-value (Branch) vs by-ID (Node) representations of the same pattern tree exist to support different stages of processing. This may simplify in Roc.

## Roc Translation Notes

### Maps Naturally

- **QuineValue** maps directly to a Roc tagged union:
  ```
  QuineValue : [
      Str Str,
      Integer I64,
      Floating F64,
      True,
      False,
      Null,
      Bytes (List U8),
      List (List QuineValue),
      Map (Dict Str QuineValue),
      DateTime ...,
      Id QuineId,
      ...
  ]
  ```

- **QuineType** maps to a simple tag enum (same variants without data).

- **HalfEdge** maps to a record: `{ edgeType : Str, direction : EdgeDirection, other : QuineId }`.

- **EdgeDirection** maps to a three-variant tag: `[Outgoing, Incoming, Undirected]`.

- **NodeChangeEvent** maps to a tagged union:
  ```
  NodeChangeEvent : [
      PropertySet { key : Str, value : PropertyValue },
      PropertyRemoved { key : Str, previousValue : PropertyValue },
      EdgeAdded HalfEdge,
      EdgeRemoved HalfEdge,
  ]
  ```

- **EventTime** maps to a `U64` with accessor functions for the three bit-packed components.

- **NodeSnapshot** maps to a record of the constituent data.

- **QuineIdProvider** maps to a record of functions (a manual type class / vtable):
  ```
  QuineIdProvider customId : {
      newId : {} -> customId,
      toBytes : customId -> List U8,
      fromBytes : List U8 -> Result customId Err,
      toStr : customId -> Str,
      fromStr : Str -> Result customId Err,
      hashedId : List U8 -> customId,
  }
  ```

- **PropertyValue's lazy dual representation** can be modeled as a tagged union `[Serialized (List U8), Deserialized QuineValue, Both (List U8) QuineValue]`, with pure functions to transition between states.

### Needs Different Approach

- **Node concurrency model**: Pekko actors provide sequential message processing per node. Roc has no built-in actor system. Options:
  - Platform-level message queues per node
  - A scheduler that pins node processing to a single task at a time
  - An event loop with per-node state isolated by the runtime

- **Node sleep/wake lifecycle**: The `WakefulState` machine depends on Pekko actor creation/destruction. In Roc, this becomes a cache eviction problem: node state lives in a bounded cache, evicted nodes are reconstructed from persistence on next access.

- **Mutable state within nodes**: `AbstractNodeActor` uses `var properties`, mutable edge collections, and mutable standing query indexes. Roc would use explicit state records passed through update functions, or platform-provided mutable state containers.

- **Future-based async persistence**: The `persistAndApplyEventsEffectsInMemory` method that orchestrates memory-first vs persistor-first ordering uses `Future` composition. Roc would use `Task` with explicit sequencing.

- **Thread-safe shared state**: `AtomicReference[WakefulState]` shared between shard and node actors. Roc's concurrency model would need an equivalent mechanism for cross-task state.

- **Message dispatch**: `NodeActor.receive` is a partial function dispatching on message type. In Roc, this becomes a function taking a tagged union of message types.

- **Implicit parameter threading**: The pervasive `implicit idProvider: QuineIdProvider` would become an explicit parameter in Roc, likely threaded at the application boundary rather than at every function call.

### Open Questions

1. **How to handle the QuineId external dependency?** QuineId is in an external library. We need to either: (a) inline a simple byte-array wrapper, or (b) find/create the equivalent in Roc. Given it is fundamentally `Array[Byte]` with hex-string round-tripping, inlining is straightforward.

2. **What is Roc's story for node-level concurrency?** The entire actor model (sequential per-node processing, mailbox, sleep/wake) needs a Roc equivalent. This is the single largest architectural decision.

3. **Should PropertyValue's lazy serialization be preserved?** In Roc, immutable values are cheap to pass around. The lazy ser/deser optimization may matter less, or it may matter more (if Roc's serialization is expensive). Needs benchmarking.

4. **How to represent Symbol (interned string) in Roc?** Scala Symbols are interned for fast equality. Roc strings may or may not have this property. A dedicated key type with interning may be needed for performance.

5. **Should the event-sourced model be preserved as-is, or can we use a simpler state model?** Event sourcing enables historical queries and standing queries. If those features are ported, event sourcing is required. But the specific event types and their serialization format can be redesigned.

6. **How to handle the MemoryFirst vs PersistorFirst ordering?** This is a consistency/performance tradeoff. The Roc port needs to decide whether to support both orderings or pick one.

7. **What temporal types does Roc support natively?** QuineValue includes DateTime, Duration, Date, LocalTime, Time, LocalDateTime. Roc's standard library may not have all of these, requiring custom implementations or a time library dependency.

8. **How should the DomainGraphBranch/DomainGraphNode pattern model work in Roc?** The current model uses recursive sealed hierarchies with Mu/MuVar for recursive patterns. This maps naturally to Roc tagged unions but the recursive structure needs careful handling.
