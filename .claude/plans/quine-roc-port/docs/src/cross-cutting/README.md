# Cross-Cutting Concerns

## What Happens Here

Cross-cutting concerns are patterns and infrastructure that span the entire Quine codebase rather than living in a single module. This document covers serialization formats and strategies, type class patterns (especially Scala implicit derivation), error handling, metrics instrumentation, logging, and the structured safe-logging system. Understanding these is critical because they pervade every module and will require coherent Roc replacements.

## Key Types and Structures

### Serialization: Formats and Where They Are Used

Quine uses **five distinct serialization formats**, each chosen for a specific context:

#### 1. FlatBuffers (persistence layer -- internal storage)
- **Where:** `quine-core/.../persistor/codecs/` -- all `*Codec.scala` files
- **What gets serialized:** Node snapshots, node change events, domain index events, domain graph nodes, standing queries, standing query states, query plans, and `QuineValue`
- **How:** The `PersistenceCodec[T]` trait (in `PersistenceCodec.scala`) provides a `BinaryFormat[T]` (defined in `BinaryFormat.scala`) with `read(bytes): Try[T]` and `write(obj): Array[Byte]`. The concrete implementation is `PackedFlatBufferBinaryFormat[A]` which adds LZ4-style packing/unpacking around FlatBuffer serialization.
- **Why FlatBuffers:** The code comments document the rationale: backward-compatible schema evolution, minimal allocation overhead vs Protobuf, incremental (lazy) deserialization potential, allows Scala code to "own" the class/trait definitions, fast serialization with compact output. FlatBuffer schemas live in `.fbs` files compiled by the `FlatcPlugin`.
- **Key codecs:** `SnapshotCodec`, `NodeChangeEventCodec`, `DomainIndexEventCodec`, `DomainGraphNodeCodec`, `StandingQueryCodec`, `MultipleValuesStandingQueryStateCodec`, `QuineValueCodec`, `QueryPlanCodec`

#### 2. MessagePack (property value serialization)
- **Where:** `quine-core/.../model/PropertyValue.scala`, `quine-core/.../model/QuineValue.scala`
- **What:** Individual property values stored on nodes. `PropertyValue` has a lazy serialization strategy with two states: `Deserialized` (holds `QuineValue`, lazily computes bytes) and `Serialized` (holds `Array[Byte]` in MessagePack format, lazily deserializes). Custom extension types (bytes 32-38) encode temporal values and QuineIds.
- **Why:** Compact, fast, schema-less -- good for individual values that may never be read.

#### 3. Protocol Buffers (ingest/output -- external data)
- **Where:** `quine-serialization/.../ProtobufSchemaCache.scala`, `quine-serialization/.../QuineValueToProtobuf.scala`
- **What:** Parsing incoming Protobuf-encoded data during ingest, and converting `QuineValue` maps to Protobuf messages for output. Schema resolution is async with caching via `Scaffeine` (Caffeine wrapper).
- **Key types:** `QuineValueToProtobuf` converts `QuineValue` -> `DynamicMessage` with error accumulation via `cats.data.Chain`/`NonEmptyChain`. `ConversionFailure` is a sealed ADT of possible errors (`TypeMismatch`, `UnexpectedNull`, `NotAList`, `InvalidEnumValue`, `FieldError`, `ErrorCollection`).

#### 4. Avro (ingest -- external data)
- **Where:** `quine-serialization/.../AvroSchemaCache.scala`, `data/.../DataFoldableFrom.scala` (the `avroDataFoldable` instance)
- **What:** Parsing incoming Avro-encoded data. Schemas are resolved from URLs with async caching. The `GenericRecord` foldable converts Avro records to any target type via the `DataFolderTo` pattern.

#### 5. JSON / Circe (API layer, configuration, inter-module communication)
- **Where:** Pervasive -- 30+ files use Circe. Key integration points: `quine-serialization/.../EncoderDecoder.scala`, `data/.../DataFolderTo.scala` (the `jsonFolder`), all API endpoint definitions.
- **What:** REST API request/response bodies, configuration file parsing, inter-system data exchange.
- **The EncoderDecoder bridge:** `EncoderDecoder[A]` wraps a `circe.Encoder[A]` and `circe.Decoder[A]` into a single trait that neither Tapir nor endpoints4s "knows about," preventing conflicts between the two API frameworks during the v1->v2 migration. Contains a `DeriveEndpoints4s` helper for deriving instances from endpoints4s `JsonSchema`.

### The DataFolderTo / DataFoldableFrom Abstraction

This is a **format-agnostic data conversion framework** in the `data/` module:

- `DataFolderTo[A]` (in `data/.../DataFolderTo.scala`) -- a visitor/algebra that constructs a value of type `A` from primitive operations (`nullValue`, `trueValue`, `integer(Long)`, `string(String)`, `bytes(Array[Byte])`, `floating(Double)`, date/time operations, `vectorBuilder()`, `mapBuilder()`). Three provided instances: `jsonFolder` (-> `circe.Json`), `anyFolder` (-> `Any`), and the `quineValueFolder` in `quine-serialization`.
- `DataFoldableFrom[A]` (in `data/.../DataFoldableFrom.scala`) -- the dual: something that can be folded over to produce any target type. Provided instances: `jsonDataFoldable`, `byteStringDataFoldable`, `bytesDataFoldable`, `stringDataFoldable`, `protobufDataFoldable` (for `DynamicMessage`), `avroDataFoldable` (for `GenericRecord`), and `quineValueDataFoldableFrom` in `quine-serialization`.
- Together they form a "bridge" pattern: any `DataFoldableFrom[A]` can convert to any `DataFolderTo[B]` target, enabling format-agnostic data transformation (e.g., Protobuf -> QuineValue, JSON -> QuineValue, Avro -> JSON).

### Type Class Patterns (Scala Implicits)

The codebase makes heavy use of Scala's implicit mechanism (269+ implicit definitions in `quine-core` alone). Key patterns:

#### Circe JSON Codec Derivation
- Files: 30+ across `quine-core`, `api/`, `quine-endpoints/`, `quine-endpoints2/`
- Pattern: `implicit val fooEncoder: Encoder[Foo] = deriveEncoder`, `implicit val fooDecoder: Decoder[Foo] = deriveDecoder` (from `circe-generic` or `circe-generic-extras`)
- The `EncoderDecoder[A]` bridge in `quine-serialization` wraps encoder/decoder pairs

#### Pureconfig Configuration Readers
- Files: 17 files in `quine/.../config/`
- Pattern: `implicit val fooConvert: ConfigConvert[Foo] = deriveConvert[Foo]` (from `pureconfig.generic.semiauto`)
- The `PureconfigInstances` trait centralizes common conversions (timeouts, regions, persistence config, log config, symbols, host/port). Uses `ProductHint[T](allowUnknownKeys = false)` to make unknown config keys errors.
- Enum-like sealed traits use `deriveEnumerationConvert`

#### Tapir Schema Derivation
- Files: 30+ across `api/`, `quine-endpoints/`, `quine/`
- Pattern: Tapir endpoint definitions with `Schema[A]` and `Codec[A]` derivation for OpenAPI generation and HTTP route definitions. The v2 API uses Tapir; v1 uses endpoints4s.

#### endpoints4s Schema Derivation
- Files: 30+ in `quine-endpoints/`, `quine-browser/`
- Pattern: The older v1 API framework. Defines schemas via trait mixin (`endpoints4s.circe.JsonSchemas`). Being migrated to Tapir.

#### Cats Type Classes
- Files: 30+ across the codebase
- Pattern: `cats.data.{Chain, NonEmptyChain, NonEmptyList}`, `cats.implicits._`, `cats.effect` (v3). Used for error accumulation (`NonEmptyChain`), functional data structures, and effect management.

#### Shapeless Generic Derivation
- Files: 20 across `api/`, `quine-cassandra-persistor/`, `quine-language/`, `quine/`
- Pattern: Used by Cassandra persistor for HList-based column handling, and by some API codec derivations.

#### Custom Loggable Type Class
- `quine-core/.../util/Loggable.scala` defines `Loggable[A]` with `safe(a): String` and `unsafe(a, redactor): String` methods
- 74+ implicit instances in that file covering QuineId, EventTime, StandingQueryId, various message types
- Integrated with the `com.thatdot.common.logging.Log` safe-logging framework

### Error Handling

Quine uses a **structured error hierarchy** combined with Scala's standard error types:

#### The BaseError Hierarchy (`quine-core/.../util/BaseError.scala`)
```
AnyError (sealed trait extends Throwable)
  +-- BaseError (sealed trait) -- finite, enumerable errors
  |     +-- QuineError (trait, NoStackTrace) -- errors from within Quine
  |     |     +-- ExactlyOnceTimeoutException
  |     |     +-- CypherException (sealed abstract, with Position)
  |     |     +-- QuineRuntimeFutureException
  |     |     +-- GraphNotReadyException
  |     |     +-- ShardNotAvailableException
  |     |     +-- WrappedPersistorException
  |     |     +-- NamespaceNotFoundException
  |     |     +-- DuplicateIngestException
  |     |     +-- ShardIterationException
  |     |     +-- KafkaValidationException
  |     |     +-- FileIngestSecurityException
  |     +-- ExternalError (trait) -- errors from external systems
  |           +-- RemoteStreamRefActorTerminatedError
  |           +-- StreamRefSubscriptionTimeoutError
  |           +-- InvalidSequenceNumberError
  +-- GenericError (case class) -- catch-all for unknown exceptions
```

Both `BaseError.fromThrowable` and `QuineError.fromThrowable` use pattern matching to classify exceptions into the hierarchy.

#### Standard Scala Error Types in Use
- **`Future[T]`** -- the dominant async type in `quine-core`. Used for persistence operations, schema resolution, messaging. Failures are `Future.failed(exception)`.
- **`Either[E, A]`** -- used for synchronous error handling, especially in Protobuf conversion (`Either[ConversionFailure, DynamicMessage]`) and schema resolution.
- **`Try[T]`** -- used in `BinaryFormat.read(bytes): Try[T]` for deserialization and in `DataFoldableFrom.fold` signatures.
- **`cats.data.NonEmptyChain[E]`** -- used for accumulating multiple conversion errors in protobuf mapping.
- **Sealed ADTs for domain errors** -- `ConversionFailure` (protobuf), `ProtobufSchemaError`/`AvroSchemaError` (schema resolution), `CypherException` subtypes (query errors with source positions).

### Metrics Instrumentation

Uses **Dropwizard Metrics** (v4, package `com.codahale.metrics`):

#### Central Registry: `HostQuineMetrics`
- **File:** `quine-core/.../graph/metrics/HostQuineMetrics.scala`
- Wraps a `MetricRegistry` with canonical accessors for all Quine metrics
- Supports namespace-aware metric naming with optional default namespace omission
- Has `enableDebugMetrics` flag -- debug metrics (e.g., shard evictions, messaging volumes) are only registered when enabled, using `NoopMetricRegistry` otherwise

#### Metric Categories
- **Node metrics:** Property counts (histogram), edge counts (histogram), property sizes (histogram) -- all per-namespace
- **Persistor metrics:** Timers for persist-event, persist-snapshot, get-journal, get-latest-snapshot, set-standing-query-state, get-standing-query-states
- **Shard metrics:** Node eviction meters, sleep/wake counters and timers, unlikely-path counters (wake-up-failed, incomplete-shutdown, actor-name-reserved, hard-limit-reached)
- **Messaging metrics:** relayAsk/relayTell meters (local/remote/failed) and latency timers. Debug-only.
- **Ingest metrics:** Per-ingest query timer and deserialization timer
- **Standing query metrics:** Result meters, dropped counters, queue time timers, state size histograms, result hash codes
- **Cache metrics:** Insert timers
- **Gauges:** Domain graph node count, shared valve closed count

#### BinaryHistogramCounter
- **File:** `quine-core/.../graph/metrics/BinaryHistogramCounter.scala`
- Custom histogram with hard-coded power-of-2 buckets: `[1,8)`, `[8,128)`, `[128,2048)`, `[2048,16384)`, `[16384,+inf)`
- Supports increment/decrement with automatic bucket transitions -- used for tracking property and edge counts that can go up and down

#### Timer Extension
- **File:** `quine-core/.../graph/metrics/implicits.scala`
- `TimeFuture` implicit class adds `.time[T](future: => Future[T])` to `Timer`, timing how long a `Future` takes to complete

#### Metrics Reporters
- **File:** `quine/.../config/MetricsReporter.scala`
- Configurable reporters: JMX, CSV (periodic file dump), SLF4J (periodic log), InfluxDB (periodic HTTP push with custom tag transformer)
- All configured via Pureconfig from HOCON config

### Logging

#### Safe Logging Framework
- **Package:** `com.thatdot.common.logging.Log` (in external `quine-common` library)
- **Traits:** `LazySafeLogging` (lazy logger initialization), `StrictSafeLogging` (eager initialization)
- **Safe interpolation:** `safe"message ${Safe(value)} ${Unsafe(secret)}"` -- string interpolator that wraps values in safe/unsafe markers for redaction
- **Loggable type class:** `Loggable[A]` with `safe` and `unsafe` methods, 74+ implicit instances in `quine-core/.../util/Loggable.scala`
- **LogConfig:** Configurable redaction method (currently only `RedactHide`)

#### Underlying Implementation
- **SLF4J** as the logging facade (via `org.slf4j.LoggerFactory`)
- **Logback** as the concrete implementation (version managed in `Dependencies.scala`)
- `scala-logging` (v3.9.6) providing Scala-friendly wrappers

### AWS Integration Utilities

The `aws/` module provides a thin abstraction over AWS SDK v2:

- `AwsCredentials(accessKeyId: Secret, secretAccessKey: Secret)` -- credentials wrapped in `Secret` type for safe logging
- `AwsRegion(region: String)` -- simple region wrapper
- `AwsOps` -- builder extensions (`credentialsV2`, `regionV2`) that handle optional credential/region configuration with fallback to environmental defaults. Sets `httpConcurrencyPerClient = 100`.

## Dependencies

### Internal (other stages/modules)
- `data/` module provides `DataFolderTo`/`DataFoldableFrom` abstractions used by `quine-serialization`
- `quine-serialization/` is used by ingest and output modules for external data format handling
- `quine-core/.../persistor/codecs/` is used by all persistor implementations
- `quine-core/.../graph/metrics/` is used by nearly every runtime component
- `aws/` module is used by Kinesis ingest, S3 ingest, Keyspaces (AWS Cassandra) persistor
- The `com.thatdot.common.logging.Log` package (external library) is used everywhere

### External (JVM libraries)
- **FlatBuffers** (`com.google.flatbuffers`, v25.2.10) -- persistence serialization
- **MessagePack** (`org.msgpack`, v0.9.11) -- property value serialization
- **Protobuf** (`com.google.protobuf`, v4.34.1) -- ingest/output data format
- **Avro** (`org.apache.avro`, v1.12.1) -- ingest data format
- **Circe** (v0.14.15, with -generic-extras, -optics, -yaml) -- JSON codec derivation
- **Cats** (v2.13.0) / **Cats Effect** (v3.7.0) -- functional abstractions
- **Scaffeine/Caffeine** (v5.3.0/v3.2.3) -- async caching for schema resolution
- **Dropwizard Metrics** (v4.2.38) -- runtime metrics infrastructure
- **Logback** (v1.5.32) + **scala-logging** (v3.9.6) -- logging
- **Pureconfig** (v0.17.10) -- HOCON configuration parsing
- **Tapir** (v1.13.14) -- v2 API endpoint definitions and OpenAPI generation
- **endpoints4s** (v1.12.1 + various sub-modules) -- v1 API endpoint definitions
- **AWS SDK v2** (v2.42.24) -- AWS service integration
- **Shapeless** (v2.3.13) -- generic programming / derivation

### Scala-Specific Idioms
- **Implicit type class instances** -- the single most pervasive Scala idiom. Used for JSON codecs, config readers, API schemas, logging formatters, persistence codecs, data conversion. Hundreds of `implicit val`/`implicit def` definitions.
- **Sealed trait + case class ADTs** -- error hierarchies, serialization formats, configuration variants
- **Trait mixin composition** -- `PureconfigInstances`, `EncoderDecoder.DeriveEndpoints4s`, logging traits
- **Lazy val** for deferred initialization (logging, caches)
- **Pattern matching on sealed hierarchies** -- error classification, data folding, value conversion
- **`Future` composition** with `map`/`flatMap`/`recoverWith` -- all async persistence and schema operations

## Essential vs. Incidental Complexity

### Essential (must port)
- **The 5 serialization formats** -- FlatBuffers for persistence, MessagePack for properties, Protobuf/Avro for external data, JSON for API. Each serves a distinct purpose.
- **DataFolderTo/DataFoldableFrom abstraction** -- the format-agnostic conversion bridge. This is elegant and essential for supporting multiple ingest formats.
- **Structured error hierarchy** -- the `BaseError`/`QuineError`/`ExternalError` classification with `fromThrowable` routing is important for operational reliability.
- **Metrics infrastructure** -- per-namespace metric naming, the full set of metric categories (persistence, shard, ingest, standing query, messaging), debug-metric toggle.
- **BinaryHistogramCounter** -- the custom bidirectional histogram for tracking node property/edge counts.
- **Schema caching with async resolution** -- protobuf and avro schemas loaded from URLs with caching.
- **Safe logging with redaction** -- the `Loggable` type class pattern and safe string interpolation for PII/secret protection.
- **AWS credential/region handling** -- the fallback-to-environment pattern with Secret wrapping.

### Incidental (rethink for Roc)
- **Scala implicit resolution** -- the entire type class derivation mechanism (`implicit val`, `implicit def`, `deriving` via macros). Roc uses abilities and explicit passing.
- **Circe-specific codec derivation** -- the macro-based `deriveEncoder`/`deriveDecoder` pattern. Roc JSON handling will use different patterns.
- **Pureconfig** -- HOCON parsing with semiauto derivation. Roc will need a different config parsing approach.
- **Tapir/endpoints4s** -- framework-specific API definition patterns. Roc web frameworks will have their own patterns.
- **The EncoderDecoder bridge** -- exists only to mediate between Tapir and endpoints4s during the v1->v2 migration. Can be dropped entirely.
- **Shapeless** -- used for generic derivation in a few places. Not applicable to Roc.
- **Better-monad-for / kind-projector** -- Scala compiler plugins for ergonomic Scala syntax. No Roc equivalent needed.
- **Cats/Cats Effect** -- the functional programming primitives (`Chain`, `NonEmptyChain`, `IO`). Roc has its own effect system via tasks and abilities.

## Roc Translation Notes

### Maps Naturally
- **Sealed error ADTs** -> Roc tagged unions. `ConversionFailure`, `ProtobufSchemaError`, `AvroSchemaError`, `CypherException` subtypes all map directly to Roc tags.
- **BinaryFormat[T] type class** -> Roc ability with `encode` and `decode` functions.
- **DataFolderTo/DataFoldableFrom visitor pattern** -> Roc ability. The visitor/algebra approach maps very well to Roc's ability system. `DataFolderTo[A]` becomes an ability providing `nullValue`, `string`, `integer`, etc., and `DataFoldableFrom[A]` becomes a function parameterized over that ability.
- **BinaryHistogramCounter** -> direct port with mutable state behind a Roc ability or platform-specific wrapper.
- **Metric naming scheme** (namespace-aware dotted names) -> straightforward string building.
- **Error accumulation with NonEmptyChain** -> Roc `List` of errors or a custom non-empty list type.

### Needs Different Approach
- **FlatBuffers serialization** -- FlatBuffers has no Roc code generator. Options: (a) FFI to the C FlatBuffer library, (b) hand-roll a compatible binary format reader/writer in Roc, (c) switch to a different persistence serialization format that Roc can handle natively. The packing layer (LZ4-like compression) would also need a Roc implementation or FFI.
- **MessagePack** -- no Roc library exists. Options: implement a minimal MessagePack encoder/decoder in Roc (the format is simple enough) or use FFI.
- **Protobuf** -- no Roc protobuf library. Must use FFI to a C protobuf library or implement a wire-format reader. The `DynamicMessage` + `DynamicSchema` pattern (runtime schema resolution) is especially complex.
- **Avro** -- similar to Protobuf: no Roc library. FFI or from-scratch implementation.
- **Circe/JSON** -- Roc has `json` in its standard library. JSON serialization maps naturally but all the implicit derivation must become explicit `encode`/`decode` function implementations.
- **Pureconfig (HOCON config)** -- Roc will need a config file parser. Could use TOML or JSON config instead of HOCON. The key feature to preserve is type-safe config with error messages for unknown keys.
- **Metrics (Dropwizard)** -- no Roc equivalent. Options: (a) FFI to a C metrics library, (b) implement counter/timer/histogram/meter primitives in Roc, (c) expose metrics via a simpler mechanism (e.g., structured logging). The registry + reporter pattern can be modeled as a Roc ability.
- **Logging** -- Roc has `Stdout`/`Stderr` for basic output. The safe-logging framework (redaction, structured log values) would need to be built. The `Loggable` type class maps to a Roc ability or a `toSafeStr`/`toUnsafeStr` function pair on relevant types.
- **Async caching (Scaffeine/Caffeine)** -- Roc has no direct equivalent. Options: implement an LRU cache in Roc, or use FFI to a C cache library. The async aspect (cache miss triggers a `Future`) would use Roc tasks.
- **AWS SDK** -- pure FFI. The `AwsOps` builder pattern would become Roc functions that configure and call AWS APIs through FFI.

### Open Questions
1. **Should FlatBuffers be kept for persistence?** It was chosen partly because it lets Scala "own" the type definitions, which is less relevant in Roc. A simpler binary format (or even MessagePack for everything) might reduce FFI complexity.
2. **Is the DataFolderTo/DataFoldableFrom pattern the right abstraction in Roc?** It maps well to abilities, but Roc's type system may allow a more elegant approach (e.g., a single `serialize`/`deserialize` ability with format-specific implementations).
3. **How to handle Protobuf/Avro runtime schema resolution?** These are fundamentally JVM-library-dependent features. In Roc, this might need to be FFI to C libraries with careful memory management.
4. **What metrics export format to target?** Dropwizard's registry model is JVM-specific. Could target Prometheus exposition format directly, or OpenTelemetry, which has C/Rust libraries available for FFI.
5. **What replaces HOCON?** TOML is a natural fit for Roc (simple, well-specified, has parsers in many languages). JSON config is another option.
6. **How deep does safe-logging need to go?** The current system has 74+ `Loggable` instances. A simpler approach might suffice initially (e.g., a `Debug` ability with safe/unsafe variants).
7. **What's the migration story for existing FlatBuffer-persisted data?** Any format change requires a migration tool that can read the old format (possibly via JVM FFI) and write the new one.
