# System Overview

## What Quine Is

Quine is a streaming graph database that turns event streams into a live, queryable graph and continuously monitors it for patterns. Data arrives through ingest pipelines (Kafka, Kinesis, files, etc.), gets written to a property graph as nodes with key-value properties and half-edges, and persists through an event-sourced journal-plus-snapshot system. Standing queries -- Quine's defining feature -- register graph patterns once and then incrementally re-evaluate as the graph changes, emitting results to external systems the moment a match occurs.

The Scala codebase is approximately 113,000 lines across 19 SBT modules, built on Apache Pekko (actors and streams), Cats, Circe, and a pluggable persistence layer supporting RocksDB, MapDB, and Cassandra.

## Architecture Through the Data Lifecycle

The following diagram traces data from external sources through to standing query outputs, showing each stage and how they connect.

```
                              EXTERNAL DATA SOURCES
                     (Kafka, Kinesis, SQS, S3, files, SSE, ...)
                                      |
                                      v
                      +-------------------------------+
                      |        INGEST PIPELINES       |
                      | source -> decompress -> frame |
                      | -> decode -> Cypher query     |
                      +-------------------------------+
                                      |
                          parameterized Cypher mutations
                                      |
                                      v
                +-----------------------------------------+
                |            QUERY LANGUAGES              |
                |  Cypher parser -> AST -> Query IR ->    |
                |  interpreter (on-node or external)      |
                |  Gremlin parser -> traversal steps      |
                +-----------------------------------------+
                          |                     ^
           node mutations |                     | query results
                          v                     |
          +-------------------------------------|-------+
          |          GRAPH STRUCTURE (shards)           |
          |  GraphService -> N shards -> M nodes each  |
          |  relayTell / relayAsk message routing       |
          |  LRU sleep/wake for memory management       |
          +--------------------------------------------+
                  |                |              |
                  v                v              v
    +----------------+  +------------------+  +--------------------+
    |  GRAPH NODES   |  |   PERSISTENCE    |  |  STANDING QUERIES  |
    | QuineId, props |  | journals (events)|  | per-node pattern   |
    | half-edges,    |  | snapshots (state)|  | states; incremental|
    | event-sourced  |  | RocksDB/MapDB/   |  | re-eval on change; |
    | state changes  |  | Cassandra        |  | cross-edge subscr. |
    +----------------+  +------------------+  +--------------------+
                                                       |
                                           match / cancellation
                                                       |
                                                       v
                              +-------------------------------+
                              |       OUTPUT PIPELINES        |
                              | filter -> enrich -> serialize |
                              | -> deliver (Kafka, HTTP, ...) |
                              +-------------------------------+
                                              |
                                              v
                                   EXTERNAL DESTINATIONS
                           (Kafka, Kinesis, SNS, HTTP, file, ...)
                                              |
                              +-------------------------------+
                              |     REST API / APP SHELL      |
                              | endpoint groups (admin, ingest|
                              | standing queries, Cypher,     |
                              | debug, algorithms, UI config) |
                              | config, startup, shutdown     |
                              +-------------------------------+
```

**How the stages connect:**

1. **Ingest** receives raw bytes, frames and decodes them, then executes a parameterized Cypher query per record.
2. **Query Languages** parse Cypher (or Gremlin) into a Query IR and interpret it. Mutations flow down to nodes; read results flow up.
3. **Graph Structure** routes messages to the correct shard and node. Nodes that are asleep are transparently woken from persistence.
4. **Graph Nodes** are the atom of the system: each holds properties, half-edges, and standing query subscription state. State changes are expressed as events (PropertySet, EdgeAdded, etc.).
5. **Persistence** durably stores event journals and periodic snapshots. On wake-up, a node is reconstructed from its latest snapshot plus journal replay.
6. **Standing Queries** maintain per-node state for each registered pattern. When a node change matches a watched event, only the affected query part is re-evaluated. Results propagate across edges via subscription messages and ultimately reach a global result queue.
7. **Outputs** consume standing query results, optionally enrich them with a Cypher query, serialize, and deliver to external destinations.
8. **REST API / App Shell** exposes all of the above over HTTP, manages application state (ingest streams, standing queries, UI config), and orchestrates startup/shutdown.

## Cross-Cutting Infrastructure

Several concerns span every stage:

- **Serialization**: Five formats serve distinct roles -- FlatBuffers for persistence, MessagePack for property values, Protobuf and Avro for external data, JSON/Circe for the API layer.
- **Metrics**: Dropwizard Metrics instruments persistence latency, node sleep/wake, ingest throughput, standing query result rates, and messaging volumes.
- **Logging**: A safe-logging framework with a `Loggable` type class provides redaction-aware structured logging.
- **Error handling**: A structured `BaseError` hierarchy classifies errors as `QuineError` (internal), `ExternalError`, or `GenericError`.
- **Configuration**: PureConfig loads HOCON into a typed `QuineConfig` record covering persistence backend, node limits, web server, ID scheme, and more.

---

## Dependency Map

### Scala Codebase Dependencies (Actual)

The arrows below read as "depends on" (A -> B means A calls into B).

```
App Shell -> REST API -> Graph Structure (query execution, SQ lifecycle, ingest wiring)
REST API -> Query Languages (Cypher compilation)
REST API -> Ingest (stream creation)
REST API -> Outputs (output attachment)

Ingest -> Query Languages (Cypher execution per record)
Ingest -> Graph Structure (graph mutations via CypherOpsGraph)

Outputs -> Query Languages (enrichment queries)
Outputs -> Standing Queries (result source)
Outputs -> Graph Structure (via CypherOpsGraph)

Standing Queries -> Graph Nodes (per-node state, event dispatch)
Standing Queries -> Persistence (SQ state persistence, DomainGraphNode storage)
Standing Queries -> Graph Structure (cross-node subscription messages via relayTell)
Standing Queries -> Query Languages (FilterMap evaluates Cypher expressions)

Graph Structure -> Graph Nodes (creates/manages node actors)
Graph Structure -> Persistence (node wake-up reads, sleep writes)
Graph Structure -> Standing Queries (SQ registration, propagation, result distribution)

Graph Nodes -> Persistence (journal writes, snapshot writes)
Graph Nodes -> Standing Queries (event dispatch to SQ states, subscription messages)

Persistence -> (external storage backends: RocksDB, MapDB, Cassandra)

Query Languages -> Graph Nodes (on-node Cypher execution via CypherBehavior)
Query Languages -> Graph Structure (entry point scans, node enumeration)
```

### Dependencies Not Anticipated in the SPEC

The analysis revealed several dependency relationships not called out in the SPEC's preliminary ordering:

1. **Standing Queries depend on Query Languages**: The `FilterMap` MVSQ state evaluates Cypher `Expr` nodes at runtime. This means the Cypher expression evaluator (at minimum) must exist before standing queries can be fully functional. However, a subset of standing queries (property-only patterns without FilterMap) can work without it.

2. **Outputs depend on Query Languages**: The `CypherQuery` enrichment output executes a full Cypher query per result. This is not just a dependency on the graph but on the compiled Cypher engine.

3. **Standing Queries have a bidirectional dependency with Graph Nodes**: Node state includes standing query subscription state, and standing query states are mutated inside the node actor. These two stages are tightly coupled and must be co-designed.

4. **Ingest depends on Query Languages directly**: Each ingested record is processed by executing a compiled Cypher query. Ingest cannot function without at least a basic Cypher engine.

5. **Graph Structure depends on Standing Queries**: `StandingQueryOpsGraph` is a trait mixed into `GraphService`. The graph structure must be aware of standing queries for registration, propagation, and result distribution. This creates a circular dependency between graph structure and standing queries at the trait level, though the runtime dependency flows primarily downward.

### Roc Build Dependencies

For the Roc port, the build-order dependencies are:

```
Graph Node Model          (foundation -- no dependencies)
    |
    v
Persistence Interfaces    (depends on: node model types)
    |
    v
Graph Structure           (depends on: node model, persistence)
    |
    v
Standing Queries          (depends on: node model, persistence, graph structure,
    |                      partial query language support for Expr evaluation)
    v
Query Languages           (depends on: node model, graph structure)
    |
    v
Ingest & Outputs          (depends on: query languages, standing queries, graph structure)
    |
    v
API & Application Shell   (depends on: everything above)
```

The key insight is that standing queries and query languages have a partial mutual dependency. The recommended approach is to build a minimal Cypher expression evaluator as part of the standing queries phase, then build the full query language parser and compiler afterward.

---

## Recommended Roc Build Order

Based on the actual dependency analysis across all eight stages, the recommended build order is:

### Phase 1: Graph Node Model
Build the foundational types: `QuineId` (opaque byte array), `QuineValue` (15-variant tagged union), `PropertyValue` (lazy serialization wrapper), `HalfEdge`, `EdgeDirection`, `NodeChangeEvent` hierarchy, `EventTime` (bit-packed timestamp), `NodeSnapshot`, and `QuineIdProvider` (record of functions). These are pure data types with no concurrency or I/O concerns.

**Rationale**: Unchanged from SPEC. Everything else references these types.

### Phase 2: Persistence Interfaces
Define the `PersistenceAgent` interface (record of functions for journal, snapshot, standing query state, and metadata CRUD), `PersistenceConfig`, `BinaryFormat` (encode/decode pair), and key encoding functions. Implement `InMemoryPersistor` and `EmptyPersistor` for testing. Defer RocksDB (FFI) and Cassandra to a later sub-phase.

**Rationale**: Unchanged from SPEC. Persistence types are needed by graph structure (for node wake/sleep) and standing queries (for state persistence). The user's stated interest in extending persistence makes this an early priority.

### Phase 3: Graph Structure and Concurrency
Build the shard-based node management system: `GraphService` (or equivalent), shard routing (`QuineId -> shard index`), node lifecycle (sleep/wake state machine), in-memory node limits (soft/hard LRU), message routing (`relayTell`/`relayAsk`), and namespace support. This is where the Pekko actor replacement design is realized -- likely per-node Tasks with channels, managed by per-shard event loops.

**Rationale**: Unchanged from SPEC. This is the largest architectural challenge and must be settled before standing queries (which rely on cross-node messaging) and query languages (which rely on on-node execution).

### Phase 4: Standing Queries (with minimal expression evaluator)
Build the `MultipleValuesStandingQuery` AST, per-node `MultipleValuesStandingQueryState` state machines, the `StandingQueryWatchableEventIndex` for efficient event dispatch, cross-edge subscription protocol, result diffing, and backpressure signaling. Include a minimal Cypher `Expr` evaluator (property access, comparisons, boolean logic, `id()`, `labels()`) to support `FilterMap` states.

**Change from SPEC**: The SPEC listed standing queries before query languages, which is correct. The refinement is that a minimal expression evaluator must be built here rather than waiting for the full query language phase. The DomainGraphBranch (v1) system can be deferred or dropped in favor of MVSQ only.

### Phase 5: Query Languages
Build the Cypher parser (hand-rolled recursive descent from the `Cypher.g4` grammar), the `Query` IR (~25 variants), the Cypher compiler (AST to Query IR), and the interpreter. The Gremlin parser is lower priority and can be deferred.

**Change from SPEC**: The SPEC listed this as a single phase. The analysis confirms it is feasible as one phase because the parser and compiler are largely self-contained. The key insight is that the standing query pattern compiler (`StandingQueryPatterns.compile`) also lives here and must produce `MultipleValuesStandingQuery` ASTs from restricted Cypher MATCH-RETURN patterns.

### Phase 6: Ingest and Outputs
Build the ingest pipeline (source abstraction, framing, decoding, Cypher execution per record, lifecycle control), the output pipeline (filter, enrich, serialize, deliver to destinations), and the recipe system. Use the V2 architecture as the sole model. External source/destination connectors (Kafka via librdkafka FFI, AWS via C SDK FFI, file via platform I/O) are sub-phases.

**Rationale**: Unchanged from SPEC. These depend on query languages for Cypher execution and standing queries for result sourcing.

### Phase 7: API and Application Shell
Build the REST API (seven endpoint groups), the HTTP server, startup/shutdown orchestration, configuration loading, state persistence (metadata key-value store), and the recipe interpreter. Decompose the Scala `QuineApp` God Object into separate manager modules.

**Rationale**: Unchanged from SPEC. This is the outermost layer and depends on everything else.

### Cross-Cutting (Built Incrementally)
The following are built as needed across all phases rather than as a separate phase:
- **Serialization**: MessagePack (Phase 1), persistence codecs (Phase 2), JSON (Phase 7), Protobuf/Avro (Phase 6)
- **Metrics**: Counter/timer/histogram primitives (Phase 3), instrumentation per phase
- **Logging**: Structured logger with safe/unsafe distinction (Phase 1 onward)
- **Error handling**: Tagged union error types, built per phase
- **Configuration**: TOML or JSON config reader (Phase 7, with earlier phases using simple records)
