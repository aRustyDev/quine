# Persistence Layer

## What Happens Here

The persistence layer is Quine's pluggable durable storage system. It persists five categories of data: node change journals (event-sourced mutations), domain index event journals (standing query subscription bookkeeping), node snapshots (full serialized node state at a point in time), standing query definitions and their intermediate states, and metadata (version info, application config). The system uses a two-tier architecture: `PrimePersistor` manages global data (metadata, domain graph nodes) and acts as a namespace-aware factory for `NamespacedPersistenceAgent` instances, each of which manages per-namespace node data.

### Architecture Overview

The persistence layer is structured as follows:

```
PrimePersistor (abstract)
  |-- manages: Map[NamespaceId, NamespacedPersistenceAgent]
  |-- owns: metadata, domain graph nodes (global data)
  |-- factory: agentCreator(config, namespace) => PersistenceAgentType
  |
  +-- UnifiedPrimePersistor (abstract)
  |     |-- delegates global ops to getDefault (the default namespace's PersistenceAgent)
  |     +-- RocksDbPrimePersistor
  |     +-- AbstractMapDbPrimePersistor
  |     |     +-- PersistedMapDbPrimePersistor
  |     |     +-- TempMapDbPrimePersistor
  |     +-- StatelessPrimePersistor (wraps a lambda)
  |
  +-- PrimeCassandraPersistor (abstract)
        |-- owns its own MetaData and DomainGraphNodes Cassandra tables
        +-- vanilla.PrimeCassandraPersistor
        +-- aws.PrimeKeyspacesPersistor
```

Each `PrimePersistor` wraps its namespaced agents in two decorators before exposing them:
1. **ExceptionWrappingPersistenceAgent** -- catches and wraps exceptions with context about which operation failed
2. **BloomFilteredPersistor** (optional) -- uses a Guava BloomFilter on QuineId to short-circuit reads for nodes known not to exist, avoiding disk I/O

### What Gets Persisted

There are seven distinct data stores, each with a clear schema:

#### 1. Node Change Events (Journals)
- **Key**: `(QuineId, EventTime)` -- which node, when the event occurred
- **Value**: Serialized `NodeChangeEvent` (PropertySet, PropertyRemoved, EdgeAdded, EdgeRemoved)
- **Purpose**: Event-sourced log of all data mutations to a node. Used to replay state from a snapshot forward.
- **Operations**: persist batch, get by time range, enumerate all node IDs, delete by node ID

#### 2. Domain Index Events
- **Key**: `(QuineId, EventTime)`
- **Value**: Serialized `DomainIndexEvent` (CreateDomainNodeSubscription, DomainNodeSubscriptionResult, CancelDomainNodeSubscription, etc.)
- **Purpose**: Standing query subscription bookkeeping. Separate from node change events because these are not data mutations but subscription state.
- **Operations**: persist batch, get by time range, delete by node ID, delete by DomainGraphNodeId

#### 3. Snapshots
- **Key**: `(QuineId, EventTime)` -- node ID and snapshot timestamp
- **Value**: Serialized `NodeSnapshot` (FlatBuffer + packing)
- **Purpose**: Full serialized state of a node at a point in time. Avoids replaying the full journal on node wake-up.
- **Operations**: persist, get latest up to time, enumerate all node IDs, delete by node ID
- **Cassandra variant**: Uses multipart snapshots (splits large blobs into parts with `multipartIndex` and `multipartCount` columns) due to Cassandra's blob size limitations.

#### 4. Standing Queries
- **Key**: Standing query name (RocksDB/MapDB) or standing query ID (Cassandra)
- **Value**: Serialized `StandingQueryInfo`
- **Purpose**: Persisted definitions of registered standing queries, so they survive restart.
- **Operations**: persist, remove, get all

#### 5. Standing Query States (MultipleValues)
- **Key**: `(StandingQueryId, QuineId, MultipleValuesStandingQueryPartId)` -- which SQ, which node, which sub-query
- **Value**: Serialized `MultipleValuesStandingQueryState`
- **Purpose**: Intermediate state of standing query computation per node. Persisted on node sleep.
- **Operations**: get all for a node, set/clear for a specific (SQ, node, part) tuple, delete all for a node, remove all for a SQ

#### 6. Metadata
- **Key**: `String`
- **Value**: `Array[Byte]`
- **Purpose**: Arbitrary key-value pairs. Used for version tracking (`serialization_version`), application-level config. Supports local metadata scoped by `MemberIdx` for clustered deployments.
- **Operations**: get by key, get all, set/clear by key

#### 7. Domain Graph Nodes
- **Key**: `DomainGraphNodeId` (Long)
- **Value**: Serialized `DomainGraphNode`
- **Purpose**: Persistent pattern trees used by standing queries. Content-addressed (ID is derived from content).
- **Operations**: persist batch, remove batch, get all

### Serialization Format

All persistent data uses one of two serialization strategies:

**FlatBuffers + Packing** (for snapshots, node events, standing queries, domain graph nodes):
- `PackedFlatBufferBinaryFormat[A]` serializes via Google FlatBuffers, then applies `Packing.pack()` (a compression/encoding step).
- Reading: `Packing.unpack(bytes)` then `FlatBufferBuilder.readFromBuffer`.
- The `BinaryFormat[T]` type class provides `read(Array[Byte]): Try[T]` and `write(T): Array[Byte]`.

Codec implementations in `quine-core/.../persistor/codecs/`:
- `NodeChangeEventCodec` -- serializes `NodeChangeEvent` (PropertySet/PropertyRemoved/EdgeAdded/EdgeRemoved)
- `DomainIndexEventCodec` -- serializes `DomainIndexEvent`
- `SnapshotCodec` / `AbstractSnapshotCodec` -- serializes full `NodeSnapshot` (time, properties, edges, subscribers, domain node index)
- `StandingQueryCodec` -- serializes `StandingQueryInfo`
- `DomainGraphNodeCodec` -- serializes `DomainGraphNode`
- `MultipleValuesStandingQueryStateCodec` -- serializes standing query intermediate states
- `QuineValueCodec` -- serializes `QuineValue` (used within other codecs)

**Raw bytes** (for metadata, standing query states):
- Metadata values are opaque `Array[Byte]`.
- Standing query state values are serialized by `MultipleValuesStandingQueryStateCodec`.

### How Snapshots and Journals Work Together

The snapshot-journal system implements event sourcing with periodic checkpointing:

1. **On mutation**: When a node's state changes (property set, edge added, etc.), the change is journaled as a `NodeChangeEvent` with an `EventTime` timestamp. If `snapshotOnUpdate` is configured, a snapshot is also taken immediately.

2. **On node sleep**: If `snapshotOnSleep` is configured (the default), the node serializes its full state via `toSnapshotBytes()` and persists it. Standing query states are also persisted at this time. The snapshot timestamp is the `EventTime` of the latest update.

3. **On node wake-up** (`StaticNodeSupport.restoreFromSnapshotAndJournal`):
   - Fetch the latest snapshot up to the target time via `getLatestSnapshot(qid, upToTime)`
   - If journals are enabled, fetch journal events *after* the snapshot time via `getJournal(qid, startingAt, endingAt)`
   - Deserialize the snapshot (if any) into a `NodeSnapshot`
   - Pass both the snapshot and journal to `createNodeArgs`, which constructs the `NodeConstructorArgs`
   - The `NodeActor` constructor replays the journal events on top of the snapshot state

4. **Singleton snapshots**: If `snapshotSingleton` is true, all snapshots for a node use `EventTime.MaxValue` as the key, effectively keeping only the latest snapshot (overwriting the previous). This saves disk space but means the journal cannot be replayed from intermediate points.

5. **Historical queries**: For a node at a historical time `t`, the system fetches the latest snapshot at or before `t`, then replays journal events up to `t`. This enables time-travel queries.

### The `PersistenceConfig` Controls

```scala
PersistenceConfig(
  journalEnabled: Boolean = true,         // write events to journal?
  effectOrder: EventEffectOrder = PersistorFirst,  // memory-first or persistor-first?
  snapshotSchedule: PersistenceSchedule = OnNodeSleep,  // when to snapshot
  snapshotSingleton: Boolean = false,      // overwrite single snapshot per node?
  standingQuerySchedule: PersistenceSchedule = OnNodeSleep,  // when to persist SQ states
)
```

`PersistenceSchedule` has three values: `Never`, `OnNodeSleep`, `OnNodeUpdate`.

### EventEffectOrder: Memory-First vs Persistor-First

This controls the ordering of in-memory state updates relative to disk persistence:

**PersistorFirst** (default, most correct):
1. Compute the event
2. Persist to journal (blocking message processing via `pauseMessageProcessingUntil`)
3. Apply to in-memory state
4. Complete the query

If persistence fails, the query fails and can be retried. No other messages are processed until the persist completes.

**MemoryFirst** (lower latency, weaker consistency):
1. Compute the event
2. Apply to in-memory state immediately
3. Persist to journal asynchronously (with infinite retry on failure)
4. Complete the query after persistence succeeds

Changes are visible to queries and standing queries before they hit disk. Multiple updates can be in flight simultaneously.

### Version Management

The `Version(major, minor, patch)` system tracks the persistence format:
- Current version: `13.2.0`
- Compatibility: same major, current minor >= on-disk minor (forwards-compatible within a major version)
- Stored in metadata under key `serialization_version`
- On startup, `syncVersion()` checks compatibility and upgrades the stored version if compatible

## Key Types and Structures

### Core Interfaces
| Type | Location | Role |
|------|----------|------|
| `PrimePersistor` | `persistor/PrimePersistor.scala` | Abstract namespace-managing factory; owns global data (metadata, DGNs) |
| `NamespacedPersistenceAgent` | `persistor/PersistenceAgent.scala` | Per-namespace persistence interface: journals, snapshots, SQ states |
| `PersistenceAgent` | `persistor/PersistenceAgent.scala` | Extends `NamespacedPersistenceAgent` with global ops (metadata, DGNs) -- legacy shim |
| `PersistenceConfig` | `persistor/PersistenceConfig.scala` | Controls journal/snapshot/SQ scheduling and effect ordering |
| `EventEffectOrder` | `persistor/PersistenceConfig.scala` | MemoryFirst or PersistorFirst |
| `PersistenceSchedule` | `persistor/PersistenceConfig.scala` | Never, OnNodeSleep, OnNodeUpdate |
| `BinaryFormat[T]` | `persistor/BinaryFormat.scala` | Type class for binary serialization |
| `Version` | `persistor/Version.scala` | Semantic version for persistence format compatibility |

### Decorator / Infrastructure Types
| Type | Location | Role |
|------|----------|------|
| `UnifiedPrimePersistor` | `persistor/UnifiedPrimePersistor.scala` | PrimePersistor where global data lives in default namespace agent |
| `StatelessPrimePersistor` | `persistor/StatelessPrimePersistor.scala` | UnifiedPrimePersistor wrapping a creation lambda |
| `BloomFilteredPersistor` | `persistor/BloomFilteredPersistor.scala` | Decorator: Guava BloomFilter to skip reads for unknown nodes |
| `ExceptionWrappingPersistenceAgent` | `persistor/ExceptionWrappingPersistenceAgent.scala` | Decorator: wraps exceptions with operation context |
| `WrappedPersistenceAgent` | `persistor/WrappedPersistenceAgent.scala` | Base class for 1:1 persistor decorators |
| `PartitionedPersistenceAgent` | `persistor/PartitionedPersistenceAgent.scala` | Multiplexes nodes across multiple agents by QuineId hash |
| `ShardedPersistor` | `persistor/ShardedPersistor.scala` | Concrete partitioned agent with configurable shard function |
| `MultipartSnapshotPersistenceAgent` | `persistor/PersistenceAgent.scala` | Mixin for splitting large snapshots into parts (used by Cassandra) |

### Implementations
| Type | Location | Role |
|------|----------|------|
| `RocksDbPersistor` | `quine-rocksdb-persistor/.../RocksDbPersistor.scala` | Embedded RocksDB persistence |
| `RocksDbPrimePersistor` | `quine-rocksdb-persistor/.../RocksDbPrimePersistor.scala` | PrimePersistor factory for RocksDB |
| `MapDbPersistor` | `quine-mapdb-persistor/.../MapDbPersistor.scala` | Embedded MapDB persistence |
| `PersistedMapDbPrimePersistor` | `quine-mapdb-persistor/.../MapDbGlobalPersistor.scala` | PrimePersistor factory for MapDB |
| `CassandraPersistor` | `quine-cassandra-persistor/.../CassandraPersistor.scala` | Abstract Cassandra persistence |
| `vanilla.CassandraPersistor` | `quine-cassandra-persistor/.../vanilla/CassandraPersistor.scala` | Standard Cassandra |
| `aws.KeyspacesPersistor` | `quine-cassandra-persistor/.../aws/KeyspacesPersistor.scala` | AWS Keyspaces variant |
| `InMemoryPersistor` | `persistor/InMemoryPersistor.scala` | In-memory (testing/debugging) |
| `EmptyPersistor` | `persistor/EmptyPersistor.scala` | No-op (benchmarking) |

### Serialization Codecs
| Type | Location | Role |
|------|----------|------|
| `NodeChangeEventCodec` | `persistor/codecs/NodeChangeEventCodec.scala` | Ser/de for PropertySet, PropertyRemoved, EdgeAdded, EdgeRemoved |
| `DomainIndexEventCodec` | `persistor/codecs/DomainIndexEventCodec.scala` | Ser/de for domain index subscription events |
| `AbstractSnapshotCodec` | `persistor/codecs/SnapshotCodec.scala` | Ser/de for full NodeSnapshot (FlatBuffers) |
| `StandingQueryCodec` | `persistor/codecs/StandingQueryCodec.scala` | Ser/de for StandingQueryInfo |
| `DomainGraphNodeCodec` | `persistor/codecs/DomainGraphNodeCodec.scala` | Ser/de for DomainGraphNode |
| `MultipleValuesStandingQueryStateCodec` | `persistor/codecs/MultipleValuesStandingQueryStateCodec.scala` | Ser/de for SQ intermediate states |
| `PackedFlatBufferBinaryFormat` | `persistor/PackedFlatBufferBinaryFormat.scala` | FlatBuffers + packing base class |

## Backend Implementation Details

### RocksDB

**Storage model**: One RocksDB instance per namespace. Data is organized into 8 column families:
- `node-events` -- key: `(QuineId length: 2 bytes, QuineId bytes, EventTime: 8 bytes)`, value: serialized NodeChangeEvent
- `domain-index-events` -- same key schema, value: serialized DomainIndexEvent
- `snapshots` -- same key schema, value: serialized NodeSnapshot
- `standing-queries` -- key: standing query name (UTF-8 bytes), value: serialized StandingQueryInfo
- `standing-query-states` -- key: `(StandingQueryId: 16 bytes, QuineId length: 2 bytes, QuineId bytes, SQPartId: 16 bytes)`, value: serialized state
- `meta-data` -- key: metadata key (UTF-8 bytes), value: raw bytes
- `domain-graph-nodes` -- key: DomainGraphNodeId (8 bytes), value: serialized DomainGraphNode
- `default` -- RocksDB's required default column family (unused)

**Key encoding**: Keys are carefully encoded to preserve bytewise ordering under RocksDB's built-in bytewise comparator. QuineId is prefixed with a 2-byte unsigned length to handle variable-length IDs. EventTime is stored as a raw 8-byte long. StandingQueryId and MultipleValuesStandingQueryPartId are 16-byte UUIDs. See `RocksDbPersistor.qidAndTime2Key` and related methods.

**Concurrency**: A `StampedLock` protects all RocksDB operations. Regular operations (put, get, seek) use read locks (concurrent). Global operations (shutdown, reset) use write locks (exclusive). This prevents segfaults from concurrent access during shutdown.

**Configuration**: WAL (write-ahead log) can be enabled/disabled. Sync writes can be toggled. Universal style compaction is used. Custom `DBOptions` can be passed as properties.

**Range operations**: `getLatestSnapshot` uses `seekForPrev` to efficiently find the most recent snapshot. `deleteNodeChangeEvents` uses `deleteRange` for efficient bulk deletion. Journal retrieval uses iterator with `ReadOptions.setIterateUpperBound`.

### MapDB

**Storage model**: Memory-mapped B-tree maps and hash maps within a single MapDB file per shard.

**Data structures**:
- `nodeChangeEvents` -- `TreeMap[(QuineId bytes, EventTime long), byte[]]` with unsigned long comparator
- `domainIndexEvents` -- same structure
- `snapshots` -- same structure, with compression wrapper on values
- `standingQueries` -- `HashSet[byte[]]`
- `multipleValuesStandingQueryStates` -- `TreeMap[(UUID, QuineId bytes, UUID), byte[]]` with compression
- `metaData` -- `HashMap[String, byte[]]`
- `domainGraphNodes` -- `TreeMap[Long, byte[]]` with compression

**Key encoding**: Uses MapDB's `SerializerArrayTuple` which handles composite keys natively. A custom `SerializerUnsignedLong` ensures unsigned long comparison for EventTime ordering.

**Sharding**: MapDB supports optional sharding via `ShardedPersistor` to work around a performance cliff when DB files exceed ~2GB (commit times skyrocket). The shard count is configurable; nodes are partitioned by `QuineId.hashCode % shardCount`.

**Known issues**: Memory-mapped files grow without bound. A known MapDB bug (`GetVoid: record does not exist`) is worked around with retries. WAL doesn't work on Windows. Closing/deleting DB files doesn't work on Windows due to `mmap`.

**Strength**: No native code dependency -- runs on any JVM target.

### Cassandra (vanilla and AWS Keyspaces)

**Storage model**: CQL tables in a Cassandra keyspace, one set of tables per namespace (table names incorporate namespace).

**Table schemas**:
- `journals` -- partition key: `quine_id blob`, clustering key: `timestamp bigint ASC`, data: `data blob`. Uses time-window compaction.
- `snapshots` -- partition key: `quine_id blob`, clustering keys: `timestamp bigint DESC, multipart_index int`, data: `data blob, multipart_count int`. Descending timestamp for efficient latest-snapshot retrieval.
- `standing_queries` -- stores standing query definitions
- `standing_query_states` -- partition key: `quine_id blob`, clustering keys: `standing_query_id uuid, standing_query_part_id uuid`, data: `data blob`
- `domain_index_events` -- same schema as journals

**Multipart snapshots**: Cassandra uses `MultipartSnapshotPersistenceAgent` to split large snapshot blobs into parts. Each part has a `multipart_index` and `multipart_count`. On read, parts are reassembled and validated (checking that all parts agree on count and are contiguous). If validation fails, it falls back to the previous snapshot.

**AWS Keyspaces differences**:
- No `SELECT DISTINCT` support (Keyspaces falls back to full scans + client-side dedup via `dropRepeated()`)
- Batch size limited to 30 statements (handled by `SizeBoundedChunker`)
- `SingleRegionStrategy` replication instead of `SimpleStrategy`
- Table creation requires polling `system_schema_mcs.tables` for `ACTIVE` status
- SigV4 authentication via AWS SDK

**Prepared statements**: All CQL operations use prepared statements created at initialization time. The `PrepareStatements` class (a shapeless `~>` natural transformation) maps table definitions to their prepared statement instances.

## Dependencies

### Internal (other stages/modules)

- **Node Model** (`graph/NodeEvent.scala`, `graph/EventTime.scala`, `graph/NodeSnapshot.scala`): The types that get persisted -- `NodeChangeEvent`, `DomainIndexEvent`, `EventTime`, `NodeSnapshot`, `StandingQueryInfo`, etc.
- **Graph Infrastructure** (`graph/AbstractNodeActor.scala`, `graph/StaticNodeSupport.scala`, `graph/behavior/GoToSleepBehavior.scala`): The consumers of persistence -- node actors call `persistNodeChangeEvents`, `persistSnapshot`, `getLatestSnapshot`, and `getJournal` during their lifecycle.
- **Standing Queries** (`graph/StandingQueryId.scala`, `graph/cypher/MultipleValuesStandingQueryState.scala`): Standing query state types that get persisted.
- **Domain Graph Nodes** (`model/DomainGraphNode.scala`): Pattern trees persisted globally.

### External (JVM libraries)

- **RocksDB** (`org.rocksdb:rocksdbjni`): Embedded key-value store. Provides `RocksDB`, `ColumnFamilyHandle`, `DBOptions`, `WriteOptions`, `ReadOptions`, `RocksIterator`, `Slice`. Native code via JNI.
- **MapDB** (`org.mapdb:mapdb`): Pure-Java embedded database. Provides `DB`, `DBMaker`, `HTreeMap`, `ConcurrentNavigableMap`, `Serializer`, `SerializerArrayTuple`. Memory-mapped B-trees.
- **DataStax Java Driver** (`com.datastax.oss:java-driver-core`): Cassandra client. Provides `CqlSession`, `PreparedStatement`, `BatchStatement`, `SimpleStatement`, query builders.
- **AWS SDK** (`software.amazon.awssdk:sts`, `software.aws.mcs:aws-sigv4-auth-cassandra-java-driver-plugin`): AWS Keyspaces authentication.
- **Google FlatBuffers** (`com.google.flatbuffers:flatbuffers-java`): Binary serialization for snapshots and events. Schema-driven, zero-copy deserialization.
- **Google Guava** (`com.google.common.hash.BloomFilter`): Probabilistic set membership for the bloom filter optimization.
- **Apache Pekko Streams** (`org.apache.pekko:pekko-stream`): Used for `Source[QuineId, NotUsed]` in node enumeration operations.
- **Cats** (`cats-core`): `NonEmptyList` for guaranteed-nonempty event batches, `Monad[Future]` for Cassandra statement composition.
- **Shapeless** (`com.chuusai:shapeless`): `~>` (natural transformation) and tuple operations for Cassandra prepared statement creation.
- **Dropwizard Metrics** (`com.codahale.metrics`): Histogram and Counter for MapDB event size tracking.

### Scala-Specific Idioms

- **Abstract type member `PersistenceAgentType`**: `PrimePersistor` uses `type PersistenceAgentType <: NamespacedPersistenceAgent` to let subclasses narrow the agent type (e.g., `PersistenceAgent` for RocksDB/MapDB, `CassandraPersistor` for Cassandra).
- **Mixin trait composition**: `MultipartSnapshotPersistenceAgent` is mixed into `CassandraPersistor` via self-type (`this: NamespacedPersistenceAgent =>`).
- **Template method pattern via `protected def`**: `PrimePersistor` uses `internalGetMetaData` / `internalSetMetaData` etc. as extension points, with public methods providing exception wrapping.
- **Implicit `Materializer`**: Threaded through for Pekko Streams operations (node enumeration, bloom filter loading).
- **`Future`-based async**: All persistence operations return `Future[Unit]` or `Future[Option[...]]`. Operations are dispatched to dedicated execution contexts (`ioDispatcher`, `blockingDispatcherEC`).
- **`lazy val` for deferred initialization**: Cassandra prepared statements and the default persistor use `lazy val` to defer initialization until first use.

## Essential vs. Incidental Complexity

### Essential (must port)

1. **The `NamespacedPersistenceAgent` interface**: The 7 data categories and their CRUD operations define what persistence means for Quine. Every method on this trait represents a capability the system needs. The complete method set is:
   - `persistNodeChangeEvents`, `getNodeChangeEventsWithTime`, `deleteNodeChangeEvents`
   - `persistDomainIndexEvents`, `getDomainIndexEventsWithTime`, `deleteDomainIndexEvents`, `deleteDomainIndexEventsByDgnId`
   - `persistSnapshot`, `getLatestSnapshot`, `deleteSnapshots`
   - `persistStandingQuery`, `removeStandingQuery`, `getStandingQueries`
   - `getMultipleValuesStandingQueryStates`, `setMultipleValuesStandingQueryState`, `deleteMultipleValuesStandingQueryStates`
   - `persistQueryPlan`
   - `enumerateJournalNodeIds`, `enumerateSnapshotNodeIds`
   - `emptyOfQuineData`, `containsMultipleValuesStates`
   - `shutdown`, `delete`

2. **The `PrimePersistor` factory pattern**: Namespace-aware persistor management. The ability to create, delete, and look up per-namespace persistence agents. Plus global metadata and domain graph node storage. The complete method set on `PrimePersistor` itself is:
   - **Namespace lifecycle**: `createNamespace`, `deleteNamespace`, `prepareNamespace`, `apply` (lookup by NamespaceId), `getDefault`
   - **Metadata (global)**: `getMetaData`, `getAllMetaData`, `setMetaData`, `getLocalMetaData`, `setLocalMetaData`
   - **Domain graph nodes (global)**: `persistDomainGraphNodes`, `removeDomainGraphNodes`, `getDomainGraphNodes`
   - **Cross-namespace queries**: `getAllStandingQueries`, `emptyOfQuineData`
   - **Version management**: `syncVersion(context, versionMetaDataKey, currentVersion, isDataEmpty)`, `syncVersion()` (convenience overload for core quine data)
   - **Lifecycle**: `shutdown`, `declareReady`
   - **Extension points (protected)**: `agentCreator`, `internalGetMetaData`, `internalGetAllMetaData`, `internalSetMetaData`, `internalPersistDomainGraphNodes`, `internalRemoveDomainGraphNodes`, `internalGetDomainGraphNodes`
   - **Configuration**: `val persistenceConfig`, `val slug`

3. **Snapshot + journal event sourcing**: The fundamental restoration algorithm -- load latest snapshot, replay journal forward -- is architecturally essential. It enables time-travel queries and efficient node wake-up.

4. **`PersistenceConfig`**: The configurable scheduling (when to snapshot, when to persist SQ states) and effect ordering (memory-first vs persistor-first) are user-facing features that affect correctness and performance.

5. **The `BinaryFormat[T]` serialization contract**: Whatever format is chosen, the system needs a way to serialize/deserialize all persistent types. The type class pattern (or equivalent) is essential.

6. **Key encoding for ordered storage**: The composite key design `(QuineId, EventTime)` that preserves ordering is essential for efficient range queries (journal retrieval, latest snapshot lookup).

7. **Version management**: The ability to detect and handle persistence format changes across upgrades is a production requirement.

8. **Bloom filter optimization**: While technically optional, this is a significant performance optimization for the common case where many node lookups find nothing in the persistor.

### Incidental (rethink for Roc)

1. **`Future`-based async model**: All methods return `Future[T]`. Roc would use `Task` or a platform-native effect type.

2. **FlatBuffers serialization**: The specific binary format is replaceable. Roc might use a simpler binary format, or the platform's native serialization.

3. **Pekko Streams for enumeration**: `Source[QuineId, NotUsed]` is used for streaming node ID enumeration. Roc would use a different streaming abstraction.

4. **Decorator pattern for exception wrapping**: The `ExceptionWrappingPersistenceAgent` wrapper is a Scala-specific pattern. Roc would handle errors via `Result` types.

5. **Implicit `Materializer` threading**: Pekko Streams infrastructure. Not relevant to Roc.

6. **`StampedLock` in RocksDB**: JVM concurrency primitive. Roc's concurrency model would handle this differently.

7. **MapDB memory-mapped file management**: MapDB-specific concerns (commit intervals, sharding for performance) would not apply to a Roc implementation.

8. **Cassandra driver abstractions**: `CqlSession`, `PreparedStatement`, shapeless-based statement preparation -- all CQL-driver-specific.

9. **Sharding within a single persistor**: `ShardedPersistor` exists to work around MapDB's 2GB performance cliff. A different storage engine may not need this.

10. **`PersistenceAgent` trait (the legacy shim)**: The combined `NamespacedPersistenceAgent + global data` trait exists for backwards compatibility. A clean design would separate these cleanly from the start.

## Roc Translation Notes

### Maps Naturally

- **The persistence interface as a record of functions**: The `NamespacedPersistenceAgent` trait maps to a Roc record (or "ability") containing all the persistence operations:
  ```
  PersistenceAgent : {
      persistNodeChangeEvents : QuineId, NonEmptyList (WithTime NodeChangeEvent) -> Task {},
      getNodeChangeEventsWithTime : QuineId, EventTime, EventTime -> Task (List (WithTime NodeChangeEvent)),
      persistSnapshot : QuineId, EventTime, List U8 -> Task {},
      getLatestSnapshot : QuineId, EventTime -> Task (Result (List U8) [NotFound]),
      ...
  }
  ```

- **`PersistenceConfig`** maps directly to a Roc record:
  ```
  PersistenceConfig : {
      journalEnabled : Bool,
      effectOrder : [MemoryFirst, PersistorFirst],
      snapshotSchedule : [Never, OnNodeSleep, OnNodeUpdate],
      snapshotSingleton : Bool,
      standingQuerySchedule : [Never, OnNodeSleep, OnNodeUpdate],
  }
  ```

- **`Version`** maps to a simple record with comparison functions.

- **`BinaryFormat[T]`** maps to a pair of functions: `encode : T -> List U8` and `decode : List U8 -> Result T DecodeErr`.

- **Key encoding** (the `qidAndTime2Key` family of functions) maps naturally to pure Roc functions operating on byte lists.

- **The snapshot + journal restoration algorithm** is a pure function: `(Option Snapshot, List NodeEvent) -> NodeState`.

### Needs Different Approach

- **Pluggable backend architecture**: In Scala, the backend is selected at runtime via class hierarchy and configuration. In Roc, this would likely be:
  - A platform-level FFI for storage engines (RocksDB via C FFI)
  - A Roc-native storage engine for the default case
  - Backend selection via Roc platform configuration or dependency injection

- **Namespace management**: The `PrimePersistor` factory pattern with mutable `Map[NamespaceId, Agent]` would become an explicit state management pattern in Roc, possibly using a `Dict` of agents threaded through the system.

- **Async I/O**: `Future`-based dispatch to IO executors becomes `Task`-based effects in Roc. The platform would provide the IO scheduling.

- **Bloom filter**: Guava's `BloomFilter` would need a Roc-native implementation or FFI binding. The concept (probabilistic set for read avoidance) is straightforward.

- **Streaming enumeration**: `Source[QuineId, NotUsed]` for `enumerateJournalNodeIds()` / `enumerateSnapshotNodeIds()` would need a Roc streaming abstraction (possibly a lazy list or iterator protocol).

- **Multipart snapshots**: Cassandra's blob size limitations require splitting. A Roc port might use a different strategy depending on the chosen backend (e.g., RocksDB has no such limitation).

- **Serialization format**: FlatBuffers provides zero-copy deserialization on the JVM. For Roc, options include:
  - A purpose-built binary format (likely simplest)
  - FlatBuffers via C FFI (complex but compatible)
  - Roc's own serialization capabilities if they exist

### Open Questions

1. **Which storage backend for the Roc port?** RocksDB via C FFI is the most capable option but requires FFI. A pure-Roc embedded storage engine (B-tree or LSM) would be more portable but a significant undertaking. The user mentioned wanting to extend persistence -- understanding their use case would inform this decision.

2. **Should the persistence interface use Roc abilities?** The persistence operations are a natural fit for Roc's ability system. The question is whether the platform provides the IO capability or whether it's injected as a parameter.

3. **How to handle the mutable namespace registry?** `PrimePersistor.persistors` is a `var Map`. In Roc, this state would need to be managed through the platform or through explicit state threading.

4. **Is the dual journal system (NodeChangeEvents + DomainIndexEvents) necessary?** These are currently separate tables because DomainIndexEvents are not data mutations but subscription bookkeeping. A unified journal might simplify the interface, or the separation might be valuable for query performance.

5. **Should Cassandra/distributed backends be supported initially?** The Cassandra backend adds significant complexity (multipart snapshots, chunking, async statement preparation). Starting with an embedded backend (RocksDB or pure-Roc) and adding distributed backends later might be practical.

6. **What serialization format to use?** FlatBuffers provides zero-copy reads but requires schema files and code generation. A simpler format (e.g., hand-written binary encoding, or a Roc serialization library) might be more maintainable.

7. **How to handle the `EventEffectOrder` duality?** Both orderings are used in production. The Roc port needs to decide whether to support both (more complex) or pick one (simpler but less flexible). PersistorFirst is the default and the safer choice.

8. **Can the bloom filter be integrated more tightly with the storage engine?** RocksDB has built-in bloom filters. A Roc-native storage engine could integrate this at a lower level than the current wrapper pattern.

9. **What is the migration story?** If the Roc port needs to read data persisted by the Scala version, the FlatBuffers serialization format must be preserved exactly. If not, a clean break on serialization format is preferable.

10. **How should the persistence layer interact with Roc's memory model?** The current system relies heavily on `Array[Byte]` as the interchange format between persistence and the node model. Roc's `List U8` is semantically similar but may have different performance characteristics for large blobs.
