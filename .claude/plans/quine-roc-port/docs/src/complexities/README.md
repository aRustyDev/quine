# Key Porting Complexities: Scala to Roc

This document synthesizes the hardest translation challenges identified across all eight analysis stages. Each section summarizes the essential problem and the candidate Roc approaches found in the individual stage analyses.

---

## 1. Concurrency Model -- Actor System Replacement

**Source analysis**: [Graph Structure](../core/graph/structure/README.md), [Graph Concurrency](../core/graph/concurrency/README.md)

### The Problem

Quine's entire runtime is built on Apache Pekko actors. Every graph node is an independent Pekko actor with a mailbox, sequential message processing, and lifecycle management. Every shard is an actor. The system depends on three guarantees the actor model provides:

1. **Single-threaded node access**: Each node processes exactly one message at a time. No locks are needed for property/edge mutations, standing query state updates, or query execution within a node.
2. **Transparent location**: Messages are sent to nodes by `QuineId` without knowing whether the node is awake, asleep, local, or remote. The routing layer handles wake-up transparently.
3. **Cooperative lifecycle**: Nodes can be evicted from memory (sleep) and restored from persistence (wake) through a cooperative state machine between the shard actor and the node actor.

The Pekko-specific machinery is extensive: `ActorRef`, `Props`, `StampedLock` for actor-ref liveness, custom `NodeActorMailbox` with priority (GoToSleep is low-priority), `ExactlyOnceAskNodeActor` for request-response, three dispatcher thread pools (shard, node, blocking I/O), and `AtomicReference[WakefulState]` shared between shard and node actors.

### Candidate Roc Approaches

Three options were identified in the concurrency analysis:

**Option A -- Shard-managed event loops**: Each shard is a Roc Task that owns a `Dict SpaceTimeQuineId NodeState` and a per-node message queue. The shard round-robins through nodes with pending messages, processing one at a time. Simple and low overhead, but a long-running message on one node blocks all other nodes in that shard.

**Option B -- Per-node Tasks with channels** (recommended): Each awake node is a Roc Task with an input channel. The shard creates the Task on wake-up and closes the channel on sleep. This preserves the essential semantics (sequential per-node processing, async message passing, transparent wake-on-message) most faithfully. The concern is whether Roc's platform supports 50,000+ lightweight tasks efficiently.

**Option C -- Shared thread pool with per-node locks**: Node "messages" become function calls protected by per-node mutexes. No task/actor overhead, but callers block waiting for locks and the asynchronous message-passing model is lost.

**Key decision point**: This must be resolved before Phase 3 (Graph Structure). The choice ripples through standing queries (cross-node subscription messages), query languages (on-node execution), and ingest (write parallelism). Early prototyping of Option B with Roc's Task system is recommended.

**Additional considerations**:
- The sleep/wake lifecycle becomes a cache eviction problem: node state lives in a bounded LRU cache, evicted nodes are persisted, and incoming messages for evicted nodes trigger restoration.
- The `StampedLock` and `ExactlyOnceAskNodeActor` patterns disappear entirely if the Roc platform provides safe channel handles (writing to a closed channel is a no-op or returns an error rather than crashing).
- The three-dispatcher architecture (shard, node, blocking) maps to Roc's platform-managed threading, but I/O isolation (persistence reads/writes must not block compute) still matters.

---

## 2. Persistence Abstraction -- Pluggable Backends in Roc

**Source analysis**: [Persistence](../core/persistence/README.md)

### The Problem

Quine's persistence layer is a two-tier pluggable system: `PrimePersistor` manages global data and acts as a factory for per-namespace `NamespacedPersistenceAgent` instances. The agent interface defines 20+ methods across seven data categories (node change journals, domain index journals, snapshots, standing queries, standing query states, metadata, domain graph nodes). Three production backends exist: RocksDB (embedded, via JNI), MapDB (embedded, pure Java), and Cassandra (distributed, via DataStax driver).

The challenges for Roc:

1. **Backend pluggability**: The Scala codebase uses class inheritance and abstract type members (`type PersistenceAgentType <: NamespacedPersistenceAgent`) for backend polymorphism. Roc has no class hierarchy.
2. **FFI complexity**: RocksDB has a C API (good FFI target), but MapDB is Java-only (no FFI path), and the Cassandra driver is a complex Java library with connection pooling, prepared statements, and async queries. The C Cassandra driver (`cpp-driver`) is an alternative but requires careful memory management.
3. **Serialization format**: All persistent data uses FlatBuffers with LZ4-style packing. FlatBuffers has no Roc code generator, meaning either FFI to the C FlatBuffers library, a hand-rolled binary format reader/writer, or a format change with a migration tool.
4. **Async I/O model**: All persistence methods return `Future[T]` dispatched to a blocking I/O executor. Roc needs `Task`-based effects with I/O isolation.
5. **Decorator pattern**: `BloomFilteredPersistor` (Guava BloomFilter for read avoidance) and `ExceptionWrappingPersistenceAgent` are implemented as wrapper classes. Roc would use function composition or middleware-style wrapping.

### Candidate Roc Approaches

- **Backend as a record of functions**: The `NamespacedPersistenceAgent` interface maps naturally to a Roc record (or ability) containing all persistence operations. Backend selection becomes constructing different records.
  ```
  PersistenceAgent : {
      persistNodeChangeEvents : QuineId, List (WithTime NodeChangeEvent) -> Task {},
      getLatestSnapshot : QuineId, EventTime -> Task (Result (List U8) [NotFound]),
      ...
  }
  ```
- **RocksDB via C FFI** as the primary embedded backend. MapDB can be dropped (Java-only, no C API, known performance issues above 2GB).
- **Cassandra deferred** to a later sub-phase. The C Cassandra driver is usable but complex. Single-host deployment with RocksDB is sufficient for an initial port.
- **Serialization format**: Switch from FlatBuffers to a simpler format -- either MessagePack for everything (the spec is simple enough to implement in Roc) or a hand-written binary format. If data migration from existing Quine databases is needed, a JVM-based migration tool can read the old FlatBuffers format.
- **Bloom filter**: Implement a simple Bloom filter in Roc (the algorithm is well-documented) or use RocksDB's built-in bloom filters at the storage level.

---

## 3. Incremental Computation -- Standing Query Propagation

**Source analysis**: [Standing Queries](../core/standing-queries/README.md)

### The Problem

Standing queries are Quine's most distinctive and complex feature. The system maintains per-node mutable state for each registered pattern, incrementally re-evaluates only on relevant changes, and propagates results across edges via subscription messages. Three interlocking mechanisms must be ported:

1. **The MVSQ state machine**: Nine state types (`UnitState`, `CrossState`, `LocalPropertyState`, `LabelsState`, `LocalIdState`, `AllPropertiesState`, `SubscribeAcrossEdgeState`, `EdgeSubscriptionReciprocalState`, `FilterMapState`), each with mutable `var` fields updated within the single-threaded actor context. `CrossState` computes Cartesian products across subquery results. `SubscribeAcrossEdgeState` creates subscriptions on remote nodes when matching edges appear.

2. **Cross-edge subscription protocol**: When a node observes a matching edge, it creates an `EdgeSubscriptionReciprocal` query on the remote node. The remote node verifies the reciprocal half-edge and subscribes to the continuation subquery locally. Results flow back. Edge removal triggers cascading cancellation. This is a distributed protocol that relies on node-to-node messaging.

3. **Result diffing and delivery**: `MultipleValuesResultsReporter` tracks last-reported results per query and computes diffs (new matches, cancellations). Results flow into a bounded queue with backpressure that throttles ingest when the queue fills.

The Scala implementation uses mutable state within actors (safe because single-threaded), trait mixin for behavior (`MultipleValuesStandingQueryBehavior`), and late-initialized fields (`_query` is null until `rehydrate()`).

### Candidate Roc Approaches

- **Immutable state records with explicit threading**: Each MVSQ state type becomes an immutable Roc record. Update functions return a new state plus a list of effects:
  ```
  onNodeEvents : LocalPropertyState, List NodeChangeEvent, LookupInfo
      -> { state : LocalPropertyState, effects : List SqEffect }

  SqEffect : [
      CreateSubscription { onNode : QuineId, query : MultipleValuesStandingQuery },
      CancelSubscription { onNode : QuineId, queryId : PartId },
      ReportResults (List QueryContext),
  ]
  ```
  The node runtime executes the effects after the state update (sending messages, reporting results).

- **Per-node `Dict (StandingQueryId, PartId) SqPartState`**: All standing query state for a node lives in a single dictionary. `SqPartState` is a tagged union of all nine state types. This replaces the mutable collections scattered across `AbstractNodeActor`.

- **WatchableEventIndex as a pure data structure**: `Dict WatchableEventType (Set EventSubscriber)` with register/unregister/lookup operations. Rebuilt from the standing query states on wake-up.

- **Result diffing as a pure function**: `(oldResults, newResults, includeCancellations) -> List StandingQueryResult`. Trivially portable.

- **Backpressure via bounded channels**: Replace the `AtomicInteger` + `SharedValve` mechanism with a bounded channel for standing query results. When full, producers receive a backpressure signal that propagates to ingest sources.

- **Unify on MVSQ only**: The DomainGraphBranch (v1) system is less expressive and exists for backward compatibility. The Roc port can start with MVSQ only, significantly reducing complexity. The QuinePattern system is still evolving and can be deferred.

---

## 4. Parser Infrastructure -- ANTLR4 Replacement

**Source analysis**: [Query Languages](../interface/query-language/README.md)

### The Problem

Quine has two parallel Cypher parsing pipelines:

1. **openCypher front-end** (production): A thatdot fork of Neo4j's JavaCC-based parser (`org.opencypher.v9_0`) that produces an openCypher AST, applies 10+ rewriting phases (semantic analysis, CNF normalization, transitive closure, predicate optimization), and compiles to Quine's `Query[Location]` IR.

2. **quine-language** (in-progress): An ANTLR4-based parser using the `Cypher.g4` grammar with hand-written visitor classes, a symbol analysis phase, and a type checking phase. It produces its own AST but does not yet connect to the execution engine.

Neither pipeline is usable in Roc. The openCypher library is deeply JVM-specific (JavaCC, Java reflection, complex AST rewriting infrastructure). ANTLR4 has a C runtime, but the hand-written visitors would need rewriting. The Gremlin parser uses Scala parser combinators (also JVM-specific).

The `Query` IR itself (~25 variants) and the `Expr` expression hierarchy (~60 variants) are the execution-layer types that must be preserved regardless of parser choice.

### Candidate Roc Approaches

- **Hand-rolled recursive descent parser**: Write a Cypher parser directly in Roc. The grammar is documented in `Cypher.g4` (~600 lines of ANTLR4 grammar). Recursive descent is well-suited to Cypher's structure (clauses are sequential, expressions have well-defined precedence). This gives full control and zero FFI dependencies.

- **Minimum viable subset first**: Not all Cypher syntax is needed on day one. The essential subset for Quine's core use case:
  - `MATCH` with node/edge patterns and `WHERE` filtering
  - `RETURN` / `WITH` projections
  - `CREATE` / `SET` / `DELETE` for mutations
  - `UNWIND` and `CALL` for procedures
  - Expressions: property access, comparisons, boolean logic, arithmetic, string functions, `id()`, `labels()`, `idFrom()`

  `MERGE`, `FOREACH`, `LOAD CSV`, complex path patterns, and `EXPLAIN` can come later.

- **Compilation monad becomes explicit state passing**: The Scala `CompM` (EitherT + ReaderWriterState) becomes a function taking `(ParametersIndex, SourceText, ScopeInfo)` and returning `Result CompileError (ScopeInfo, Query)`.

- **Location phantom types**: `Query[+Start <: Location]` uses JVM subtyping. In Roc, either use two separate types (`OnNodeQuery` and `AnywhereQuery`) with explicit conversions, or a single `Query` type with a runtime tag.

- **Standing query pattern compiler as a separate entry point**: `StandingQueryPatterns.compile` parses a restricted Cypher subset (single MATCH-RETURN) into `MultipleValuesStandingQuery` ASTs. This should be a separate, simpler parser path that validates the restrictions before compilation.

- **Gremlin deferred or dropped**: Gremlin support is a limited compatibility layer. The grammar is simple enough for a recursive descent parser if needed, but it is low priority.

---

## 5. Streaming Pipelines -- Pekko Streams Replacement

**Source analysis**: [Ingest](../interface/ingest/README.md), [Outputs](../interface/outputs/README.md)

### The Problem

Both ingest and output pipelines are built on Pekko Streams, which provides:

1. **Backpressured data flow**: Sources produce data at the rate consumers can handle. When an output destination is slow, standing query result production slows, which slows ingest.
2. **Lifecycle management**: `KillSwitch` for stopping streams, `Valve` for pause/resume, `RestartSource` for automatic restart with exponential backoff.
3. **Materialized values**: Pekko Streams compose operators and produce "materialized values" (handles like `KillSwitch`, `Future[Done]`, `Consumer.Control`) that represent the running stream's control plane.
4. **Fan-out**: `BroadcastHub` distributes standing query results to multiple output sinks.
5. **Connector libraries**: Alpakka (pekko-connectors) provides pre-built connectors for Kafka, Kinesis, S3, SQS, and other services.

The ingest pipeline has 12 source types (Kafka, Kinesis, KCL, SQS, SSE, WebSocket, File, S3, stdin, number iterator, reactive stream, WebSocket file upload) and 5 data formats (JSON, Protobuf, Avro, CSV, raw). The output pipeline has 10 destination types with JSON and Protobuf encoding.

Roc has no equivalent streaming framework, and the connector libraries (Alpakka) are entirely JVM-specific.

### Candidate Roc Approaches

- **Tasks with bounded channels**: Replace Pekko Streams with explicit Roc Tasks connected by bounded channels. A producer Task reads from a source and writes decoded records into a channel. A consumer Task reads from the channel and executes graph mutations. Channel capacity provides backpressure. This is simpler than Pekko Streams but requires manual composition.

- **Pipeline as function composition**: The ingest pipeline (source -> decompress -> frame -> decode -> transform -> query) can be modeled as a chain of functions that each transform a stream element, composed via `|>`. Each step is a `Task` that pulls from an input channel and pushes to an output channel.

- **Lifecycle control as a state machine**: Replace `KillSwitch` + `Valve` + `RestartSource` with a per-stream state machine:
  ```
  StreamState : [Running, Paused, Stopping, Stopped, Restarting { attempt : U32 }]
  ```
  The stream Task checks this state between elements and acts accordingly.

- **External connectors via FFI**: Kafka via librdkafka (C), AWS services via the AWS C SDK or REST API, file I/O via platform effects. Each connector is a Roc module that produces or consumes through channels.

- **Use the V2 architecture only**: The Scala codebase has V1 and V2 ingest/output systems. The V2 architecture (clean separation of source, framing, decoding, and graph writing) is the right model for the Roc port.

- **Dead letter queues as output destinations**: Failed records are routed to a configurable DLQ destination. This is straightforward with the channel model -- a catch block routes errors to a DLQ channel.

---

## 6. Type Class Patterns -- Implicit-Based Derivation Replacement

**Source analysis**: [Cross-Cutting Concerns](../cross-cutting/README.md), [Dependencies](../dependencies/README.md)

### The Problem

The Quine codebase has 269+ implicit definitions in `quine-core` alone and hundreds more across other modules. These serve several distinct purposes:

1. **JSON codec derivation** (Circe): `implicit val fooEncoder: Encoder[Foo] = deriveEncoder` generates JSON serialization at compile time via macros. Used in 30+ files for API types, configuration, and inter-module data exchange.

2. **Configuration readers** (PureConfig): `implicit val fooConvert: ConfigConvert[Foo] = deriveConvert[Foo]` generates HOCON config parsers. Used in 17 config files.

3. **API schema derivation** (Tapir/endpoints4s): Compile-time generation of OpenAPI schemas and HTTP codec instances from type definitions.

4. **Persistence codecs** (FlatBuffers): `PersistenceCodec[T]` with `BinaryFormat[T]` provides binary encode/decode. Hand-written but distributed via implicit resolution.

5. **Safe logging** (`Loggable[A]`): 74+ implicit instances that provide safe and unsafe string representations for structured logging with redaction.

6. **Data conversion bridge** (`DataFolderTo[A]` / `DataFoldableFrom[A]`): A visitor/algebra pattern for format-agnostic data transformation (Protobuf -> QuineValue, JSON -> QuineValue, Avro -> JSON, etc.).

7. **Dependency injection**: `QuineIdProvider`, `Timeout`, `ExecutionContext`, `Materializer`, `LogConfig` are threaded implicitly throughout the codebase.

Roc has no implicit resolution, no macro-based derivation, and no type class mechanism equivalent to Scala's implicits. Every implicit in the codebase must become something explicit.

### Candidate Roc Approaches

- **JSON encoding/decoding**: Roc has built-in `json` support. Each type gets explicit `toJson` and `fromJson` functions. No derivation needed -- Roc's tagged unions and records are straightforward to serialize manually.

- **Configuration**: Replace HOCON/PureConfig with TOML or JSON config. Write explicit parsers for each config record that return `Result ConfigError Config` with clear error messages for unknown or invalid keys.

- **Persistence codecs**: Write explicit `encode : T -> List U8` and `decode : List U8 -> Result T DecodeErr` functions per type. No derivation needed.

- **Safe logging via a `Loggable` ability or explicit functions**: Define `toSafeStr` and `toUnsafeStr` functions for types that appear in logs. Roc's abilities could provide a `Loggable` interface, but explicit functions per type may be simpler.

- **DataFolderTo/DataFoldableFrom as a Roc ability**: The visitor pattern maps well to Roc's ability system. `DataFolderTo` becomes an ability providing `nullValue`, `string`, `integer`, etc. `DataFoldableFrom[A]` becomes a function parameterized over that ability. This is one of the cleanest mappings.

- **Dependency injection becomes explicit parameters**: `QuineIdProvider`, `LogConfig`, etc. become explicit function parameters or fields on context records passed at the application boundary. Roc encourages this style.

- **API schemas**: If OpenAPI generation is needed, derive it from explicit endpoint definitions (records describing path, method, input/output types) via a generation function. No compile-time derivation needed.

**General principle**: Where Scala uses implicit derivation to avoid boilerplate, Roc uses explicit code. The initial boilerplate cost is higher, but the resulting code is more readable and has no invisible resolution chain to debug. For a codebase this size, the trade-off favors Roc's explicitness -- the Scala codebase's hundreds of implicits create a complex dependency web that is difficult to trace.
