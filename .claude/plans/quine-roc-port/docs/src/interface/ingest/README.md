# Ingest Pipeline

## What Happens Here

The ingest pipeline is how external data enters the Quine graph. It implements a multi-stage flow: source connection (Kafka, Kinesis, files, etc.) produces raw bytes, which are optionally decompressed, framed into records, deserialized into Cypher values, and then written to the graph via a Cypher query. Each ingest stream runs as a managed Pekko Streams pipeline with built-in lifecycle control (pause/resume/stop), rate limiting, metering, error handling, and optional dead-letter queues.

There are two generations of the ingest system running in parallel:

- **V1 ingest** (`model/ingest/IngestSrcDef.scala`): The original system. Each source type extends `IngestSrcDef` or `RawValuesIngestSrcDef`, directly coupling source, deserialization, and graph writing into a single abstract class hierarchy.
- **V2 ingest** (`model/ingest2/source/DecodedSource.scala`): A refactored system with cleaner separation of concerns. Sources produce `FramedSource` streams of raw frames, which are decoded into `DecodedSource` streams, which are then assembled into a `QuineIngestSource` for graph writing.

Both V1 and V2 ultimately produce a `Source[IngestSrcExecToken, NotUsed]` that plugs into the graph's `MasterStream`.

### Data Flow

```
[External Source] -> raw bytes
  -> ContentDecoder (optional: base64, gzip, zip decompression)
  -> Framing (newline-delimited, length-prefixed, CSV parsing, JSON array splitting)
  -> Deserialization (JSON -> CypherValue, Protobuf -> CypherValue, Raw bytes -> CypherValue)
  -> Optional JavaScript transformation (V2 only, via GraalVM polyglot)
  -> Cypher query execution (parameterized: `$that` = deserialized value)
  -> Graph mutations (node creation, property setting, edge creation)
```

### Supported Ingest Sources

| Source | Class(es) | External Library | Notes |
|---|---|---|---|
| **Kafka** | `KafkaSrcDef` (V1), `KafkaSource` (V2) | pekko-connectors-kafka (alpakka-kafka) | Supports topic subscription or partition assignment; optional explicit offset committing; consumer group management; SSL/SASL auth; ending offset |
| **Kinesis (direct)** | `KinesisSrcDef` (V1), `KinesisSource` (V2) | pekko-connectors-kinesis, AWS SDK v2 | Shard-based reading; iterator types (Latest, TrimHorizon, AtTimestamp, AtSequenceNumber); rate limiting per shard (2MB/s) |
| **Kinesis (KCL)** | `KinesisKclSrcDef` (V1), `KinesisKclSrc` (V2) | Amazon Kinesis Client Library 3.x | DynamoDB-backed checkpointing; automatic shard rebalancing; extensive configuration surface (scheduler, checkpoint, lifecycle, metrics settings) |
| **SQS** | `SqsStreamSrcDef` (V1), `SqsSource` (V2) | pekko-connectors-sqs, AWS SDK v2 | Optional message deletion after read; configurable read/write parallelism |
| **Server-Sent Events** | `ServerSentEventsSrcDef` (V1), `ServerSentEventSource` (V2) | Pekko HTTP (SSE support) | Consumes only the `data` portion of events |
| **WebSocket** | `WebsocketSimpleStartupSrcDef` (V1), `WebSocketClientSource` (V2) | Pekko HTTP (WebSocket) | Initial handshake messages; configurable keepalive (ping/pong) |
| **File** | `ContentDelimitedIngestSrcDef` (V1), `FileSource` (V2) | Pekko Streams FileIO | Local filesystem; supports start offset, record limit, charset transcoding |
| **S3** | Via `ContentDelimitedIngestSrcDef` (V1), `S3Source` (V2) | pekko-connectors-s3 | Downloads object as byte stream; same framing as file ingest |
| **Standard Input** | Via `ContentDelimitedIngestSrcDef` (V1), `StandardInputSource` (V2) | JDK `System.in` | Reads from process stdin |
| **Number Iterator** | Via `ContentDelimitedIngestSrcDef` (V1), `NumberIteratorSource` (V2) | None | Generates sequential longs; useful for testing |
| **Reactive Stream** | `ReactiveSource` (V2 only) | Pekko TCP | TCP server accepting length-prefixed binary frames |
| **WebSocket File Upload** | `WebSocketFileUploadSource` (V2 only) | Pekko HTTP WebSocket + MergeHub | Browser-initiated file streaming via WebSocket |

### Data Formats

**Streaming formats** (for message-oriented sources like Kafka, Kinesis, SQS, SSE, WebSocket):
- `CypherJson` / `JsonFormat` -- Parse each message as JSON, bind to Cypher query parameter
- `CypherRaw` / `RawFormat` -- Pass raw bytes as a Cypher string value
- `CypherProtobuf` / `ProtobufFormat` -- Deserialize via protobuf schema (loaded from URL, cached in `ProtobufSchemaCache`)
- `AvroFormat` (V2 only) -- Deserialize via Avro schema (loaded from URL, cached in `AvroSchemaCache`)
- `Drop` / `DropFormat` -- Discard all records (testing)

**File formats** (for file-oriented sources like File, S3, stdin):
- `CypherLine` / `LineFormat` -- Each line is a raw string
- `CypherJson` / `JsonLinesFormat` -- Each line is a JSON value (JSONL)
- `JsonFormat` -- Entire file is a JSON array, each element is a record
- `CypherCsv` / `CsvFormat` -- CSV with configurable delimiter, quote, escape characters, optional headers

### Record Deserialization (V1: `ImportFormat`)

In V1, `ImportFormat` is the trait that converts raw bytes into `cypher.Value` and writes them to the graph. Concrete implementations:
- `CypherJsonInputFormat` -- Parses JSON, executes a compiled Cypher query with the value bound to a parameter
- `CypherRawInputFormat` -- Wraps raw bytes as a Cypher string
- `ProtobufInputFormat` -- Parses protobuf using a `ProtobufParser` backed by a `Descriptor`
- `QuinePatternJsonInputFormat` -- Uses the Quine Pattern engine instead of Cypher
- `TestOnlyDrop` -- No-op for testing

Each `ImportFormat` encapsulates both the deserialization logic AND the graph-write logic (`writeValueToGraph`), which compiles and executes a Cypher query using `AtLeastOnceCypherQuery` for retry semantics.

### Record Deserialization (V2: `FrameDecoder` + `QuineIngestQuery`)

In V2, concerns are separated:
- `FrameDecoder` handles bytes -> typed value (JSON, Protobuf, Raw, Avro, CSV, etc.)
- `QuineIngestQuery` handles typed value -> graph write (compiles and executes Cypher)
- Optional `Transformation` (JavaScript via GraalVM) sits between decode and query

### Stream Lifecycle Control

Every ingest stream is wrapped in:
1. **RestartSource** -- Automatic restart with exponential backoff on recoverable errors (KafkaException, SdkException). Default: 3 restarts in 31 seconds.
2. **ShutdownSwitch** -- External kill signal (KillSwitch for most sources, `Consumer.Control.drainAndShutdown` for Kafka).
3. **Valve** -- Pause/resume flow control (`SwitchMode.Open` / `SwitchMode.Closed`).
4. **Throttle** -- Optional max-per-second rate limiting.
5. **Metering** -- `IngestMeter` tracks ingested count, byte rates, deserialization timing via Dropwizard Metrics.

These are composed via `ControlSwitches(shutdownSwitch, valveSwitch, terminationSignal)` and exposed as `QuineAppIngestControl`.

### Dead Letter Queue (V2 only)

Failed records can be routed to dead-letter queues via `DeadLetterQueueSettings`. Supported DLQ destinations: HTTP endpoint, File, Kafka, Kinesis, ReactiveStream, SNS, StandardOut. DLQ records include the original frame, optionally the decoded value, and an error message.

## Key Types and Structures

- `QuineIngestSource` -- trait; minimal interface: `name`, `graph`, `meter`, `stream(namespace, hooks) -> Source[IngestSrcExecToken, NotUsed]`
- `IngestSrcDef` -- V1 abstract class; adds format, parallelism, throttle, valve, writeToGraph, ack, restart
- `RawValuesIngestSrcDef` -- V1 abstract class extending IngestSrcDef; adds raw byte source + deserialization
- `DecodedSource` -- V2 abstract class; type-parameterized over `Decoded` and `Frame` types; produces `Source[(() => Try[Decoded], Frame), ShutdownSwitch]`
- `FramedSource` -- V2 intermediate; source of raw frames before decoding
- `QuineIngestQuery` -- V2 trait; `apply(cypher.Value) -> Future[Unit]`; implementations: `QuineValueIngestQuery` (compiles Cypher), `QuineDropIngestQuery` (no-op)
- `ImportFormat` -- V1 trait; `importBytes(Array[Byte]) -> Try[cypher.Value]` + `writeValueToGraph`
- `FrameDecoder` -- V2; converts IngestFormat to a decoding function
- `IngestStreamConfiguration` -- V1 sealed trait (ADT) of all source configs (KafkaIngest, KinesisIngest, FileIngest, etc.)
- `IngestSource` -- V2 sealed trait (ADT) of all source configs (KafkaIngest, KinesisIngest, FileIngest, etc.)
- `IngestSrcExecToken` -- completion token emitted per processed record; flows into MasterStream
- `ControlSwitches` -- bundles ShutdownSwitch + ValveSwitch + termination Future
- `ContentDecoder` -- decompression: Base64, Gzip, Zlib, applied in sequence

## Dependencies

### Internal (other stages/modules)
- `CypherOpsGraph` -- the graph service that receives mutations
- `MasterStream` -- the stream hub that ingest sources feed into
- `NamespaceId` -- logical graph partition
- `cypher.Value` / `QuineValue` -- the runtime value types
- `QuineIdProvider` -- for deterministic ID generation from ingested data (via `idFrom()` Cypher function)
- `ProtobufSchemaCache` / `AvroSchemaCache` -- schema registries for protobuf/avro deserialization
- `AtLeastOnceCypherQuery` -- retry wrapper for idempotent Cypher execution

### External (JVM libraries)
- **Apache Pekko Streams** -- the streaming runtime; `Source`, `Flow`, `Sink`, `KillSwitches`, `Valve`, `RestartSource`, `MergeHub`, `BroadcastHub`
- **Pekko Connectors (Alpakka)** -- `pekko-connectors-kafka`, `pekko-connectors-kinesis`, `pekko-connectors-sqs`, `pekko-connectors-s3`, `pekko-connectors-text`
- **Pekko HTTP** -- for SSE, WebSocket, HTTP endpoint DLQ
- **Apache Kafka client** -- `org.apache.kafka:kafka-clients` (consumer/producer APIs, serializers)
- **AWS SDK v2** -- `software.amazon.awssdk:kinesis`, `software.amazon.awssdk:sqs`, `software.amazon.awssdk:s3`
- **Amazon Kinesis Client Library 3.x** -- for KCL-based Kinesis consumption (DynamoDB leases, CloudWatch metrics)
- **Circe** -- JSON parsing (via `jawn` backend)
- **Cats** -- `ValidatedNel` for error accumulation during config validation
- **Dropwizard Metrics** -- `Timer`, `Meter` for ingest performance tracking
- **Google Protobuf** -- `com.google.protobuf:protobuf-java` for descriptor-based deserialization
- **GraalVM Polyglot** -- JavaScript transformation engine (V2 only)

### Scala-Specific Idioms
- **Sealed trait ADTs** with pattern matching for source type dispatch (e.g., `IngestStreamConfiguration` has 11 cases)
- **Pekko Streams DSL** (`Source.viaMat(...)(Keep.both)`, `Flow.mapAsync`, `watchTermination`, materialized values)
- **Type members** (`type InputType`, `type Decoded`, `type Frame`) for type-level parameterization within abstract classes
- **Implicit parameters** for graph, logConfig, protobufSchemaCache threading through call chains
- **`ValidatedNel`** (cats) for accumulating validation errors before stream construction
- **`Future` composition** with `ExecutionContext.parasitic` for zero-overhead continuation
- **Case class hierarchies** with circe generic derivation for JSON serialization/deserialization of config

## Essential vs. Incidental Complexity

### Essential (must port)
- **Source abstraction**: Connect to each external system, produce a stream of raw records
- **Framing**: Split byte streams into individual records (newline, length-prefix, CSV, JSON array)
- **Deserialization**: Convert raw bytes to typed values (JSON, Protobuf, Avro, CSV, raw)
- **Graph write**: Execute a parameterized query for each record to create/update nodes and edges
- **Lifecycle control**: Pause, resume, stop ingest streams; rate limiting; restart on transient errors
- **Metering**: Track ingested count, byte rates, deserialization latency
- **Dead letter queue**: Route failed records to configurable destinations
- **Configuration validation**: Validate source configs before stream construction (e.g., Kafka settings validation)
- **Content decoding**: Base64/gzip/zlib decompression pipeline

### Incidental (rethink for Roc)
- **Pekko Streams materialization model**: The concept of "materialized values" (KillSwitch, Future[Done], ValveSwitch) and `Keep.both`/`Keep.right` combinators is deeply Pekko-specific
- **V1/V2 dual codepath**: The entire V1ToV2 / V2ToV1 conversion layer exists for backward compatibility; a port only needs one model
- **ImplicitParameterThreading**: graph, logConfig, protobufSchemaCache passed implicitly everywhere
- **Actor-based concurrency**: Pekko ActorSystem, dispatchers, materializers
- **Circe/Cats ecosystem**: JSON codec derivation, ValidatedNel; Roc would use its own serialization
- **Dropwizard Metrics**: Specific metrics library; Roc would use platform-native metrics
- **`ImportFormat` conflating deserialization + graph write**: V1 couples these; V2 separates them correctly

## Roc Translation Notes

### Maps Naturally
- **Source enumeration**: The set of supported sources (Kafka, Kinesis, S3, File, etc.) is a straightforward tagged union / enum in Roc
- **Data format enumeration**: StreamingFormat / FileFormat are simple enums
- **Pipeline structure**: source -> decompress -> frame -> decode -> transform -> query -> write maps to any streaming/pipeline abstraction
- **Rate limiting**: Token bucket or similar; no framework dependency
- **Configuration model**: Case class hierarchies map to Roc records + tag unions
- **Content decoding chain**: Composable byte transformers (base64, gzip, zlib)

### Needs Different Approach
- **Streaming runtime**: Pekko Streams (reactive streams backpressure, graph-shaped pipelines, materialized values) has no Roc equivalent. Need to design a streaming abstraction -- possibly: platform tasks with channels, or a simpler pull-based iterator model
- **External connector libraries**: pekko-connectors-kafka, pekko-connectors-kinesis, pekko-connectors-s3, pekko-connectors-sqs are JVM-only. Roc needs native client libraries or C FFI bindings for Kafka (librdkafka), AWS SDK (via C SDK or REST APIs), etc.
- **Backpressure propagation**: Pekko Streams' built-in backpressure (Reactive Streams spec) needs explicit implementation in Roc (e.g., bounded channels, pull-based iteration)
- **Lifecycle management**: KillSwitch + Valve + RestartSource patterns need Roc-native equivalents (Task cancellation, circuit breakers)
- **Kafka offset management**: Consumer group coordination, explicit commit batching -- requires direct Kafka client integration
- **Kinesis KCL**: The KCL is a complex Java library with DynamoDB leases; may need to reimplement checkpointing or use the C/Rust Kinesis libraries
- **Protobuf deserialization**: Currently uses Java protobuf library; would need protobuf-c or similar

### Open Questions
- What streaming/concurrency model will Roc use? (Tasks + Channels? A streaming library? Manual poll loops?)
- Should external source connectors be implemented as Roc platform effects, host-language FFI, or pure Roc over raw protocol?
- How to handle Kafka consumer group protocol in Roc? (librdkafka FFI is the most practical path)
- Is KCL (Kinesis Client Library) functionality needed, or is direct Kinesis API sufficient?
- How to handle schema registries (Protobuf, Avro) -- embedded schemas vs. external registry service?
- What is the Roc-native approach to backpressure across async boundaries?
- Should the V2 architecture (FramedSource -> DecodedSource -> QuineIngestSource) be the basis, or should we simplify further?
- How to handle JavaScript transformations? GraalVM is JVM-only. Options: embedded JS interpreter, WASM-based transform engine, or drop JS support.
