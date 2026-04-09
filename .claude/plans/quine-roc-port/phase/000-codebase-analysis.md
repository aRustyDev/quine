# Phase 0: Codebase Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a comprehensive "Follow the Data" analysis of the Quine Scala codebase, written to the mdbook docs structure, enabling layer-by-layer porting to Roc.

**Architecture:** Each of 8 analysis stages reads specific Scala source files, traces execution paths and data structures, and produces a structured markdown document in the plan's `docs/src/` directory. Stages 1→2 are sequential; stages 3-8 can run in parallel. A final synthesis task produces the dependency map and overview.

**Spec:** `.claude/plans/quine-roc-port/SPEC.md`

**Output root:** `.claude/plans/quine-roc-port/docs/src/`

---

## File Map

Each task produces one or more analysis documents:

| Task | Creates |
|------|---------|
| 1 | `docs/src/core/graph/node/README.md` |
| 2 | `docs/src/core/graph/structure/README.md`, `docs/src/core/graph/concurrency/README.md` |
| 3 | `docs/src/core/persistence/README.md` |
| 4 | `docs/src/core/standing-queries/README.md` |
| 5 | `docs/src/interface/query-language/README.md` |
| 6 | `docs/src/interface/ingest/README.md`, `docs/src/interface/outputs/README.md` |
| 7 | `docs/src/interface/api/README.md`, `docs/src/interface/app-shell/README.md` |
| 8 | `docs/src/cross-cutting/README.md`, `docs/src/dependencies/README.md` |
| 9 | `docs/src/overview.md`, `docs/src/complexities/README.md` |

---

## Per-Task Document Template

Every analysis document MUST follow this structure (from the SPEC per-stage method):

```markdown
# [Stage Name]

## What Happens Here
[Trace the code: primary types, relationships, execution paths. Describe behavior, not just existence.]

## Key Types and Structures
[The essential data types, traits/interfaces, sealed hierarchies. Show the type names and what they represent.]

## Dependencies

### Internal (other stages/modules)
[Which other Quine modules does this stage call into?]

### External (JVM libraries)
[Which libraries, and what specifically do they provide? Not just "Pekko" but "Pekko actors for message-passing concurrency".]

### Scala-Specific Idioms
[Implicits, type classes, HKT, macros — anything without a direct Roc equivalent.]

## Essential vs. Incidental Complexity

### Essential (must port)
[Business logic, algorithms, data structures that define what Quine does.]

### Incidental (rethink for Roc)
[Scaffolding from JVM/Scala/actor framework/library APIs.]

## Roc Translation Notes

### Maps Naturally
[Pure functions, tagged unions, records — what translates cleanly.]

### Needs Different Approach
[Concurrency, mutation, IO — what requires fundamental rethinking.]

### Open Questions
[Unresolved decisions for the build phase.]
```

---

## Task Dependencies

```
Task 1 (Graph Node Model) ─── must complete before ───▶ Task 2 (Graph Structure & Concurrency)
                          ─── must complete before ───▶ Tasks 3-8 (all reference node types)

Task 2 ─── must complete before ───▶ Task 9 (Synthesis)

Tasks 3-8 ─── can run in parallel after Task 2 ───▶ all must complete before Task 9
```

---

### Task 1: Graph Node Model Analysis

**Reads:**
- `quine-core/src/main/scala/com/thatdot/quine/graph/AbstractNodeActor.scala`
- `quine-core/src/main/scala/com/thatdot/quine/graph/NodeActor.scala`
- `quine-core/src/main/scala/com/thatdot/quine/graph/NodeChangeEvent.scala`
- `quine-core/src/main/scala/com/thatdot/quine/model/QuineId.scala`
- `quine-core/src/main/scala/com/thatdot/quine/model/QuineValue.scala`
- `quine-core/src/main/scala/com/thatdot/quine/model/PropertyValue.scala`
- `quine-core/src/main/scala/com/thatdot/quine/model/HalfEdge.scala`
- Any other files in `quine-core/src/main/scala/com/thatdot/quine/model/` that define core node data types
- Use Serena or grep to find all references to `QuineId` to understand addressing

**Creates:** `docs/src/core/graph/node/README.md`

- [ ] **Step 1: Identify all core node types**

Read the model directory and graph directory to find all types that define what a node IS — its identity (`QuineId`), its data (`PropertyValue`, `QuineValue`), its connections (`HalfEdge`, edges), and its change events (`NodeChangeEvent`).

- [ ] **Step 2: Trace node state and behavior**

Read `AbstractNodeActor.scala` and `NodeActor.scala` to understand what a node CAN DO — what messages it handles, how it mutates state, what operations are exposed. Focus on the logical behavior, not the actor mechanics.

- [ ] **Step 3: Document the node model**

Write `docs/src/core/graph/node/README.md` following the per-task document template. Key questions to answer:
- What uniquely identifies a node? How are `QuineId`s constructed?
- What data can a node hold? (properties as key-value pairs, edges, half-edges)
- What is a `HalfEdge` and why does Quine use half-edges instead of full edges?
- What are `NodeChangeEvent`s and how do they represent mutations?
- What is the node's lifecycle (created, active, sleeping, woken)?

- [ ] **Step 4: Verify completeness**

Grep for `case class` and `sealed` in the model directory to ensure no major types were missed. Check that every type referenced in the document actually exists in the codebase at the stated path.

- [ ] **Step 5: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/core/graph/node/README.md
git commit -m "analysis: Stage 1 — graph node model"
```

---

### Task 2: Graph Structure & Concurrency Analysis

**Depends on:** Task 1 (references node types documented there)

**Reads:**
- `quine-core/src/main/scala/com/thatdot/quine/graph/GraphShardActor.scala`
- `quine-core/src/main/scala/com/thatdot/quine/graph/BaseGraph.scala`
- `quine-core/src/main/scala/com/thatdot/quine/graph/StandingQueryOSS.scala`
- `quine-core/src/main/scala/com/thatdot/quine/graph/LiteralOpsGraph.scala`
- `quine-core/src/main/scala/com/thatdot/quine/graph/AlgorithmGraph.scala`
- Any traits/classes that `BaseGraph` extends or mixes in
- Grep for `ActorRef`, `Props`, `Receive` to map the actor topology

**Creates:** `docs/src/core/graph/structure/README.md`, `docs/src/core/graph/concurrency/README.md`

- [ ] **Step 1: Map the actor hierarchy**

Read `GraphShardActor.scala` and `BaseGraph.scala` to understand the topology: how many shards exist, how a `QuineId` maps to a shard, how shards manage node actor lifecycles.

- [ ] **Step 2: Trace the concurrency model**

Understand how Pekko actors provide concurrency: message passing between nodes, mailbox processing, futures/promises, sleep/wake behavior (how nodes are evicted from memory and restored). Identify which concurrency guarantees Quine depends on (e.g., single-threaded access per node, at-most-once message delivery).

- [ ] **Step 3: Trace the graph trait mixins**

`BaseGraph` likely uses Scala trait composition to mix in capabilities (literal ops, algorithm support, standing queries). Read the mixin traits to understand how the graph's public API surface is assembled.

- [ ] **Step 4: Document graph structure**

Write `docs/src/core/graph/structure/README.md` following the template. Key questions:
- How is the graph organized? (shards → nodes)
- How does a `QuineId` route to the correct shard and node?
- What is the graph's public API surface? (the mixed-in traits)
- How does the graph handle node creation vs. lookup of existing nodes?

- [ ] **Step 5: Document concurrency model**

Write `docs/src/core/graph/concurrency/README.md` following the template. Key questions:
- What concurrency guarantees does Quine depend on?
- How do nodes communicate (message types, async patterns)?
- What is the sleep/wake lifecycle and why does it exist?
- What is essential about the concurrency model vs. what is Pekko-specific?
- What Roc concurrency primitives could replace the actor model?

- [ ] **Step 6: Verify completeness**

Check that all traits mixed into `BaseGraph` are accounted for. Grep for `extends BaseGraph` or `with BaseGraph` to find the concrete graph implementation.

- [ ] **Step 7: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/core/graph/structure/README.md
git add .claude/plans/quine-roc-port/docs/src/core/graph/concurrency/README.md
git commit -m "analysis: Stage 2 — graph structure and concurrency"
```

---

### Task 3: Persistence Analysis

**Depends on:** Task 1 (references node types and events)

**Reads:**
- `quine-core/src/main/scala/com/thatdot/quine/persistor/PrimePersistor.scala`
- All other files in `quine-core/src/main/scala/com/thatdot/quine/persistor/`
- `quine-rocksdb-persistor/src/main/scala/` — all files
- `quine-mapdb-persistor/src/main/scala/` — all files
- `quine-cassandra-persistor/src/main/scala/` — all files
- Grep for `PrimePersistor` to find all implementations and usages

**Creates:** `docs/src/core/persistence/README.md`

- [ ] **Step 1: Analyze the persistence interface**

Read `PrimePersistor.scala` and related files to understand the abstract persistence API: what methods exist, what gets persisted (snapshots, journals/events, standing query state, metadata), what the serialization format is.

- [ ] **Step 2: Analyze persistence implementations**

Read the three persistor implementations (RocksDB, MapDB, Cassandra). For each: how do they map the abstract API to their storage model? What are the key-value schemas? How is data serialized/deserialized?

- [ ] **Step 3: Trace how persistence is used by the graph**

Grep for where the graph calls into the persistor — when are snapshots taken? When are journals written? How is state restored on node wake-up? What is the snapshot-vs-journal tradeoff?

- [ ] **Step 4: Document persistence**

Write `docs/src/core/persistence/README.md` following the template. Key questions:
- What is the `PrimePersistor` interface? (every method, what it stores/retrieves)
- What data gets persisted and in what format?
- How do snapshots and journals/event-sourcing work together?
- What are the differences between the three backends? (capabilities, tradeoffs)
- Which external libraries are used and what do they provide?
- What would a Roc persistence interface look like? (FFI for RocksDB? Pure Roc storage engine?)

- [ ] **Step 5: Verify completeness**

Confirm all persistor implementations are covered. Check that every method on `PrimePersistor` is documented.

- [ ] **Step 6: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/core/persistence/README.md
git commit -m "analysis: Stage 3 — persistence"
```

---

### Task 4: Standing Queries Analysis

**Depends on:** Task 1 (references node types), Task 2 (references graph structure)

**Reads:**
- `quine-core/src/main/scala/com/thatdot/quine/graph/StandingQueryOSS.scala`
- All files matching `*StandingQuery*` or `*Standing*` in `quine-core/src/main/scala/`
- `quine-core/src/main/scala/com/thatdot/quine/model/` — standing query model types
- Grep for `StandingQuery`, `StandingQueryResult`, `StandingQueryPattern` across the codebase
- Look for the standing query propagation/matching logic within node actors

**Creates:** `docs/src/core/standing-queries/README.md`

- [ ] **Step 1: Identify standing query types and model**

Find all types that define what a standing query IS — the pattern definition, the match result, the partial state stored per node.

- [ ] **Step 2: Trace registration and propagation**

How is a standing query registered? How does it propagate to nodes? When a node's state changes, how is the standing query re-evaluated? How are partial matches tracked and combined across multiple nodes?

- [ ] **Step 3: Trace result handling**

When a standing query matches, what happens? How are results collected and routed to outputs? What is the connection between standing query results and the output system?

- [ ] **Step 4: Document standing queries**

Write `docs/src/core/standing-queries/README.md` following the template. Key questions:
- What types of patterns can standing queries match? (subgraph patterns, property conditions, etc.)
- How does incremental evaluation work? (this is the core algorithm)
- What state does each node hold for each active standing query?
- How are results delivered to consumers?
- What is essential (the incremental pattern-matching algorithm) vs. incidental (actor message routing)?

- [ ] **Step 5: Verify completeness**

Grep for all standing query related types to ensure none were missed. Verify the propagation path is fully traced from registration through match to output.

- [ ] **Step 6: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/core/standing-queries/README.md
git commit -m "analysis: Stage 4 — standing queries"
```

---

### Task 5: Query Languages Analysis

**Depends on:** Task 1 (references node/graph types the queries operate on)

**Reads:**
- `quine-language/src/main/scala/` — all files (Cypher parser, AST types)
- `quine-language/src/main/antlr4/` or similar — ANTLR4 grammar files if they exist
- `quine-cypher/src/main/scala/` — all files (Cypher→Quine compilation)
- `quine-gremlin/src/main/scala/` — all files (Gremlin parser/interpreter)
- Grep for `CypherSession`, `compile`, `interpret` to find the query execution entry points

**Creates:** `docs/src/interface/query-language/README.md`

- [ ] **Step 1: Analyze the Cypher pipeline**

Trace the full path: source text → ANTLR4 parse → AST → Quine query plan → execution against the graph. Identify the AST types and the compilation steps.

- [ ] **Step 2: Analyze Gremlin support**

Read `quine-gremlin` to understand what subset of Gremlin is supported and how it's parsed/interpreted.

- [ ] **Step 3: Identify where queries touch the graph**

Find the boundary where parsed queries become graph operations — what graph API methods do compiled queries call? This connects query languages to the graph structure (Task 2).

- [ ] **Step 4: Document query languages**

Write `docs/src/interface/query-language/README.md` following the template. Key questions:
- What is the Cypher AST structure?
- How does compilation from AST to graph operations work?
- What Cypher features are supported vs. omitted?
- What Gremlin subset is supported?
- What is the ANTLR4 dependency and what would replace it in Roc? (hand-written parser? parser combinator library? FFI to a C parser generator?)
- What is essential (query semantics, graph traversal patterns) vs. incidental (ANTLR4 infrastructure, JVM-specific AST representation)?

- [ ] **Step 5: Verify completeness**

Check that both Cypher and Gremlin are covered. Verify the compilation pipeline is traced end-to-end.

- [ ] **Step 6: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/interface/query-language/README.md
git commit -m "analysis: Stage 5 — query languages"
```

---

### Task 6: Ingest & Outputs Analysis

**Depends on:** Task 1 (references node types for graph mutations)

**Reads:**
- `quine/src/main/scala/com/thatdot/quine/app/` — ingest-related files (grep for `Ingest`, `Source`, `Stream`)
- `outputs2/src/main/scala/` — all files
- `quine/src/main/scala/com/thatdot/quine/app/Recipe.scala`
- `quine/src/main/scala/com/thatdot/quine/app/RecipeInterpreter.scala`
- Grep for `IngestStream`, `OutputHandler`, `KafkaIngest`, `KinesisIngest` to find source/sink types

**Creates:** `docs/src/interface/ingest/README.md`, `docs/src/interface/outputs/README.md`

- [ ] **Step 1: Analyze the ingest pipeline**

Trace how data enters Quine: source configuration → stream connection → raw data parsing → graph mutations (Cypher queries or direct API calls). Map all supported ingest sources.

- [ ] **Step 2: Analyze the output system**

Trace how standing query results become external actions: result → output handler → destination (Kafka, Kinesis, SNS, SQS, webhook, etc.). Map all supported output destinations.

- [ ] **Step 3: Analyze the recipe system**

Read `Recipe.scala` and `RecipeInterpreter.scala` to understand how YAML recipes wire together ingest streams, standing queries, and outputs into a complete data pipeline.

- [ ] **Step 4: Document ingest**

Write `docs/src/interface/ingest/README.md` following the template. Key questions:
- What ingest sources are supported and how are they configured?
- How does raw data become graph mutations?
- What is the streaming abstraction? (Pekko Streams? Cats Effect streams?)
- What external libraries provide the source connectors?
- What is essential (the data-to-graph-mutation pipeline) vs. incidental (Pekko Streams/connectors)?

- [ ] **Step 5: Document outputs**

Write `docs/src/interface/outputs/README.md` following the template. Key questions:
- What output destinations are supported?
- How do standing query results get routed to outputs?
- What is the recipe system and how does it compose ingest + queries + outputs?
- What external libraries provide the sink connectors?

- [ ] **Step 6: Verify completeness**

Confirm all ingest sources and output destinations mentioned in the codebase are documented.

- [ ] **Step 7: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/interface/ingest/README.md
git add .claude/plans/quine-roc-port/docs/src/interface/outputs/README.md
git commit -m "analysis: Stage 6 — ingest and outputs"
```

---

### Task 7: API & Application Shell Analysis

**Depends on:** Task 1 (references core types exposed via API)

**Reads:**
- `quine/src/main/scala/com/thatdot/quine/app/QuineApp.scala`
- `quine/src/main/scala/com/thatdot/quine/app/Main.scala`
- `quine/src/main/scala/com/thatdot/quine/app/BaseApp.scala`
- `quine/src/main/scala/com/thatdot/quine/app/routes/` — all files
- `quine/src/main/scala/com/thatdot/quine/app/v2api/` — all files
- `quine-endpoints/src/main/scala/` — V1 API definitions
- `quine-endpoints2/src/main/scala/` — V2 API definitions
- `api/src/main/scala/` — API type definitions
- `model-converters/src/main/scala/` — model conversion between API and internal types
- `quine/src/main/scala/com/thatdot/quine/app/config/` — configuration types

**Creates:** `docs/src/interface/api/README.md`, `docs/src/interface/app-shell/README.md`

- [ ] **Step 1: Map the API surface**

Read the endpoint definitions (V1 and V2) to catalog the full REST API: what endpoints exist, what operations they support, what types they accept/return.

- [ ] **Step 2: Trace the application wiring**

Read `QuineApp.scala`, `Main.scala`, `BaseApp.scala` to understand how the application starts up: configuration loading, graph initialization, API server startup, ingest/standing-query registration.

- [ ] **Step 3: Analyze configuration**

Read the config types to understand what is configurable: persistence backend selection, network settings, graph parameters, etc.

- [ ] **Step 4: Document API**

Write `docs/src/interface/api/README.md` following the template. Key questions:
- What is the full API surface? (list endpoints by category)
- What is the V1 vs. V2 API distinction?
- How are API types defined? (Tapir, cross-compiled JVM/JS)
- What is the model-converters module doing?
- What is essential (the API contract) vs. incidental (Tapir/Pekko HTTP)?

- [ ] **Step 5: Document application shell**

Write `docs/src/interface/app-shell/README.md` following the template. Key questions:
- What is the startup sequence?
- How is configuration loaded and validated?
- How are components wired together? (graph + persistence + API + ingest)
- What is `QuineApp` doing at 77KB / ~2000 lines? What responsibilities does it have?

- [ ] **Step 6: Verify completeness**

Check that V1, V2, routes, and config are all covered. Verify the startup sequence is traced.

- [ ] **Step 7: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/interface/api/README.md
git add .claude/plans/quine-roc-port/docs/src/interface/app-shell/README.md
git commit -m "analysis: Stage 7 — API and application shell"
```

---

### Task 8: Cross-Cutting Concerns Analysis

**Depends on:** Task 1 (references types used across the system)

**Reads:**
- `quine-serialization/src/main/scala/` — all files
- Grep for `Codec`, `Encoder`, `Decoder` across the codebase to find serialization patterns
- Grep for `implicit` across `quine-core/` to catalog type class usage
- Grep for `Metrics`, `Counter`, `Histogram`, `Timer` to find metrics instrumentation
- Grep for `Logger`, `log.` to find logging patterns
- `data/src/main/scala/` — shared data structures
- `aws/src/main/scala/` — AWS integration utilities

**Creates:** `docs/src/cross-cutting/README.md`, `docs/src/dependencies/README.md`

- [ ] **Step 1: Analyze serialization**

Read `quine-serialization/` to understand what serialization formats are used (Protocol Buffers, Avro, MessagePack), how codecs are defined, and where serialization occurs (persistence, network, API).

- [ ] **Step 2: Catalog type class patterns**

Grep for implicit definitions and type class usage across the codebase. How are JSON codecs (Circe), schemas (Tapir), config readers (Pureconfig) derived? What patterns repeat?

- [ ] **Step 3: Analyze error handling**

Grep for `Try`, `Either`, `Future`, `IO`, exception handling patterns. How does Quine handle and propagate errors?

- [ ] **Step 4: Analyze metrics and logging**

Find the metrics infrastructure (Dropwizard Metrics) and logging setup (Logback/SLF4J). What is instrumented? How are metrics exposed?

- [ ] **Step 5: Document cross-cutting concerns**

Write `docs/src/cross-cutting/README.md` following the template. Key questions:
- What serialization formats are used where and why?
- What type class patterns pervade the codebase?
- How are errors handled and propagated?
- What is the metrics/logging strategy?
- What maps to Roc (tagged unions for errors, abilities for effects) vs. what needs rethinking?

- [ ] **Step 6: Document dependency inventory**

Write `docs/src/dependencies/README.md` — a consolidated list of all external JVM library dependencies across the entire codebase, grouped by function (actor framework, serialization, parsing, persistence, HTTP, streaming, monitoring, etc.). For each: what it does, whether Roc has an equivalent, and the FFI-vs-build-from-scratch assessment.

Source: `project/Dependencies.scala` plus findings from all previous stages.

- [ ] **Step 7: Verify completeness**

Cross-reference against `project/Dependencies.scala` to ensure no major dependency category was missed.

- [ ] **Step 8: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/cross-cutting/README.md
git add .claude/plans/quine-roc-port/docs/src/dependencies/README.md
git commit -m "analysis: Stage 8 — cross-cutting concerns and dependencies"
```

---

### Task 9: Synthesis — Overview, Dependency Map, and Build Order

**Depends on:** All previous tasks (1-8)

**Reads:**
- All analysis documents produced by Tasks 1-8
- The SPEC's preliminary build order

**Creates:** `docs/src/overview.md`, `docs/src/complexities/README.md`

- [ ] **Step 1: Write the system overview**

Write `docs/src/overview.md` — a concise (500-800 word) overview of Quine's architecture as understood through the data lifecycle analysis. This is the "if you read one document" summary. Include a text-based diagram of the data lifecycle showing how the stages connect.

- [ ] **Step 2: Build the dependency map**

In `docs/src/overview.md`, add a section showing which stages depend on which — both in the Scala codebase (actual dependencies) and for the Roc build (build order dependencies). Note any cases where the analysis revealed dependencies not anticipated in the SPEC.

- [ ] **Step 3: Document key complexities**

Write `docs/src/complexities/README.md` — a synthesis of the hardest Scala→Roc translation challenges found across all stages. Organize as:
- **Concurrency model** — actor system replacement (from Tasks 2, 4)
- **Persistence abstraction** — pluggable backends in Roc (from Task 3)
- **Incremental computation** — standing query propagation (from Task 4)
- **Parser infrastructure** — ANTLR4 replacement (from Task 5)
- **Streaming pipelines** — Pekko Streams replacement (from Task 6)
- **Type class patterns** — implicit-based derivation replacement (from Task 8)

For each, summarize the essential problem and the candidate Roc approaches.

- [ ] **Step 4: Finalize build order**

In `docs/src/overview.md`, add a final section with the recommended Roc build order, refined from the SPEC's preliminary order based on actual dependency findings. Note any changes from the original order and why.

- [ ] **Step 5: Update ROADMAP.md**

Update `.claude/plans/quine-roc-port/ROADMAP.md` to reflect any changes to the phase order discovered during analysis.

- [ ] **Step 6: Update SUMMARY.md**

Update `docs/src/SUMMARY.md` if any new documents were added beyond the original plan.

- [ ] **Step 7: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/overview.md
git add .claude/plans/quine-roc-port/docs/src/complexities/README.md
git add .claude/plans/quine-roc-port/ROADMAP.md
git add .claude/plans/quine-roc-port/docs/src/SUMMARY.md
git commit -m "analysis: Phase 0 synthesis — overview, dependency map, build order"
```
