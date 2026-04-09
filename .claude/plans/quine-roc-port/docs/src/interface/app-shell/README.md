# Application Shell

## What Happens Here

The application shell is the outermost layer of Quine: the `Main` object that bootstraps the process, the `QuineApp` class that holds all runtime application state, and the configuration system that controls everything. It is responsible for parsing command-line arguments, loading HOCON configuration, creating the graph, restoring persisted state, wiring up the web server, and orchestrating graceful shutdown.

### Startup Sequence (Main.scala, ~387 lines)

The startup is strictly sequential and runs on the main thread, blocking at each step:

1. **StatusLines** -- create a dual-output logger (structured logger + stderr) for startup messages
2. **Character encoding check** -- warn if not UTF-8
3. **Parse CLI arguments** (`CmdArgs`) -- using scopt: `--port`, `--recipe`, `--recipe-value`, `--disable-web-service`, `--force-config`, `--no-delete`, `--version`
4. **Load recipe** (if specified) -- `RecipeLoader.getAndSubstituteAny` reads from file/URL, applies `$key` substitutions, returns `Recipe.V1` or `Recipe.V2`
5. **Parse configuration** (`QuineConfig`) -- PureConfig loads from HOCON (application.conf + system properties), then applies CLI overrides (port, webserver enabled), then recipe overrides (temp RocksDB data file)
6. **Log startup info** -- version, cores, heap size
7. **Start metrics reporters** -- JMX by default, configured via `metricsReporters`
8. **Create GraphService** -- `Await.result` of `GraphService(...)` which creates the Pekko `ActorSystem`, persistor, shards, and master stream. This is the heaviest step. Also syncs the persistence version.
9. **Create FileAccessPolicy** -- validates and builds the file ingest security policy from config + recipe paths
10. **Instantiate QuineApp** -- constructs the application state object with graph, config, recipe
11. **Restore namespaces** -- `restoreNonDefaultNamespacesFromMetaData` reads namespace list from persistor
12. **Run migrations** -- checks `MigrationVersion` against goal; runs `QuineMigrations` if needed (currently one migration: MultipleValuesRewrite)
13. **Load app data** -- `loadAppData` restores all persisted state: sample queries, quick queries, node appearances, standing query outputs (V1 + V2), ingest streams (V1 + V2), re-registers Cypher user-defined procedures
14. **Start recipe interpreter** (if recipe) -- `RecipeInterpreter` or `RecipeInterpreterV2` runs the recipe's ingest + SQ setup on a scheduled basis
15. **Bind web server** -- `QuineAppRoutes.bindWebServer` starts the Pekko HTTP server; optionally binds a separate health endpoint server on a different port for mTLS deployments
16. **Register shutdown hooks** -- `CoordinatedShutdown` tasks: cancel recipe interpreter, sync ingest metadata, stop ingest streams, shut down graph, stop metrics reporters, stop logback
17. **Block main thread** -- `Await.ready(system.whenTerminated, Duration.Inf)`

### QuineApp (QuineApp.scala, ~1738 lines)

`QuineApp` is the central application state class. It extends `BaseApp` and mixes in numerous state traits:

```
QuineApp extends BaseApp
  with AdministrationRoutesState        -- shutdown()
  with QueryUiConfigurationState        -- sample queries, quick queries, node appearances
  with StandingQueryStoreV1             -- V1 standing query CRUD
  with StandingQueryInterfaceV2         -- V2 standing query CRUD
  with IngestStreamState                -- ingest stream lifecycle management
  with V1.QueryUiConfigurationSchemas   -- V1 schema derivation
  with V1.StandingQuerySchemas          -- V1 SQ schema derivation
  with V1.IngestSchemas                 -- V1 ingest schema derivation
  with EncoderDecoder.DeriveEndpoints4s -- endpoints4s codec derivation
  with CirceJsonAnySchema               -- catch-all JSON schema
  with SchemaCache                      -- protobuf/avro schema caches
```

**What QuineApp manages:**

1. **UI Configuration State** -- `sampleQueries`, `quickQueries`, `nodeAppearances` stored as `@volatile` vectors with object-level locks for synchronized persistence
2. **Standing Queries (V1 and V2)** -- `outputTargets: Map[NamespaceId, Map[SQName, (StandingQueryId, Map[OutputName, OutputTarget])]]` tracking all standing queries, their outputs, and kill switches. Dual V1/V2 output target types coexist.
3. **Ingest Streams** -- `ingestStreams: Map[NamespaceId, Map[IngestName, IngestStreamWithControl[UnifiedIngestConfiguration]]]` holding both V1 and V2 ingest streams via `UnifiedIngestConfiguration` wrapper
4. **Schema Caches** -- `protobufSchemaCache` and `avroSchemaCache` for schema-driven ingest/output formats
5. **Namespace Management** -- create/delete graph namespaces with persistence
6. **Metadata Persistence** -- all state above round-trips through the graph's `namespacePersistor` as JSON-encoded byte arrays keyed by string names
7. **Telemetry** -- `ImproveQuine` sends anonymous usage data (opt-out via `helpMakeQuineBetter: false`)

**The synchronization model** is notable: `synchronizedFakeFuture` acquires an object lock, runs a `Future`, and `Await`s the result within the lock. This makes all state mutations sequential and blocks threads. The code comments explicitly acknowledge this as a trade-off for simplicity at the cost of concurrency.

### BaseApp (BaseApp.scala, ~263 lines)

`BaseApp` provides the metadata persistence primitives that `QuineApp` builds on:
- `storeLocalMetaData` / `getLocalMetaData` -- per-member-index metadata (e.g., this node's ingest streams)
- `storeGlobalMetaData` / `getGlobalMetaData` -- cluster-wide metadata (e.g., standing query outputs)
- `getOrDefaultLocalMetaData` / `getOrDefaultGlobalMetaData` -- read-or-initialize patterns
- `getOrDefaultLocalMetaDataWithFallback` -- read-or-initialize with type migration fallback
- `createNamespace` / `deleteNamespace` / `getNamespaces` -- namespace CRUD
- Serialization via `EncoderDecoder` (circe encoder/decoder pair) to/from UTF-8 JSON bytes

### Configuration System

**QuineConfig** (config/QuineConfig.scala) is the top-level configuration, loaded from HOCON via PureConfig:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `dumpConfig` | Boolean | false | Print config on startup |
| `timeout` | Timeout | 120s | Global operation timeout |
| `inMemorySoftNodeLimit` | Option[Int] | 10000 | Shard soft node limit |
| `inMemoryHardNodeLimit` | Option[Int] | 75000 | Shard hard node limit |
| `declineSleepWhenWriteWithin` | Duration | 100ms | Keep node awake after write |
| `declineSleepWhenAccessWithin` | Duration | 0ms | Keep node awake after access |
| `maxCatchUpSleep` | Duration | 2000ms | Max catch-up sleep |
| `webserver` | WebServerBindConfig | 0.0.0.0:8080 | HTTP bind address/port |
| `webserverAdvertise` | Option[...] | None | Canonical URL override |
| `shouldResumeIngest` | Boolean | false | Resume ingests on restart |
| `shardCount` | Int | 4 | Number of shards |
| `id` | IdProviderType | UUID | Node ID generation scheme |
| `edgeIteration` | EdgeIteration | ReverseInsertion | Edge traversal order |
| `store` | PersistenceAgentType | RocksDb | Persistence backend |
| `persistence` | PersistenceConfig | defaults | Journal/snapshot settings |
| `labelsProperty` | Symbol | `__LABEL` | Property name for labels |
| `metricsReporters` | List[MetricsReporter] | [Jmx] | Where to report metrics |
| `metrics` | MetricsConfig | defaults | Debug metrics toggle |
| `helpMakeQuineBetter` | Boolean | true | Telemetry opt-in |
| `defaultApiVersion` | String | "v1" | Default API version for UI |
| `logConfig` | LogConfig | permissive | Logging configuration |
| `fileIngest` | FileIngestConfig | defaults | File ingest security policy |

**WebServerBindConfig:**
- `address: Host` (default 0.0.0.0)
- `port: Port` (default 8080)
- `enabled: Boolean` (default true)
- `useTls: Boolean` (auto-detected from `SSL_KEYSTORE_PATH` env var)
- `useMtls: UseMtls` (client cert validation, separate health port)

**PersistenceAgentType** (sealed ADT):
- `Empty` -- no persistence (no-op)
- `InMemory` -- in-memory only (lost on shutdown)
- `RocksDb(filepath, writeAheadLog, syncAllWrites, ...)` -- local embedded DB (default)
- `MapDb(filepath, numberPartitions, ...)` -- alternative local DB
- `Cassandra(keyspace, endpoints, consistency, ...)` -- distributed persistence
- `Keyspaces(...)` -- AWS Keyspaces (Cassandra-compatible)
- `ClickHouse(...)` -- ClickHouse persistence

**IdProviderType** (sealed ADT):
- `UUID` (default), `Long`, `Uuid3`, `Uuid4`, `Uuid5`, `ByteArray`
- Each has optional `partitioned: Boolean` for position-aware IDs

**FileIngestConfig:**
- `allowedDirectories: Option[List[String]]` -- directories from which file ingests may read
- `resolutionMode: Option[ResolutionMode]` -- `Static` (enumerate once) or `Dynamic` (check at runtime)

**Configuration Loading:**
PureConfig reads from HOCON sources (application.conf files, system properties) using `ConfigConvert` instances derived semi-automatically. The config is rooted under the `quine` key, with `allowUnknownKeys = true` at the top level so other keys (e.g., Pekko config) do not cause errors. Shapeless lenses (`webserverPortLens`, `webserverEnabledLens`) are used for CLI override application.

### Recipe System

Recipes are YAML/JSON documents that declaratively specify ingests and standing queries to set up on startup. Two versions exist:
- `RecipeV1` -- original format, interpreted by `RecipeInterpreter`
- `RecipeV2` -- newer format with V2 ingest/SQ types, interpreted by `RecipeInterpreterV2`

`RecipeLoader.getAndSubstituteAny` loads from file path, URL, or built-in recipe name, applies `$key=value` substitutions, and returns `Recipe.V1` or `Recipe.V2`. The recipe interpreter runs on a schedule to verify the declared resources are present.

### Persistence Version Management

The system tracks two version dimensions:
1. **Persistor data format version** (`PersistenceAgent.CurrentVersion`) -- for the underlying storage format
2. **Quine app state version** (`QuineApp.CurrentPersistenceVersion`, currently 1.2.0) -- for the metadata schemas

Version checking uses `syncVersion` on startup with an `isDataEmpty` check to distinguish fresh databases from incompatible ones. Migrations are run via `MigrationVersion` with explicit `MigrationApply` instances.

## Key Types and Structures

- `QuineApp` -- the God Object: 1738 lines, holds all application state, implements all state management traits
- `BaseApp` -- metadata persistence primitives (store/get/delete local and global metadata)
- `QuineConfig` -- full application configuration (product type)
- `CmdArgs` -- CLI argument model
- `Recipe` (`Recipe.V1 | Recipe.V2`) -- declarative startup configuration
- `IngestStreamWithControl[T]` -- ingest stream handle: config + metrics + valve + termination + close
- `UnifiedIngestConfiguration` -- `Either[V2IngestConfiguration, V1.IngestStreamConfiguration]` wrapper
- `OutputTarget` -- `OutputTarget.V1(definition, killSwitch) | OutputTarget.V2(definition, killSwitch)` for standing query output handles
- `GraphService` -- the graph (actor system, shards, master stream, persistor, dispatchers)
- `PersistenceBuilder` -- composable builder for persistence backends (pluggable per product)
- `StatusLines` -- startup logger that writes to both structured logger and stderr
- `CoordinatedShutdown` -- Pekko's phased shutdown mechanism

## Dependencies

### Internal (other stages/modules)
- **Graph core**: `GraphService`, `BaseGraph`, shard management, namespace management
- **Persistor**: `PrimePersistor`, `PersistenceAgent` -- metadata and state persistence
- **Cypher compiler**: `registerUserDefinedProcedure`, `CypherStandingWiretap`
- **Migrations**: `QuineMigrations`, `MigrationVersion`
- **API layer**: `QuineAppRoutes`, `V2OssRoutes`, `HealthAppRoutes`
- **Ingest**: `IngestSrcDef`, `IngestSource`, `QuineIngestSource`
- **Standing queries**: `StandingQueryResultOutput`, `ApiToStanding`

### External (JVM libraries)
- **Pekko Actor** (`org.apache.pekko:pekko-actor`): `ActorSystem`, `CoordinatedShutdown`, dispatchers
- **Pekko Stream** (`org.apache.pekko:pekko-stream`): `KillSwitches`, `Materializer`, stream combinators
- **Pekko HTTP** (`org.apache.pekko:pekko-http`): web server binding, routes, TLS
- **PureConfig** (`com.github.pureconfig`): HOCON config loading with compile-time derivation
- **scopt**: CLI argument parsing
- **Shapeless**: lenses for config override, coproduct handling
- **cats**: `Validated`, `ValidatedNel`, `Applicative`, `traverse`
- **circe**: JSON serialization for metadata persistence
- **logback/SLF4J**: structured logging
- **Dropwizard Metrics**: metrics registry
- **sslcontext-kickstart** (`nl.altindag:sslcontext-kickstart`): TLS factory for keystores/truststores

### Scala-Specific Idioms
- **Trait mixin composition (cake pattern)**: `QuineApp` mixes in 11+ traits to compose its capability. Each trait defines an interface and (in some cases) implementation. This is the deepest use of the cake pattern in the codebase.
- **`@volatile` + `synchronized` + `Await`**: the state management model uses JVM-level volatile reads, object monitor locks, and blocking futures. This is a JVM threading idiom that does not translate.
- **Lens-based config override**: Shapeless lenses (`webserverPortLens.set(...)`) for immutable config modification.
- **PureConfig semi-auto derivation**: `deriveConvert[T]` generates HOCON <-> case class converters at compile time.
- **`object Main extends App`**: Scala `App` trait makes the object body the main method. The entire startup is sequential code in the object initializer.
- **`blocking()` hint**: used around `synchronized` blocks to tell the thread pool this is a blocking operation.

## Essential vs. Incidental Complexity

### Essential (must port)
- **Startup sequence**: parse CLI args, load config, create graph, restore state, bind HTTP, register shutdown. This sequence is fundamental to any application.
- **Configuration model**: the set of configurable options (persistence backend, node limits, webserver bind, ID provider, etc.) represents real user-facing knobs.
- **State persistence and restoration**: ingest streams, standing queries, and UI configuration must survive restarts. The metadata key-value store pattern is sound.
- **Namespace management**: multi-tenant graph partitions with per-namespace state.
- **Migration framework**: schema evolution for persisted state.
- **Recipe system**: declarative startup configuration is a valuable user feature.
- **Graceful shutdown**: orderly teardown (sync metadata, stop ingests, flush graph, stop system).
- **File access policy**: security boundary for file-based ingest sources.

### Incidental (rethink for Roc)
- **QuineApp as a 1738-line God Object**: the single class holds all application state, mixes in 11+ traits, and implements all CRUD for all subsystems. This should be decomposed into separate modules (IngestManager, StandingQueryManager, UiConfigManager, etc.).
- **Dual V1/V2 ingest and SQ state**: `UnifiedIngestConfiguration` wrapping `Either[V2, V1]`, dual `storeStandingQueryOutputs1()` / `storeStandingQueryOutputs2()`. Port only V2.
- **`synchronizedFakeFuture`**: blocking inside synchronized blocks to simulate atomic state updates. Use an actor/channel pattern or STM in Roc.
- **`Await.result` throughout startup**: blocking the main thread for async operations. In Roc, structure startup as a sequence of `Task`s.
- **Shapeless lenses for config override**: simple record update in Roc.
- **PureConfig / HOCON configuration**: HOCON is a JVM-centric format. Consider YAML or TOML for Roc, or a simple custom config parser.
- **Pekko `CoordinatedShutdown` with named phases**: the phased shutdown framework is Pekko-specific. Implement a simple ordered shutdown list.
- **endpoints4s schema mixin**: `QuineApp` mixes in V1 schema traits (`V1.StandingQuerySchemas`, `V1.IngestSchemas`) solely for codec derivation context. Not needed without V1.
- **`StatusLines` dual-output logging**: a Quine-specific logging abstraction. Use standard structured logging.

## Roc Translation Notes

### Maps Naturally
- **Configuration as a record**: `QuineConfig` maps directly to a Roc record type. Config loading from a file (YAML/TOML) is straightforward.
- **CLI argument parsing**: scopt's model (`CmdArgs` case class) maps to any CLI parsing library pattern.
- **State as a value**: the various state maps (ingest streams, standing queries, UI config) can be held in a mutable reference or managed by an actor.
- **Metadata key-value persistence**: `storeGlobalMetaData(key, jsonBytes)` and `getGlobalMetaData(key)` is a simple KV store interface.
- **Shutdown sequence**: an ordered list of cleanup actions.
- **Recipe as declarative config**: YAML parsing into a typed recipe structure.

### Needs Different Approach
- **Actor system and dispatchers**: the startup creates a Pekko `ActorSystem` which provides the execution context for everything. Roc needs its own concurrency runtime (Tasks, platform threads, or an event loop).
- **Graph creation**: `GraphService(...)` is a complex async factory that creates shards, initializes persistors, and sets up the master stream. This will be a different initialization pattern in Roc.
- **Trait-based state composition**: `QuineApp` mixes in `IngestStreamState`, `StandingQueryStoreV1`, etc. In Roc, these become separate modules with their own state, composed via function arguments or a context record.
- **Blocking startup**: the `Await.result` pattern blocks the main thread. Roc should use `Task.await` or structured concurrency.
- **Persistence builder composition**: `PersistenceBuilder` uses case class composition with function fields to support product-specific persistence construction. In Roc, this would be a tagged union of configs plus a builder function.
- **JVM-specific TLS**: keystores, truststores, `SSLFactory`. Roc on native would use different TLS primitives (e.g., OpenSSL bindings).

### Open Questions
- **How to decompose QuineApp?** The God Object pattern is the biggest architectural concern. Should the port have an `AppState` record-of-modules, or separate manager actors/tasks?
- **What concurrency model for state management?** The current `synchronized + Await` model is crude. Options: single-threaded state actor, STM, or lock-free data structures.
- **Configuration format?** HOCON is JVM-specific. YAML is widely understood but verbose. TOML is simpler. What does Roc's ecosystem prefer?
- **How to handle the recipe system?** Recipes are YAML that drives API calls. Should the port support recipes natively, or treat them as external scripts that call the API?
- **Migration framework**: the current migration system is minimal (one migration exists). What level of schema migration support is needed from day one?
- **Telemetry**: should the port include the `ImproveQuine` telemetry system, or defer it?
