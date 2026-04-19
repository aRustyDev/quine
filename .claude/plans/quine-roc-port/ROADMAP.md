# Roadmap

## Phase 0: Codebase Analysis
- [x] Stage 1: Graph Node Model analysis
- [x] Stage 2: Graph Structure & Concurrency analysis
- [x] Stage 3: Persistence analysis
- [x] Stage 4: Standing Queries analysis
- [x] Stage 5: Query Languages analysis
- [x] Stage 6: Ingest & Outputs analysis
- [x] Stage 7: API & Application Shell analysis
- [x] Stage 8: Cross-Cutting Concerns analysis
- [x] Stage 9: Synthesis — overview, dependency map, build order finalization

## Phase 1-7: Roc Implementation (per-layer cycle)
For each layer: read analysis → design Roc equivalent → build with tests → retrospective

- [x] Phase 1: Graph Node Model — foundational types (QuineId, QuineValue, HalfEdge, NodeChangeEvent, EventTime, NodeSnapshot, QuineIdProvider)
- [x] Phase 2: Persistence Interfaces — PersistenceAgent interface, PersistenceConfig, BinaryFormat, InMemoryPersistor; defer RocksDB FFI and Cassandra
- [ ] Phase 3: Graph Structure & Concurrency — shard routing, node lifecycle (sleep/wake), in-memory limits (LRU), message routing (relayTell/relayAsk), namespace support; **Phase 3b (Roc graph layer) complete**; Phase 3a (custom Roc platform) pending; shard-managed event loops (ADR-016); custom Roc platform (ADR-017)
- [ ] Phase 4: Standing Queries (with minimal Cypher expression evaluator) — MVSQ AST, per-node state machines, WatchableEventIndex, cross-edge subscriptions, result diffing, backpressure; DGB/v1 system deferred
- [ ] Phase 5: Query Languages — Cypher parser (recursive descent), Query IR, compiler, interpreter, standing query pattern compiler; Gremlin deferred
- [ ] Phase 6: Ingest & Outputs — V2 architecture only; source abstraction, framing, decoding, Cypher execution per record; output filter/enrich/serialize/deliver; recipe system; external connectors (Kafka, AWS) as sub-phases
- [ ] Phase 7: API & Application Shell — REST API (7 endpoint groups), HTTP server, config loading, startup/shutdown, state persistence; decompose QuineApp into separate modules

## Cross-Cutting (built incrementally across all phases)
- Serialization: MessagePack (Phase 1), persistence codecs (Phase 2), JSON (Phase 7), Protobuf/Avro (Phase 6)
- Metrics: counter/timer/histogram primitives (Phase 3), per-phase instrumentation
- Logging: structured logger with safe/unsafe distinction (Phase 1 onward)
- Error handling: tagged union error types, per phase
- Configuration: TOML or JSON config reader (Phase 7, earlier phases use simple records)

## Key Complexities (see [docs/src/complexities/README.md](docs/src/complexities/README.md))
1. Concurrency model: Pekko actor replacement (Phase 3)
2. Persistence abstraction: pluggable backends via FFI (Phase 2)
3. Incremental computation: standing query propagation (Phase 4)
4. Parser infrastructure: Cypher recursive descent parser (Phase 5)
5. Streaming pipelines: Tasks + bounded channels (Phase 6)
6. Type class patterns: explicit functions replace Scala implicits (all phases)
