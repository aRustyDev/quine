# Outputs & Recipe System

## What Happens Here

The output system is how Quine delivers results from standing queries to external systems. When a standing query detects a graph pattern match (or cancellation), it produces a `StandingQueryResult` that flows through an output pipeline: optional filtering, optional transformation, optional Cypher enrichment, serialization, and finally delivery to one or more destinations (Kafka, Kinesis, HTTP endpoint, Slack, file, etc.).

Like ingest, there are two generations running in parallel:

- **V1 outputs** (`StandingQueryResultOutput.scala`, `model/outputs/*.scala`): Each output type (PostToEndpoint, WriteToKafka, etc.) extends `OutputRuntime` and produces a `Flow[StandingQueryResult, SqResultsExecToken, NotUsed]`. The output is a single Pekko Streams flow that serializes and delivers each result.
- **V2 outputs** (`model/outputs2/query/standing/StandingQueryResultWorkflow.scala`, `outputs2/` module): A workflow-based architecture with separate filter, pre-enrichment transformation, enrichment query, and destination steps. Destinations live in a separate `outputs2` module with a trait-based abstraction (`ResultDestination`, `DestinationSteps`).

The **recipe system** (`Recipe.scala`, `RecipeInterpreter.scala`, `RecipeV2.scala`, `RecipeInterpreterV2.scala`) provides a declarative YAML/JSON format that wires together ingest streams, standing queries, and output destinations into a single deployable unit.

### V1 Output Flow

```
StandingQueryResult
  -> KillSwitch (for output lifecycle)
  -> resultHandlingFlow (pattern match on output type):
       Drop: discard
       InternalQueue: enqueue for testing
       PostToEndpoint: HTTP POST as JSON
       WriteToKafka: produce to Kafka topic
       WriteToKinesis: produce to Kinesis stream
       WriteToSNS: publish to SNS topic
       PrintToStandardOut: log to console
       WriteToFile: append to file
       PostToSlack: webhook to Slack (with batching)
       CypherQuery: execute enrichment query, then recurse to andThen output
       QuinePatternQuery: same as CypherQuery but uses Quine Pattern engine
  -> SqResultsExecToken (completion signal to MasterStream)
```

Each V1 output type is defined in `routes.StandingQueryResultOutputUserDef` (the API/config model) and has a corresponding `OutputRuntime` implementation in `model/outputs/`.

### V2 Output Workflow

```
StandingQueryResult
  -> Optional filter (Predicate: match on isPositiveMatch, data fields)
  -> Optional pre-enrichment transformation (e.g., InlineData: flatten meta+data)
  -> Optional enrichment Cypher query (execute query, produce QueryContext)
  -> Broadcast to N destinations (via alsoToAll):
       Each destination is a DataFoldableSink that accepts the output type
```

The V2 workflow model is significantly more composable than V1:
- **Predicate** -- filter results before processing
- **StandingQueryResultTransformation** -- transform result shape (currently: `InlineData` which extracts just the data map as a `QuineValue`)
- **CypherQuery enrichment** -- execute a Cypher query using the result as input, producing a `QueryContext` with named columns
- **Destinations** -- multiple destinations per workflow, each receiving the same processed data

### V2 Destination Architecture (`outputs2/` module)

The `outputs2` module provides a clean separation between output encoding and destination transport:

**Sink Traits:**
- `ByteArraySink` -- accepts `Array[Byte]` (for Kafka, Kinesis, SNS, File, StandardOut, ReactiveStream)
- `DataFoldableSink` -- accepts any type with a `DataFoldableFrom` instance (for HTTP endpoint)
- `AnySink` -- accepts anything (for Drop)

**ResultDestination** sealed trait hierarchy:
- `ResultDestination.Bytes` -- subtypes: Kafka, Kinesis, SNS, File, StandardOut, ReactiveStream
- `ResultDestination.FoldableData` -- subtypes: HttpEndpoint
- `ResultDestination.AnyData` -- subtypes: Drop

**DestinationSteps** -- combines encoding with destination:
- `FoldableDestinationSteps.WithByteEncoding(encoder, destination)` -- fold data to encoder repr, encode to bytes, send to ByteArraySink
- `FoldableDestinationSteps.WithDataFoldable(destination)` -- fold data directly to destination's native format
- `FoldableDestinationSteps.WithAny(destination)` -- pass through to AnySink
- `NonFoldableDestinationSteps.WithRawBytes(destination)` -- pass raw bytes to ByteArraySink

**OutputEncoder:**
- `OutputEncoder.JSON` -- fold to circe JSON, print to bytes with configurable charset
- `OutputEncoder.Protobuf` -- fold to QuineValue, serialize via QuineValueToProtobuf

### Supported Output Destinations

| Destination | V1 Class | V2 Class (`outputs2/destination/`) | Transport |
|---|---|---|---|
| **HTTP Endpoint** | `PostToEndpointOutput` | `HttpEndpoint` | Pekko HTTP `singleRequest`; POST JSON; configurable parallelism; custom headers |
| **Kafka** | `KafkaOutput` | `Kafka` | pekko-connectors-kafka Producer; configurable topic, bootstrap servers, SSL/SASL auth, kafkaProperties |
| **Kinesis** | `KinesisOutput` | `Kinesis` | pekko-connectors-kinesis `KinesisFlow`; configurable parallelism, batch size, rate limits |
| **SNS** | `SnsOutput` | `SNS` | pekko-connectors-sns `SnsPublisher`; 10 parallel requests by default |
| **File** | `FileOutput` | `File` | Pekko Streams `FileIO.toPath`; append mode |
| **Standard Out** | `ConsoleLoggingOutput` | `StandardOut` | `System.out.write` (V2) or logger (V1) |
| **Slack** | `SlackOutput` | (V1 only) | Pekko HTTP webhook POST; result batching with configurable interval; Slack Block Kit formatting |
| **Reactive Stream** | N/A | `ReactiveStream` | TCP server via Pekko TCP; length-prefixed framing; BroadcastHub for fan-out |
| **Drop** | `DropOutput` | `Drop` | `Sink.ignore` |
| **Cypher Query** | `CypherQueryOutput` | (workflow enrichment) | Executes Cypher query, passes results to `andThen` output (V1) or broadcasts to destinations (V2) |
| **Quine Pattern Query** | `QuinePatternOutput` | N/A | Like CypherQuery but uses Quine Pattern engine |

### Serialization

V1 serialization (`StandingQueryResultOutput.serialized`):
- `OutputFormat.JSON` -- `StandingQueryResult.toJson` with configurable structure (WithMetadata or Bare)
- `OutputFormat.Protobuf` -- only positive matches; converts data map to protobuf bytes via schema

V2 serialization (`OutputEncoder`):
- JSON encoding via `DataFolderTo.jsonFolder` -> circe JSON -> bytes
- Protobuf encoding via `QuineSerializationFoldersTo.quineValueFolder` -> QuineValue -> protobuf bytes

### Recipe System

A recipe is a YAML/JSON document that declaratively defines a complete Quine application:

**V1 Recipe** (`RecipeV1`):
```yaml
version: 1
title: "My Recipe"
ingestStreams:          # List[IngestStreamConfiguration]
standingQueries:       # List[StandingQueryDefinition] with outputs map
nodeAppearances:       # UI customization
quickQueries:          # UI customization
sampleQueries:         # UI customization
statusQuery:           # Optional periodic Cypher query for monitoring
```

**V2 Recipe** (`RecipeV2.Recipe`):
```yaml
version: 2
title: "My Recipe"
ingestStreams:          # List[IngestStreamV2] with source, query, transformation
standingQueries:       # List[StandingQueryDefinitionV2] with pattern + workflow outputs
nodeAppearances:       # UI customization
quickQueries:          # UI customization
sampleQueries:         # UI customization
statusQuery:           # Optional periodic Cypher query
```

Key differences in V2:
- Ingest streams carry their Cypher query inline (not embedded in the format)
- Standing query outputs use the workflow model (filter -> transform -> enrich -> destinations)
- Standing query patterns use the V2 API pattern types

**Recipe Loading** (`RecipeLoader`):
1. Resolve recipe identifier: URL, local file path, or canonical name (redirected via `recipes.quine.io`)
2. Parse YAML/JSON via `circe.yaml`
3. Detect version from `version` field
4. Decode into `RecipeV1` or `RecipeV2.Recipe`
5. Apply variable substitutions (`$varName` -> value from `--recipe-value` CLI args)

**Recipe Interpretation** (`RecipeInterpreter` / `RecipeInterpreterV2`):
1. Set UI configuration (node appearances, quick queries, sample queries)
2. Create standing queries with their output configurations
3. Create ingest streams (named `INGEST-1`, `INGEST-2`, etc. in V1; custom or `ingest-stream-0` etc. in V2)
4. Start periodic reporters for ingest progress and standing query counts
5. Optionally start status query reporter (periodic Cypher query execution)

Variable substitution is simple: strings starting with `$` are looked up in the values map. `$$` escapes to a literal `$`. Substitution applies to URLs, connection strings, credentials, and other configurable string fields.

## Key Types and Structures

### V1 Output Types
- `StandingQueryResultOutputUserDef` -- sealed trait ADT; cases: Drop, InternalQueue, PostToEndpoint, WriteToKafka, WriteToKinesis, WriteToSNS, PrintToStandardOut, WriteToFile, PostToSlack, CypherQuery, QuinePatternQuery
- `OutputRuntime` -- trait with `flow(name, namespace, output, graph) -> Flow[StandingQueryResult, SqResultsExecToken, NotUsed]`
- `StandingQueryResultOutput` -- object that dispatches to concrete OutputRuntime implementations
- `SqResultsExecToken` -- completion token flowing into MasterStream

### V2 Output Types
- `StandingQueryResultWorkflow` -- case class: outputName, namespaceId, workflow, destinationStepsList (NonEmptyList)
- `Workflow` -- case class: filter (Option[Predicate]), preEnrichmentTransformation, enrichmentQuery
- `Predicate` -- filter on standing query results
- `StandingQueryResultTransformation` -- sealed trait; currently only `InlineData`
- `BroadcastableFlow` -- trait with existential type `Out` and `DataFoldableFrom[Out]`

### `outputs2` Module Types
- `ResultDestination` -- sealed trait; subtypes: Bytes (Kafka, Kinesis, SNS, File, StandardOut, ReactiveStream), FoldableData (HttpEndpoint), AnyData (Drop)
- `DestinationSteps` -- sealed trait; combines encoding + transport
- `OutputEncoder` -- sealed trait; JSON or Protobuf encoding
- `ByteArraySink` / `DataFoldableSink` / `AnySink` -- sink traits parameterized by input type
- `DataFoldableFrom[A]` / `DataFolderTo[B]` -- typeclass-based serialization framework (fold pattern)

### Recipe Types
- `Recipe` -- sealed trait; V1 and V2 variants
- `RecipeV1` -- ingestStreams, standingQueries, UI config, statusQuery
- `RecipeV2.Recipe` -- same structure with V2-style ingest/SQ definitions
- `RecipeInterpreter` / `RecipeInterpreterV2` -- blocking interpreters that wire recipe to app state
- `RecipeLoader` -- version detection, loading, variable substitution

### Core Data Types
- `StandingQueryResult` -- `meta: Meta` (isPositiveMatch, etc.) + `data: Map[String, QuineValue]`
- `StandingQueryResultStructure` -- WithMetaData (includes meta envelope) or Bare (just data)

## Dependencies

### Internal (other stages/modules)
- `StandingQueryResult` / `StandingQueryResultStructure` -- from `quine-core`
- `CypherOpsGraph` -- for enrichment query execution
- `MasterStream` -- standing query result source and completion sink
- `cypher.Value` / `QuineValue` -- runtime value types
- `ProtobufSchemaCache` -- for protobuf output encoding
- `AtLeastOnceCypherQuery` -- retry wrapper for enrichment queries
- `DataFoldableFrom` / `DataFolderTo` -- the `data` module's generic fold framework for serialization

### External (JVM libraries)
- **Apache Pekko Streams** -- `Flow`, `Sink`, `Source`, `KillSwitches`, `BroadcastHub`
- **Pekko HTTP** -- HTTP client for PostToEndpoint and Slack webhook
- **Pekko Connectors (Alpakka)** -- `pekko-connectors-kafka` (Producer), `pekko-connectors-kinesis` (KinesisFlow), `pekko-connectors-sns` (SnsPublisher)
- **Apache Kafka client** -- `ProducerRecord`, `ByteArraySerializer`
- **AWS SDK v2** -- `KinesisAsyncClient`, `SnsAsyncClient`, Netty async HTTP client
- **Circe** -- JSON serialization (noSpaces, Printer)
- **Cats** -- `NonEmptyList` for ensuring at least one destination
- **Google Protobuf** -- protobuf serialization for output encoding
- **SnakeYAML Engine** -- YAML parsing for recipes
- **Dropwizard Metrics** -- standing query stats

### Scala-Specific Idioms
- **Sealed trait ADTs** with exhaustive pattern matching for output dispatch
- **Existential types** (`type Out` in `BroadcastableFlow`) for type-safe workflow composition
- **Typeclass pattern** (`DataFoldableFrom[A]`, `DataFolderTo[B]`) for generic serialization -- the "fold" pattern where data structures accept a folder that builds an output representation
- **`Flow.alsoToAll`** -- broadcast to multiple sinks (V2 multi-destination)
- **Recursive output composition** -- `CypherQueryOutput.andThen` creates a recursive `resultHandlingFlow`
- **Implicit conversions** -- `StandingQueryOutputStructure` to `StandingQueryResultStructure`
- **Circe generic derivation** -- `deriveConfiguredEncoder/Decoder` for all config types
- **`ValidatedNel`** -- error accumulation in recipe variable substitution

## Essential vs. Incidental Complexity

### Essential (must port)
- **Standing query result delivery**: Route SQ results to external systems (HTTP, Kafka, Kinesis, SNS, file, stdout)
- **Serialization**: JSON and Protobuf output encoding
- **Output lifecycle**: Start/stop individual outputs; kill switch per output
- **Filtering**: Drop results based on predicates (positive match only, field matching)
- **Enrichment**: Execute a Cypher query to add data to results before delivery
- **Multi-destination broadcast**: Send same result to multiple destinations
- **Recipe system**: Declarative YAML wiring of ingest + queries + outputs
- **Variable substitution**: Template variables in recipe configs
- **Recursive CypherQuery output**: The ability to chain query -> andThen -> destination

### Incidental (rethink for Roc)
- **V1/V2 dual system**: Only one output model needed in a port
- **Pekko Streams materialization**: KillSwitch composition, materialized value plumbing
- **`DataFoldableFrom`/`DataFolderTo` typeclass machinery**: The generic fold pattern for serialization is elaborate; Roc's abilities system may offer a simpler approach
- **Slack-specific formatting**: Block Kit JSON construction is very Slack-API-specific
- **Actor system lifecycle**: Pekko actor system for HTTP client, Kafka producer, etc.
- **Implicit parameter threading**: graph, logConfig, protobufSchemaCache
- **RecipeLoader URL redirect service**: `recipes.quine.io` redirect for canonical names

## Roc Translation Notes

### Maps Naturally
- **Output destination enumeration**: Kafka, Kinesis, SNS, HTTP, File, Stdout, Drop -- straightforward tagged union
- **Recipe data model**: YAML/JSON config with ingest + queries + outputs maps to Roc records
- **Variable substitution**: Simple string replacement; trivial in any language
- **JSON serialization**: Roc has built-in JSON support
- **Filter/predicate model**: Simple boolean predicates on result data
- **Multi-destination fan-out**: Send to a list of destinations

### Needs Different Approach
- **Streaming delivery**: Pekko Streams `Flow`/`Sink` with backpressure needs a Roc-native equivalent (bounded channels, async tasks, pull-based iterators)
- **External producer libraries**: Kafka Producer (pekko-connectors-kafka), Kinesis producer (AWS SDK), SNS publisher -- all JVM-only. Need: librdkafka FFI for Kafka, AWS REST API or C SDK for Kinesis/SNS
- **HTTP client**: Pekko HTTP for webhook/Slack delivery; Roc needs its own HTTP client (platform effect or library)
- **Backpressure across outputs**: When a destination is slow, Pekko automatically backpressures the standing query. Roc needs explicit bounded buffers or similar
- **Enrichment query execution**: CypherQuery output runs a Cypher query per result. This requires the Cypher execution engine to be available as an output step, not just an ingest step
- **Protobuf output**: Java protobuf library; needs protobuf-c or Roc-native protobuf
- **Slack Block Kit**: Very specific JSON structure; could be dropped or simplified

### Open Questions
- Should the recipe system be ported as-is, or replaced with a Roc-native configuration approach (e.g., a Roc DSL)?
- How to handle enrichment queries in outputs? This requires the full Cypher engine to be callable from the output pipeline.
- What is the Roc equivalent of "broadcast to N sinks"? (List of async tasks? Channel fan-out?)
- Should Slack output be included in the port, or treated as a user-space extension?
- How to handle output backpressure when a destination is temporarily unavailable? (Buffer? Drop? Block the SQ?)
- Is the `DataFoldableFrom`/`DataFolderTo` pattern worth porting, or should Roc use a simpler trait-based serialization?
- How to handle the recursive `CypherQuery -> andThen -> destination` pattern in a non-Scala type system?
- Should the `outputs2` module's trait-based destination abstraction be the basis, or should destinations be simpler (just a function from bytes to IO)?
