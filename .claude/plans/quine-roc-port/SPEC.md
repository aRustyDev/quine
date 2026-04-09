# Quine-to-Roc Port: Codebase Analysis Specification

## Purpose

Produce a comprehensive analysis of the Quine Scala codebase that enables layer-by-layer porting to Roc. The analysis serves as a living reference document — a map of the territory — that informs Roc design decisions at each build layer without prescribing them prematurely.

## Goals

- Understand what Quine does at each stage of its data lifecycle
- Identify which complexity is essential (business logic, algorithms, data structures) vs. incidental (JVM/Scala/actor framework scaffolding)
- Surface Scala→Roc translation concerns and open questions per stage
- Catalog external library dependencies and flag FFI vs. build-from-scratch decision points
- Produce a build order for the Roc port grounded in actual dependency relationships

## Non-Goals

- Designing the Roc architecture (happens during each build layer)
- Specifying Roc types or function signatures (premature)
- Making final FFI vs. pure-Roc decisions (flags decision points only)
- Analyzing test code, documentation generation, Docker/CI, or the Scala.js web UI

## Source Codebase

- **Language:** Scala 2.13.18 on JVM
- **Size:** ~113k lines of production code, ~700 source files, 19 SBT subprojects
- **Key frameworks:** Apache Pekko (actors), Cats/Cats Effect (FP), Circe (JSON), Tapir (HTTP APIs), ANTLR4 (parsing)

## Analysis Method

### Approach: "Follow the Data"

Trace the lifecycle of data through Quine end-to-end, starting at the graph node (the center of the system) and following data both inward (how does data arrive?) and outward (how do queries and persistence use it?).

### Per-Stage Method

Each lifecycle stage is analyzed with four steps:

**A. Trace the code.** Read key source files, identify primary types (traits, case classes, sealed hierarchies), their relationships, and main execution paths. Document what happens, not just what exists.

**B. Catalog dependencies.**
- Internal: which other stages/modules does this call into?
- External: which JVM libraries, and what specifically do they provide?
- Scala-specific idioms: implicits, type classes, HKT, macros — anything without a direct Roc equivalent

**C. Separate essential from incidental.**
- Essential complexity: the actual business logic, data structures, and algorithms. Must be ported.
- Incidental complexity: scaffolding from the JVM, Scala's type system, the actor framework, or library APIs. Should be rethought, not ported.

**D. Roc translation notes.**
- What maps naturally (pure functions, tagged unions, records)
- What needs a different approach (concurrency, mutation, IO)
- Open questions for the build phase

## Data Lifecycle Stages

### Core System (Stages 1-4)

These form a functional streaming graph with persistence and standing queries. Building only these in Roc yields a powerful tool.

#### Stage 1: Graph Node Model
What is a node? Properties, edges, half-edges. QuineId addressing. The atom everything else builds on.
- Primary code: `quine-core/src/main/scala/com/thatdot/quine/graph/` — `AbstractNodeActor`, `NodeActor`, model types
- Analysis output: `docs/src/core/graph/node/`

#### Stage 2: Graph Structure & Concurrency
How nodes organize into shards, actor-based lifecycle management (sleep/wake), inter-node messaging. Where Pekko actors dominate. Biggest Scala→Roc translation challenge.
- Primary code: `quine-core/src/main/scala/com/thatdot/quine/graph/` — `GraphShardActor`, `BaseGraph`
- Analysis output: `docs/src/core/graph/structure/`, `docs/src/core/graph/concurrency/`

#### Stage 3: Persistence
The `PrimePersistor` interface — snapshots, journals, standing query state. Pluggable backend system. Three implementations.
- Primary code: `quine-core/src/main/scala/com/thatdot/quine/persistor/`, `quine-rocksdb-persistor/`, `quine-mapdb-persistor/`, `quine-cassandra-persistor/`
- Analysis output: `docs/src/core/persistence/`

#### Stage 4: Standing Queries
Pattern registration, incremental propagation through the graph, partial match tracking per node, result→output triggering. Quine's most distinctive feature.
- Primary code: `quine-core/src/main/scala/com/thatdot/quine/graph/` standing query types, `quine-core/src/main/scala/com/thatdot/quine/model/`
- Analysis output: `docs/src/core/standing-queries/`

### Interface Layer (Stages 5-7)

How users interact with the core system. Important but separable.

#### Stage 5: Query Languages
Cypher parsing (ANTLR4 grammar → AST), compilation to graph operations, Gremlin subset.
- Primary code: `quine-language/`, `quine-cypher/`, `quine-gremlin/`
- Analysis output: `docs/src/interface/query-language/`

#### Stage 6: Ingest & Outputs
Data source connections, raw data → graph mutations pipeline. Standing query results → external actions.
- Primary code: `quine/` ingest code, `outputs2/`, recipe system
- Analysis output: `docs/src/interface/ingest/`, `docs/src/interface/outputs/`

#### Stage 7: API & Application Shell
REST API surface (V1/V2 via Tapir), app startup, configuration, wiring.
- Primary code: `quine/routes/`, `quine/v2api/`, `quine-endpoints/`, `quine-endpoints2/`, `api/`, `QuineApp.scala`
- Analysis output: `docs/src/interface/api/`, `docs/src/interface/app-shell/`

### Stage 8: Cross-Cutting Concerns
Serialization (protobuf, avro, msgpack), configuration (pureconfig), error handling patterns, metrics/logging, type class usage.
- Primary code: `quine-serialization/`, scattered across modules
- Analysis output: `docs/src/cross-cutting/`

## Analysis Execution

- Stage 1 is analyzed first (defines the core types everything references)
- Stage 2 is analyzed second (depends on Stage 1's node model)
- Stages 3-8 can be analyzed in parallel where they don't depend on each other's findings
- Each stage analysis is written to its corresponding `docs/src/` directory
- A summary with dependency map and build order is produced after all stages complete

## How the Analysis Feeds Into Building

The analysis doc is a living reference, not a stone tablet. The build cycle for each layer:

1. Read the analysis section for that stage
2. Design the Roc equivalent (types, modules, interfaces)
3. Build it with tests
4. Retrospective: update the analysis doc with insights that affect later stages

The analysis does not prescribe Roc architecture. It provides the map; each build layer plots its own route.

## Recommended Build Order (Preliminary)

Based on dependency relationships and user priorities:

1. **Graph node model** — foundation everything else sits on
2. **Persistence interfaces** — how nodes get saved/loaded (user's primary interest area for extension)
3. **Graph structure & concurrency** — the system that manages node lifecycles
4. **Standing queries** — Quine's killer feature, embedded in the graph
5. **Query languages** — Cypher/Gremlin parsing and compilation
6. **Ingest & outputs** — connecting to external data sources/sinks
7. **API & application shell** — HTTP interface and app wiring

This order will be refined as the analysis reveals actual dependency constraints.
