# REST API Surface

## What Happens Here

The REST API is how users interact with Quine at runtime -- creating ingest streams, registering standing queries, executing Cypher queries, inspecting node state, and managing the system. The API is served over HTTP (with optional TLS/mTLS) using Pekko HTTP, and has two parallel generations: V1 (endpoints4s-based) and V2 (Tapir-based). Both are served simultaneously; the `defaultApiVersion` config controls which the UI defaults to.

### API Endpoint Groups

The full API surface is organized into seven functional areas. Each exists in both V1 and V2:

**1. Administration** (`/api/v{1,2}/admin/...`)
- `GET /build-info` -- version, git commit, JVM info, persistence version
- `GET /config` -- full running configuration (with sensitive values masked)
- `GET /liveness` -- no-op 204 for process manager health checks
- `GET /readiness` -- 204 if graph is ready, 503 if not
- `GET /metrics` -- counters, timers, gauges from Dropwizard metrics registry
- `POST /shutdown` -- initiate graceful coordinated shutdown
- `GET /meta-data` -- raw persisted metadata key-value pairs
- `POST /shard-sizes` -- get/set in-memory node soft/hard limits per shard
- `POST /request-node-sleep/{id}` -- hint a node to go to sleep
- `GET /graph-hash-code` -- checksum of graph state at a point in time

**2. Ingest Streams** (`/api/v{1,2}/ingest/...` or `/api/v{1,2}/ingests/...`)
- `POST` -- create a named ingest stream (source + format + Cypher query)
- `GET` -- list all ingest streams (with status, metrics)
- `GET /{name}` -- get one ingest stream
- `DELETE /{name}` -- remove/stop an ingest stream
- `PUT /{name}/pause` -- pause
- `PUT /{name}/start` -- unpause
- V2 also returns structured `SuccessEnvelope` responses with proper HTTP status codes

**3. Standing Queries** (`/api/v{1,2}/query/standing/...` or `/api/v{1,2}/standing-queries/...`)
- `POST /{name}` -- register a standing query (pattern + outputs)
- `GET` -- list all registered standing queries with stats
- `GET /{name}` -- get one standing query
- `DELETE /{name}` -- cancel a standing query
- `POST /{name}/output/{outputName}` -- add an output to an existing SQ
- `DELETE /{name}/output/{outputName}` -- remove an output
- V2 adds `POST /propagate` to propagate an existing SQ across the graph

**4. Cypher Query Language** (`/api/v{1,2}/query/cypher/...`)
- `POST /cypher` -- execute a Cypher query, return tabular results (columns + rows)
- `POST /cypher/nodes` -- execute Cypher, return results as UI nodes
- `POST /cypher/edges` -- execute Cypher, return results as UI edges
- V2 adds `POST /analyze` for query cost analysis (readOnly, canContainAllNodeScan)

**5. Debug Node Operations** (`/api/v{1,2}/debug/...`)
- `GET /{id}` -- raw node data (properties + half-edges) at optional historical time
- `GET /{id}/edges` -- filtered half-edges on a node
- `PUT /{id}/edges` -- add a half-edge
- `DELETE /{id}/edges` -- remove a half-edge
- `PUT /{id}/properties/{key}` -- set a property
- `DELETE /{id}/properties/{key}` -- remove a property
- `POST /{id}/properties/{key}/merge` -- merge value into a property

**6. Graph Algorithms** (`/api/v{1,2}/algorithm/...`)
- `GET /walk` -- random walk from a node (for node2vec, etc.)
- `POST /walk/save-to-file` -- save walk results to file
- `POST /walk/save-to-s3` -- save walk results to S3
- Parameters: walk length, count, return parameter (p), in-out parameter (q), seed, on-node Cypher query

**7. UI Styling** (`/api/v{1,2}/query/...`)
- `GET/PUT /sample-queries` -- dropdown query suggestions in the UI
- `GET/PUT /node-appearances` -- how to style nodes visually (icon, color, label)
- `GET/PUT /quick-queries` -- right-click queries on nodes

**WebSocket Endpoints**
- `/api/v1/query/cypher/subscribe` -- streaming Cypher results via WebSocket (V1)
- `/api/v2/query/cypher/subscribe` -- streaming Cypher results via WebSocket (V2, Tapir)
- `/api/v1/ws/quine-pattern` -- language server protocol for QuinePattern (experimental, behind flag)

### V1 vs V2 Architecture

**V1 (endpoints4s):**
- Endpoint definitions in `quine-endpoints/` using `endpoints4s.algebra` traits
- Schemas defined with `endpoints4s.generic.JsonSchemas` + `@title`/`@docs` annotations
- Route implementations in `quine/app/routes/*RoutesImpl.scala` using `endpoints4s.pekkohttp.server`
- OpenAPI docs generated via `endpoints4s.openapi.Endpoints`
- Request/response types defined inline in the endpoint traits (e.g., `AdministrationRoutes`)
- Codec framework: endpoints4s schema-driven; JSON via ujson/circe

**V2 (Tapir):**
- Endpoint definitions in `quine/app/v2api/endpoints/V2*Endpoints.scala` using `sttp.tapir`
- Schemas defined with `sttp.tapir.Schema.derived` + `@title`/`@description` annotations
- Types re-defined as parallel `T*` case classes (e.g., `TQuineInfo` mirrors V1 `QuineInfo`)
- Business logic in `quine/app/v2api/definitions/QuineApiMethods.scala` (shared across products)
- Route generation via `PekkoHttpServerInterpreter` in `TapirRoutes`
- OpenAPI docs generated via `sttp.tapir.docs.openapi.OpenAPIDocsInterpreter`
- Structured error handling: `ErrorResponse` coproducts (`ServerError :+: BadRequest :+: NotFound :+: CNil`)
- Response wrapping: `SuccessEnvelope.Ok[A]`, `SuccessEnvelope.Created[A]`
- Codec framework: circe with `deriveConfiguredEncoder/Decoder`, unified discriminator config

**Cross-compilation:** Both `quine-endpoints` and `quine-endpoints2` are cross-compiled for JVM and Scala.js via SBT `crossProject(JVMPlatform, JSPlatform)`. This means the same endpoint and type definitions compile to both JVM bytecode (used by the server) and JavaScript (used by `quine-browser`, the bundled React UI). The shared definitions ensure the browser client and server agree on API shapes at compile time.

**Key Observation:** V1 and V2 define the same logical API but with completely independent type hierarchies, schema definitions, and codec derivation. The `QuineApiMethods` trait serves as the shared business logic layer that both versions call into.

### The `api/` Module and model-converters

The `api/` module (`com.thatdot.api.v2`) contains cross-product type definitions used by V2 endpoints:
- `V2EndpointDefinitions` -- base trait for all V2 endpoint definitions (ID codecs, time params, error handling)
- `SuccessEnvelope` -- standardized response wrappers (`Ok`, `Created`)
- `ErrorResponse` -- typed error responses (`BadRequest`, `NotFound`, `ServerError`)
- `TypeDiscriminatorConfig` / `TapirCirceUnifiedConfig` -- ensures Tapir schemas and circe codecs use matching discriminator field names
- `AwsCredentials`, `AwsRegion`, `RatesSummary` -- shared domain types
- `outputs/` -- output format types (`OutputFormat.JSON`, `OutputFormat.Protobuf`), destination step types
- `codec/` -- `SecretCodecs` for credential handling, `ThirdPartyCodecs`
- `YamlCodec` -- YAML request body support

The `quine-endpoints2/` module provides:
- `TapirCirceUnifiedConfig` -- single source of truth for discriminator/renaming config
- `TypeDiscriminatorConfig` -- ADT type discrimination settings
- `QueryWebSocketProtocol` -- WebSocket query protocol types

The `model-converters/` module (`com.thatdot.convert`) bridges between the three model layers:
- `Api2ToModel1` -- API V2 types to V1 route types (e.g., `api.v2.RatesSummary` -> `V1.RatesSummary`)
- `Model1ToApi2` -- V1 route types to API V2 types (reverse direction)
- `Api2ToOutputs2` -- API V2 output types to internal `outputs2` types (destination steps, output encoders)
- `Api2ToAws` -- API V2 AWS types to internal `aws.model` types

This three-layer conversion exists because the codebase has:
1. **V1 route types** (`com.thatdot.quine.routes.*`) -- original endpoint schemas
2. **V2 API types** (`com.thatdot.api.v2.*`) -- shared cross-product types
3. **Internal model types** -- `outputs2.*`, `aws.model.*`, etc.

## Key Types and Structures

### V1 Endpoint Type System
- `endpoints4s.algebra.Endpoints` -- abstract endpoint definition trait
- `endpoints4s.pekkohttp.server.Endpoints` -- concrete Pekko HTTP server mixin
- `endpoints4s.circe.JsonSchemas` -- circe-based codec derivation
- `QuineEndpoints` -- base trait adding ID segments, namespace params, atTime params
- Types: `IngestStreamConfiguration`, `StandingQueryDefinition`, `StandingQueryResultOutputUserDef`, `CypherQuery`, `CypherQueryResult`, `LiteralNode[Id]`, `UiNode[Id]`, `UiEdge[Id]`, `MetricsReport`

### V2 Endpoint Type System
- `V2EndpointDefinitions` -- base trait (ID codecs, time params, error utilities)
- `V2QuineEndpointDefinitions` -- Quine-specific additions (namespace resolution, appMethods)
- `TapirRoutes` -- abstract route class (OpenAPI generation, Pekko HTTP binding)
- `V2OssRoutes` -- OSS Quine route aggregator
- Types: `ApiIngest.Oss.QuineIngestConfiguration`, `StandingQuery.StandingQueryDefinition`, `StandingQuery.RegisteredStandingQuery`, `TCypherQuery`, `TCypherQueryResult`, `TLiteralNode[ID]`, `TMetricsReport`

### Endpoint Wiring Pattern (V2)
```
V2*Endpoints trait            -- defines Endpoint[_, IN, ERR, OUT, _] + serverLogic
  V2OssEndpointProvider trait -- aggregates all endpoint traits
    V2OssRoutes class         -- provides appMethods, builds ServerEndpoint list
      TapirRoutes             -- converts to Pekko HTTP Route, generates OpenAPI
```

### Endpoint Wiring Pattern (V1)
```
*Routes trait (e.g., AdministrationRoutes)  -- defines Endpoint[IN, OUT] abstractions
  *RoutesImpl trait (e.g., AdministrationRoutesImpl)  -- implements route logic
    QuineAppRoutes class  -- mixes in all *RoutesImpl traits, provides graph/app
      BaseAppRoutes       -- combines staticFilesRoute + apiRoute + openApiRoute
```

## Dependencies

### Internal (other stages/modules)
- **Graph core** (`quine-core`): `BaseGraph`, `GraphService`, `CypherOpsGraph`, `LiteralOpsGraph`, `AlgorithmGraph`, `StandingQueryOpsGraph` -- the graph operations the API calls into
- **Cypher compiler** (`quine-compiler`): query compilation, standing query pattern compilation
- **Persistor** (`quine-persistor`): `PersistenceAgent`, `PrimePersistor` -- metadata storage for app state
- **quine-endpoints** (`quine-endpoints/`): V1 endpoint definitions (trait-level schemas)
- **quine-endpoints2** (`quine-endpoints2/`): V2 shared config types
- **api module** (`api/`): V2 shared types, error handling, codecs
- **model-converters** (`model-converters/`): V1 <-> V2 <-> internal type bridges
- **Application state** (`QuineApp`, `BaseApp`): standing query management, ingest stream management, UI config state

### External (JVM libraries)
- **Pekko HTTP** (`org.apache.pekko:pekko-http`): HTTP server, routing DSL, WebSocket support, TLS/mTLS
- **endpoints4s** (`org.endpoints4s`): V1 endpoint algebra + Pekko HTTP server interpreter + OpenAPI generation
- **Tapir** (`com.softwaremill.sttp.tapir`): V2 endpoint definitions, Pekko HTTP server interpreter, OpenAPI docs
- **circe** (`io.circe`): JSON serialization/deserialization for both V1 and V2
- **Dropwizard Metrics** (`io.dropwizard.metrics`): counters, timers, gauges for the metrics endpoint
- **WebJars** (`org.webjars`): static asset serving for the UI
- **sttp-apispec** (`sttp.apispec`): OpenAPI spec model used by Tapir

### Scala-Specific Idioms
- **Cake pattern (trait mixin composition)**: `QuineAppRoutes` mixes in `QueryUiRoutesImpl with DebugRoutesImpl with AlgorithmRoutesImpl with ...` -- each trait provides a `*Routes: Route` val. This is the classic Scala "cake pattern" for dependency injection via self-types and trait linearization.
- **endpoints4s algebra/interpreter pattern**: Endpoint definitions are abstract in algebra traits, then mixed with concrete interpreters (server, client, OpenAPI) for different purposes. A single definition generates server routes, client code, and docs.
- **Shapeless coproducts for error types**: V2 uses `ServerError :+: BadRequest :+: NotFound :+: CNil` for typed union error responses, with `Inject` and `Basis` for lifting specific errors into the coproduct.
- **circe generic extras with configured derivation**: V2 types use `deriveConfiguredEncoder`/`deriveConfiguredDecoder` with implicit `Configuration` for discriminator field naming.

## Essential vs. Incidental Complexity

### Essential (must port)
- **The full API contract**: all 7 endpoint groups with their request/response shapes, HTTP methods, path patterns, query parameters, and status codes. This is the user-facing interface.
- **Structured error responses**: typed errors (bad request, not found, server error) with meaningful messages.
- **Content negotiation**: JSON and YAML request body support.
- **OpenAPI specification generation**: users rely on the interactive docs.
- **WebSocket streaming**: Cypher query subscription is a core interactive feature.
- **Health probes**: liveness and readiness endpoints for orchestration.
- **Namespace parameter**: optional namespace routing for multi-tenant graph partitions.
- **AtTime parameter**: historical query support (timestamp in millis).
- **TLS/mTLS support**: security requirements for production deployments.

### Incidental (rethink for Roc)
- **Dual V1/V2 endpoint stacks**: maintaining two parallel type hierarchies and codec systems for the same API is purely historical. Port only V2 semantics.
- **endpoints4s dependency entirely**: the V1 stack exists for backward compatibility. Not needed in a new port.
- **Cake pattern for route composition**: trait mixin for wiring routes is a Scala idiom that does not translate. Use module-level composition.
- **Shapeless coproduct error handling**: the `:+: CNil` pattern for typed error unions is Scala machinery. Use Roc's union types or tagged unions.
- **Three-layer model conversion**: `Api2ToModel1`, `Model1ToApi2`, `Api2ToOutputs2` exist because of the V1/V2 split. With a single API version, one model layer suffices.
- **`synchronizedFakeFuture` pattern**: blocking inside `synchronized` to fake atomic metadata updates is a concession to JVM threading. This needs a fundamentally different concurrency approach.
- **WebJars for static assets**: the bundled UI is a separate concern from the API; static file serving can be handled by any HTTP framework.

## Roc Translation Notes

### Maps Naturally
- **Endpoint definitions as data**: Tapir's approach of defining endpoints as values (not routes) maps well to Roc's data-oriented style. Endpoints can be records describing path, method, input/output types.
- **Structured error responses**: Roc's tagged unions naturally express `[Ok result, BadRequest String, NotFound String, ServerError String]`.
- **JSON serialization**: Roc's `json` package can handle encode/decode; the contract is JSON-in/JSON-out.
- **OpenAPI generation**: can be done as a function from endpoint definitions to an OpenAPI JSON value.
- **Request/response types as records**: `QuineInfo`, `MetricsReport`, `CypherQueryResult`, etc. are simple product types.

### Cross-Compilation Constraint Dissolves
- **JVM/JS cross-compilation is irrelevant:** The `quine-endpoints`/`quine-endpoints2` modules are cross-compiled for JVM and Scala.js so that the Scala server and the bundled browser client share type definitions at compile time. A native Roc server would not share type definitions with a JavaScript browser client in this way -- the browser would consume the API via its OpenAPI contract or a separately maintained TypeScript client, not via shared compiled source. The entire `crossProject` architecture is incidental to the Scala/JVM ecosystem and carries no obligation in the port.

### Needs Different Approach
- **HTTP server**: Roc has `roc-http` or `basic-web-server` but nothing as mature as Pekko HTTP. May need to build on a lower-level HTTP library or use platform interop. WebSocket support is a specific concern.
- **Streaming responses**: Cypher query subscription via WebSocket requires a streaming abstraction. Consider Roc's `Task`-based approach or server-sent events as an alternative.
- **Route composition**: instead of trait mixins, use a list of `Route` values or a `Router` that dispatches by path prefix. Each endpoint group becomes a module that returns a list of route handlers.
- **Middleware (CORS, HSTS, security headers)**: currently done via Pekko HTTP directives. Need explicit middleware composition in Roc.
- **Content negotiation (JSON vs YAML)**: V2 accepts YAML bodies. This could be a simple content-type check + parser selection rather than a framework feature.
- **mTLS**: SSL/TLS configuration via `SSLFactory` is JVM-specific (keystores, truststores). Roc on a native platform would use different TLS primitives.

### Open Questions
- **Which HTTP server library for Roc?** The API surface is moderately complex (7 endpoint groups, WebSockets, TLS). Need to evaluate available options.
- **Should the port serve OpenAPI docs?** Generating OpenAPI from endpoint definitions is valuable but requires either a generation step or a runtime introspection library.
- **WebSocket vs SSE for streaming queries?** WebSocket is used today but SSE is simpler and might suffice for the subscription use case.
- **How to handle the UI?** The bundled React UI is served as static assets. This could be a separate deployment concern rather than bundled into the Roc binary.
- **Authentication/authorization?** The OSS version has no auth, but the Enterprise version does. If the port aims to support Enterprise features later, the API layer should have extension points.
- **YAML support worth keeping?** It adds complexity for a minority use case. Could be deferred or dropped.
