# Product Requirements

## Product
Quine-Roc: A streaming graph interpreter written in Roc, providing feature parity with the original Scala-based Quine.

## Target User
Developer (self) — learning Roc and functional programming through a meaningful systems project.

## Core Requirements
1. Graph data model with nodes, properties, edges, and unique addressing
2. Pluggable persistence with at least one storage backend
3. Standing queries that propagate incrementally through the graph
4. Cypher query language support (Gremlin as stretch goal)
5. Ingest from at least: files, stdin, and one streaming source
6. REST API for graph operations and management
7. Output actions triggered by standing query matches

## Non-Requirements (Explicit Exclusions)
- Exact API compatibility with Scala Quine
- JVM interop
- All three persistence backends simultaneously (start with one)
- Web UI (separate track, likely TypeScript)
- Scala-style actor system (find Roc-idiomatic concurrency)

## Success Criteria
- Feature parity with Quine's core capabilities
- Idiomatic Roc code (not a mechanical Scala translation)
- Extensible persistence layer (user's primary interest area)
- Deepened understanding of FP concepts through the implementation
