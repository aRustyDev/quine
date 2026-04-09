# Dependency Inventory

## What Happens Here

This document is the consolidated inventory of ALL external JVM library dependencies used by Quine, sourced from `project/Dependencies.scala` and cross-referenced with actual usage across the codebase. Each dependency is categorized by function, assessed for Roc equivalence, and given an FFI-vs-build-from-scratch recommendation.

## Key Types and Structures

### Dependency Categories

Dependencies are grouped into functional categories below. The "Roc Strategy" column uses these codes:
- **FFI** -- wrap a C/Rust library via Roc's FFI
- **Build** -- implement from scratch in Roc
- **Roc-native** -- Roc standard library or community package covers this
- **Replace** -- use a fundamentally different approach in Roc
- **Drop** -- not needed in Roc (Scala-specific or removable)

---

## Dependency Inventory

### 1. Serialization & Data Formats

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Google FlatBuffers (`com.google.flatbuffers`) | 25.2.10 | Persistence serialization (node snapshots, events, standing queries) | 14 files in `quine-core/.../persistor/codecs/`, `PackedFlatBufferBinaryFormat` | **FFI** or **Replace** | No Roc FlatBuffer codegen. Consider switching persistence format to something Roc can handle natively (MessagePack, Cap'n Proto via FFI, or custom binary). Migration tool needed for existing data. |
| Google Protocol Buffers (`com.google.protobuf`) | 4.34.1 | Ingest/output: parsing and generating Protobuf-encoded external data | `quine-serialization/` (ProtobufSchemaCache, QuineValueToProtobuf), `data/` (DataFoldableFrom protobuf instance) | **FFI** | Use C protobuf library via FFI. `DynamicMessage`/`DynamicSchema` pattern (runtime schema resolution without compiled stubs) is the critical capability. |
| Google Protobuf Common (`com.google.protobuf:protobuf-common`) | 2.14.2 | Well-known Protobuf types (Timestamp, Duration, Date, DateTime, TimeOfDay) | `QuineValueToProtobuf.scala` -- temporal value conversion | **FFI** | Bundled with protobuf FFI |
| Apache Avro (`org.apache.avro`) | 1.12.1 | Ingest: parsing Avro-encoded external data | `quine-serialization/` (AvroSchemaCache), `data/` (DataFoldableFrom avro instance) | **FFI** | Use C Avro library via FFI. Schema resolution from URLs. |
| MessagePack (`org.msgpack`) | 0.9.11 | Property value serialization (QuineValue <-> bytes) | `quine-core/.../model/PropertyValue.scala`, `QuineValue.scala`, persistence tests | **Build** | MessagePack spec is simple enough to implement in Roc. Custom extension types (32-38) for temporal values and QuineIds need porting. |
| Circe (core, generic, generic-extras, optics, yaml) | 0.14.15 / 0.14.4 / 0.15.1 / 0.16.1 | JSON encoding/decoding throughout API, config, data exchange | 30+ files across all modules | **Roc-native** | Roc has `json` in stdlib. All implicit derivation becomes explicit encode/decode implementations. |
| uJson-Circe (`com.lihaoyi:ujson-circe`) | 3.3.1 | JSON interop between uJson and Circe ASTs | Limited bridge usage | **Drop** | Not needed when using a single JSON library |
| BooPickle (`io.suzaku:boopickle`) | 1.5.0 | Binary serialization (Scala.js compatible) | Version defined but minimal direct usage found in main sources | **Drop** | Likely used in browser module or test; assess if actually needed |
| Kafka Clients (`org.apache.kafka:kafka-clients`) | 3.9.2 | Apache Kafka producer/consumer client | `outputs2/.../Kafka.scala`, `quine/.../KafkaSource.scala`, `quine/.../KafkaOutput.scala`, SASL/JAAS config | **FFI** | Use librdkafka via FFI. Includes SASL/JAAS authentication config. LZ4 version must stay in sync. |

### 2. Actor System & Streaming

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Apache Pekko (actor, stream, cluster, etc.) | 1.4.0 | Actor system: node actors, message passing, stream processing, cluster membership | 50+ files -- the backbone of the runtime. Every node is a Pekko actor. | **Replace** | This is the largest porting challenge. Roc needs: lightweight per-node compute units (green threads or similar), message passing, backpressured streams, and cluster coordination. Consider a custom actor-like framework in Roc or platform-specific concurrency primitives. |
| Pekko HTTP | 1.3.0 | HTTP server for REST API | API route implementations | **Replace** | Use a Roc HTTP server library (e.g., `roc-http` or FFI to a C HTTP server) |
| Pekko HTTP Circe (`org.apache.pekko:pekko-http-circe`) | 3.9.1 | JSON marshalling for Pekko HTTP | API layer | **Drop** | Subsumed by Roc HTTP + JSON approach |
| Pekko Management | 1.2.1 | Cluster management and health endpoints | Cluster health checks | **Replace** | Build health endpoints directly |
| Pekko Kafka (Alpakka Kafka) | 1.1.0 | Kafka consumer/producer streams | Kafka ingest and output | **FFI** | Use librdkafka via FFI |
| Pekko Connectors | 1.3.0 | Connectors for AWS services (Kinesis, S3, SQS) | Ingest sources (Kinesis, S3, SQS) | **FFI** | Use AWS C SDK or individual service clients via FFI |

### 3. Persistence Backends

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| RocksDB JNI (`org.rocksdb:rocksdbjni`) | 10.10.1 | Local embedded key-value store for node persistence | `quine-rocksdb-persistor/` (RocksDbPersistor, RocksDbPrimePersistor) | **FFI** | RocksDB has a C API. Well-suited for FFI. Primary local persistence backend. |
| MapDB (`org.mapdb:mapdb`) | 3.1.0 | Alternative local embedded store | `quine-mapdb-persistor/` (MapDbPersistor, MapDbGlobalPersistor) | **Replace** or **Drop** | MapDB is Java-only with no C API. Consider using only RocksDB for local persistence, or find a C-compatible alternative. |
| Cassandra Java Driver (`com.datastax.oss:java-driver-*`) | 4.19.2 | Distributed persistence via Apache Cassandra | `quine-cassandra-persistor/` (20+ files) | **FFI** | Use the C Cassandra driver (`cpp-driver`) via FFI. Complex: connection pooling, prepared statements, async queries. |
| AWS Keyspaces SigV4 Auth Plugin | 4.0.9 | AWS Keyspaces (managed Cassandra) authentication | `KeyspacesPersistor.scala` | **FFI** | Bundle with Cassandra FFI + AWS auth |
| Embedded Cassandra (`com.github.nosan:embedded-cassandra`) | 5.0.3 | Test-only: embedded Cassandra for integration tests | Test sources only | **Drop** | Test infrastructure; find Roc-appropriate test strategy |

### 4. Caching

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Caffeine (`com.github.ben-manes.caffeine`) | 3.2.3 | High-performance in-memory caching | Used transitively via Scaffeine | **Build** or **FFI** | Core cache logic is lock-free Java. Consider a simpler LRU cache in Roc. |
| Scaffeine (`com.github.blemale:scaffeine`) | 5.3.0 | Scala-friendly async wrapper around Caffeine | `AvroSchemaCache`, `ProtobufSchemaCache`, `CypherOpsGraph`, `DeduplicationCache`, `MeteredExecutors` | **Build** | Implement async LRU cache in Roc. Key feature: async cache miss triggers a task. |

### 5. Query Languages

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| openCypher Frontend (`org.opencypher:*`) | 9.2.3 | Cypher query parsing (AST generation) | `quine-cypher/` compiler, 20 files | **FFI** or **Build** | The openCypher frontend is Java-only. Options: (a) FFI to a C Cypher parser, (b) write a Cypher parser in Roc, (c) use ANTLR grammar with a Roc ANTLR runtime. Complex undertaking. |
| ANTLR4 Runtime | 4.13.2 | Parser generator runtime for Cypher language server | `quine-language/` | **FFI** | ANTLR has a C runtime. Could use for Cypher parsing if keeping ANTLR grammar. |
| Parboiled | 1.4.1 | PEG parser library | Used for Gremlin query parsing | **Build** | Gremlin is deprecated/legacy; may not need porting. If needed, write a PEG parser in Roc. |
| LSP4J | 0.24.0 | Language Server Protocol implementation for IDE integration | `quine-language/` (QuineLanguageClient, LSPActor, WebSocketQuinePatternServer) | **FFI** | LSP is a JSON-RPC protocol. Could implement the protocol directly in Roc rather than depending on a library. |

### 6. Observability (Metrics & Logging)

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Dropwizard Metrics (core, JMX, etc.) | 4.2.38 | Runtime metrics: counters, timers, histograms, meters, gauges | `quine-core/.../graph/metrics/` (HostQuineMetrics, BinaryHistogramCounter), `quine/` (MetricsReporter) | **Build** | Implement counter/timer/histogram/meter primitives in Roc. Consider targeting Prometheus or OpenTelemetry exposition format directly. |
| Metrics-InfluxDB | 1.1.0 | InfluxDB metrics reporter | `MetricsReporter.scala` Influxdb case | **Build** | Simple HTTP reporter; build as part of metrics system |
| Logback | 1.5.32 | SLF4J logging backend | Runtime logging configuration | **Build** | Roc needs a structured logger. Could start with `Stderr` + structured JSON output. |
| Scala-Logging | 3.9.6 | Scala-friendly SLF4J wrapper | Imported throughout via `LazySafeLogging` / `StrictSafeLogging` | **Build** | Part of the logging infrastructure rebuild |

### 7. HTTP & API

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Tapir | 1.13.14 | v2 REST API endpoint definitions, OpenAPI spec generation | 30+ files in `api/`, `quine-endpoints/`, `quine/` | **Replace** | Use Roc HTTP framework with explicit route/schema definitions. OpenAPI generation would need a Roc library or code generator. |
| endpoints4s (default, Circe, HTTP server, OpenAPI, XHR client) | Various (1.12.1, 2.6.1, 2.0.1, 5.0.1, 5.3.0) | v1 REST API endpoint definitions | 30+ files in `quine-endpoints/`, `quine-browser/` | **Drop** | Being replaced by Tapir; do not port |
| OpenAPI Circe YAML | 0.11.10 | OpenAPI spec YAML serialization | API docs generation | **Replace** | Part of API framework replacement |
| Webjars Locator | 0.52 | Serve static web assets from JVM classpath | Web UI asset serving | **Replace** | Use standard file serving in Roc HTTP |

### 8. AWS Integration

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| AWS SDK v2 (`software.amazon.awssdk`) | 2.42.24 | Core AWS service client (S3, SQS, Kinesis, etc.) | `aws/` module (AwsOps, AwsCredentials, AwsRegion), ingest sources, Keyspaces persistor | **FFI** | Use AWS C SDK (`aws-sdk-cpp` or `aws-c-*` libraries) via FFI. Credential resolution, region selection, HTTP concurrency limits need porting. |
| Amazon Kinesis Client Library | 3.4.2 | Kinesis stream consumption with checkpointing | `KinesisKclSrc.scala` | **FFI** | KCL is Java-only. May need to use raw Kinesis API via AWS C SDK instead, implementing checkpointing manually. |
| Amazon Glue Schema Registry | 1.1.27 | AWS Glue schema registry integration for Protobuf | `ProtobufSchemaCache` (DynamicSchema from Glue) | **FFI** | Use AWS C SDK. Complex: schema registry API calls + protobuf schema parsing. |
| Netty (override) | 4.1.132.Final | Async networking (transitive via AWS SDK) | Not used directly; override for CVE fixes | **Drop** | Transitive JVM dependency; irrelevant to Roc |

### 9. Configuration

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Pureconfig | 0.17.10 | Type-safe HOCON configuration parsing | 17 files in `quine/.../config/` | **Replace** | Use TOML or JSON config in Roc. Build a type-safe config reader with validation and error messages. |
| scopt | 4.1.0 | Command-line argument parsing | `quine/.../CmdArgs.scala` | **Build** or **Roc-native** | Roc has `cli` package or build a simple arg parser |

### 10. Functional Programming

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Cats (core) | 2.13.0 | Functional abstractions (Functor, Monad, etc.), data types (Chain, NonEmptyChain, NonEmptyList, Either syntax) | 30+ files | **Build** (partial) | Port only the data structures actually used: `NonEmptyChain` (error accumulation), `Chain` (efficient append). Most type classes are unnecessary in Roc. |
| Cats Effect | 3.7.0 | Functional effect system (IO monad, Resource, etc.) | Limited direct usage; mostly through Pekko integration | **Replace** | Roc has tasks for async effects. `Resource` pattern maps to Roc's ability-based resource management. |
| Better-monad-for (compiler plugin) | 0.3.1 | Improved for-comprehension desugaring | Build-time only | **Drop** | Scala compiler plugin; no Roc equivalent needed |
| Kind-projector (compiler plugin) | 0.13.4 | Type lambda syntax sugar | Build-time only | **Drop** | Scala compiler plugin; no Roc equivalent needed |
| Shapeless | 2.3.13 | Generic programming (HList, Coproduct, Generic derivation) | 20 files (Cassandra persistor, API codecs, config) | **Drop** | Scala-specific metaprogramming. Roc uses explicit implementations. |

### 11. Security & TLS

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Ayza (`io.github.hakky54:ayza`) | 10.0.4 | TLS/SSL configuration utility | Build dependency; simplifies SSL context setup | **Replace** | Roc platform handles TLS natively or via FFI to OpenSSL/BoringSSL |

### 11b. Security (Auth & Encoding)

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| JWT (Scala) | 0.13.0 / 11.0.3 | JWT token creation and validation | `StrongUUID.scala`, likely API auth | **FFI** | Use a C JWT library (e.g., `libjwt`) via FFI |
| Apache Commons Codec | 1.21.0 | Hex encoding, Base64, and other codec utilities | Byte conversion utilities | **Build** | Hex/Base64 encoding is straightforward to implement in Roc |
| Commons Text | 1.15.0 | String manipulation utilities | Limited usage | **Build** or **Drop** | Assess specific functions used |
| Commons I/O | 2.21.0 | I/O utilities | File handling | **Roc-native** | Roc has file I/O primitives |

### 12. Data Utilities

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| LZ4 Java | 1.10.4 | LZ4 compression (kept in sync with Kafka clients) | Kafka message compression, possibly persistence packing | **FFI** | LZ4 has an excellent C library. Direct FFI. |
| Guava (`com.google.guava`) | 33.3.0-jre | Bloom filters (Funnels), general utilities | `quine-core/.../util/Funnels.scala`, BloomFilteredPersistor | **FFI** or **Build** | Guava Bloom filter is the key usage. Could use a C Bloom filter library or implement in Roc. |
| Apache Commons CSV | 1.14.1 | CSV parsing for ingest | Ingest deserialization | **Build** | CSV parsing is simple enough for Roc. |
| pprint | 0.9.6 | Pretty-printing for debugging | `GremlinValue.scala`, `GraphQueryPattern.scala` | **Build** or **Drop** | Debug utility; low priority |
| memeid4s | 0.8.0 | UUID generation (v1-v5) | QuineIdProviders (UUID-based ID schemes) | **Build** or **FFI** | UUID generation can be implemented in Roc or FFI to libuuid |
| Scala Java Time | 2.6.0 | java.time API for Scala.js | Browser module (Scala.js) | **Drop** | Scala.js-specific polyfill |
| Scala Parser Combinators | 2.4.0 | Parser combinator library | Gremlin parsing, possibly other parsers | **Build** or **Drop** | If Gremlin is not ported, not needed |
| JNR POSIX | 3.1.22 | POSIX system calls from JVM | File permission handling, system-level operations | **Roc-native** | Roc compiles to native code; POSIX calls are direct |

### 13. Web UI (Browser / Scala.js)

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| Laminar | 17.2.1 | Scala.js reactive UI framework | `quine-browser/` (entire web UI) | **Replace** | Rewrite UI in a standard web framework (React, Solid, etc.) or serve a static SPA from Roc |
| Waypoint | 10.0.0-M7 | Scala.js URL routing | Browser routing | **Replace** | Part of web UI framework replacement |
| Scala.js DOM | 2.8.1 | DOM API bindings for Scala.js | Browser module | **Replace** | Part of web UI framework replacement |
| Scala.js Macro Task Executor | 1.1.1 | Scala.js async execution | Browser module | **Drop** | Scala.js-specific |
| Vis-Network/Vis-Data/Vis-Util | 10.0.2/8.0.3/6.0.0 | Graph visualization | Browser graph explorer | **Replace** | Keep as JS dependency in a standard web frontend |
| Plotly | 2.25.2 | Charting library | Metrics dashboard | **Replace** | Keep as JS dependency in a standard web frontend |
| Bootstrap/CoreUI/CoreUI Icons/Ionicons | Various | CSS framework and icons | Browser styling | **Replace** | Keep as CSS/JS dependencies in a standard web frontend |
| React | 17.0.2 | UI component library | Browser module (via Scala.js/Laminar interop) | **Replace** | Use directly in a standard web frontend |
| jQuery | 3.6.3 | DOM manipulation | Legacy browser usage | **Drop** | Modern frameworks don't need jQuery |
| hammerjs (`@nicegraf/egjshammerjs`) | 2.0.17 | Touch gesture recognition (vis-network peer dep) | Graph visualization touch support | **Replace** | Keep as JS dependency |
| component-emitter | 2.0.0 | Event emitter (vis-network peer dep) | Graph visualization events | **Replace** | Keep as JS dependency |
| keycharm | 0.4.0 | Keyboard shortcut handler (vis-network peer dep) | Graph visualization keyboard shortcuts | **Replace** | Keep as JS dependency |
| uuid (npm) | 11.1.0 | UUID generation in browser | Browser module | **Replace** | Keep as JS dependency |
| Sugar | 2.0.6 | JavaScript date manipulation | Browser date handling | **Drop** | Use native JS Date or day.js |
| Stoplight Elements | 9.0.1 | OpenAPI documentation renderer | API docs UI | **Replace** | Keep as JS dependency in a standard web frontend |

### 14. Testing (not ported, but noted for completeness)

| Library | Version | Purpose | Roc Strategy |
|---------|---------|---------|--------------|
| ScalaTest | 3.2.20 | Test framework | Use Roc's built-in test framework |
| ScalaCheck | 1.19.0 | Property-based testing | Build or find a Roc PBT library |
| MUnit | 1.2.4 | Alternative test framework | Use Roc's built-in test framework |
| ScalaTest-ScalaCheck | 3.2.18.0 | Integration of above | N/A |
| Pekko Testkit | 1.4.0 | Actor testing utilities | Replace with Roc concurrency test patterns |

### 15. Internal / First-Party Libraries

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| quine-common (`com.thatdot:quine-common`) | 0.0.4 | Shared utilities: safe logging (`Log`), `QuineId`, `Secret`, `ByteConversions` | Used everywhere via `com.thatdot.common.logging.Log`, `com.thatdot.common.quineid.QuineId`, `com.thatdot.common.security.Secret` | **Build** | Must port: safe logging with redaction, QuineId (byte-array wrapper), Secret type. These are foundational. |

### 16. Build, DevOps & Polyglot

| Library | Version | Purpose | Codebase Usage | Roc Strategy | Notes |
|---------|---------|---------|----------------|--------------|-------|
| GraalVM (`org.graalvm.polyglot`) | 25.0.2 | Polyglot scripting engine for user-defined JavaScript transforms during ingest | `quine/.../transformation/polyglot/` (Polyglot.scala, Transformation.scala, QuineJavaScript.scala) | **FFI** | Use an embeddable JS engine (QuickJS, Duktape) via FFI. GraalVM's polyglot C API is another option but heavy. |
| Pegdown | 1.6.0 | Markdown processing for documentation generation | Doc generation tooling | **Drop** | Build-time tooling; not part of runtime |

---

## Dependencies

### Internal (other stages/modules)
- This inventory informs all other porting tasks by identifying what external capabilities must be provided
- The cross-cutting concerns document (`../cross-cutting/README.md`) provides deeper analysis of how these dependencies are used

### External (JVM libraries)
- All 80+ external dependencies are cataloged above
- Source: `project/Dependencies.scala` + grep-based usage verification

### Scala-Specific Idioms
- Many dependencies exist solely to support Scala idioms (Shapeless for generic derivation, Better-monad-for for syntax, Kind-projector for type lambdas). These are all **Drop** candidates.
- The Scala.js ecosystem (Laminar, Waypoint, Scala.js DOM) represents the browser-side codebase which should be rewritten in standard web technologies rather than ported.

## Essential vs. Incidental Complexity

### Essential (must port)
- **Persistence backends** (RocksDB, Cassandra) -- core data durability
- **Serialization formats** (FlatBuffers, MessagePack, Protobuf, Avro, JSON) -- data encoding
- **Streaming/Actor runtime** (Pekko) -- the computational backbone
- **Query language** (openCypher) -- the user-facing interface
- **AWS integration** (SDK, Kinesis, S3, SQS) -- cloud data sources
- **Metrics and logging** -- operational visibility
- **Configuration** -- application setup

### Incidental (rethink for Roc)
- **Scala type class derivation libraries** (Shapeless, Circe-generic, Pureconfig-generic) -- Roc uses explicit implementations
- **API framework specifics** (Tapir, endpoints4s) -- Roc will have its own HTTP framework patterns
- **Scala.js browser ecosystem** (Laminar, Waypoint) -- rewrite in standard web tech
- **Scala compiler plugins** (Better-monad-for, Kind-projector) -- language-level concerns
- **Java-specific utilities** (JNR POSIX, Java Time polyfills) -- Roc compiles native

## Roc Translation Notes

### Maps Naturally
- **JSON** (Circe -> Roc `json` stdlib)
- **CSV parsing** (Commons CSV -> Roc implementation)
- **Hex/Base64 encoding** (Commons Codec -> Roc implementation)
- **Command-line parsing** (scopt -> Roc arg parsing)
- **POSIX operations** (JNR POSIX -> direct system calls from Roc)
- **Configuration** (Pureconfig/HOCON -> Roc TOML/JSON config parsing)

### Needs Different Approach
- **Actor system** (Pekko -> Roc concurrency model with tasks and abilities; biggest architectural challenge)
- **Persistence** (RocksDB via FFI is straightforward; Cassandra driver via FFI is complex; MapDB may be dropped)
- **Schema-driven serialization** (Protobuf/Avro runtime schema resolution requires FFI to C libraries)
- **Metrics** (build from scratch targeting modern exposition formats)
- **Web UI** (rewrite in standard JS framework, served as static assets from Roc HTTP server)
- **Cypher parser** (either FFI to C ANTLR runtime or write a Roc parser -- significant effort either way)
- **GraalVM polyglot** (for user-defined JavaScript transforms: use QuickJS or similar embeddable JS engine via FFI)

### Open Questions
1. **Which persistence backends to support initially?** RocksDB (local) is the simplest FFI target. Cassandra (distributed) is important for production but complex. MapDB could be dropped.
2. **Is Gremlin query support needed?** It appears to be legacy. If not, Parboiled, pprint for Gremlin, and Scala Parser Combinators can all be dropped.
3. **Should the web UI be part of the Roc port?** The entire Scala.js browser module (Laminar, Waypoint, etc.) is a separate application. It could be rewritten independently in React/Solid/etc. and served as static assets.
4. **What is the minimum viable FFI surface?** The critical C-FFI dependencies appear to be: RocksDB, Protobuf, Avro, AWS C SDK, LZ4, and potentially librdkafka. That is 6 FFI integrations for an initial port.
5. **Can FlatBuffers persistence format be changed?** If data migration is acceptable, switching to MessagePack or Cap'n Proto (which has a C library) for persistence could reduce FFI complexity.
6. **How to handle the Pekko actor system replacement?** This is the single largest porting challenge. Options: (a) green-thread-per-node with channel-based messaging, (b) an actor library built on Roc tasks, (c) a fundamentally different architecture (e.g., event-sourced without per-node actors). This needs its own design document.
7. **Which metrics/observability standard to target?** Dropwizard is JVM-specific. Prometheus or OpenTelemetry have C/Rust libraries available. OTLP (OpenTelemetry Protocol) would be future-proof.
