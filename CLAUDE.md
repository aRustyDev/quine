# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Quine is a streaming graph interpreter written in Scala 2.13. It consumes streaming event data, builds a stateful graph, and runs live standing queries that trigger actions on pattern matches. It supports Cypher and Gremlin query languages and ingests from Kafka, Kinesis, SQS, files, and more.

## Build Commands

```bash
sbt compile              # Compile all projects
sbt test                 # Run all tests (excludes integration and license-required tests by default)
sbt fixall               # Reformat (scalafmt) and lint (scalafix) all source files
sbt quine/run            # Build and run Quine
sbt quine/assembly       # Build fat JAR

# Run a single test class
sbt "quine-core/testOnly com.thatdot.quine.graph.SomeTestClass"

# Run integration tests (normally excluded)
sbt "quine-core/Integration/test"

# Check formatting without fixing
sbt scalafmtCheckAll scalafmtSbtCheck
sbt "scalafixAll --check"
```

**Requirements:** JDK 17+, sbt, Yarn 0.22.0+ (for quine-browser frontend)

## Architecture

The codebase is ~19 SBT subprojects. Key modules:

- **quine** — Main application entry point (`QuineApp.scala`, `Main.scala`). API routes, recipe loading, config.
- **quine-core** — Core graph engine. Actor-based (Apache Pekko) with `NodeActor` per graph node, managed by `GraphShardActor`. Persistence abstracted behind `PrimePersistor`.
- **quine-language** — Cypher parser built with ANTLR4.
- **quine-cypher** — Compiles parsed Cypher AST into Quine graph operations.
- **quine-gremlin** — Gremlin query subset parser/interpreter.
- **quine-endpoints** / **quine-endpoints2** — V1 and V2 API definitions using Tapir (cross-compiled JVM/JS).
- **api**, **model-converters**, **data** — API types, model conversion, shared data structures.
- **quine-browser** — Web UI (Scala.js + Laminar + vis-network for graph visualization).
- **quine-rocksdb-persistor**, **quine-mapdb-persistor**, **quine-cassandra-persistor** — Persistence backends.
- **quine-serialization** — Protocol Buffers, Avro, MessagePack serialization.
- **outputs2** — Output destinations (Kafka, Kinesis, SNS, SQS).
- **aws** — AWS SDK integration.

## Code Style Rules

**Scalafmt** (v2.7.5): 120 max column, trailing commas always. Config in `.scalafmt.conf`.

**Scalafix** (`.scalafix.conf`):
- **Import ordering**: Java/Javax → Scala → Pekko → wildcard → com.thatdot
- **Prohibited auto-derivation** — these are enforced by scalafix and will fail CI:
  - `io.circe.generic.auto` → use `semiauto.derive(De|En)coder`
  - `sttp.tapir.generic.auto` → use explicit `Schema.derived`
  - `pureconfig.generic.auto` → use `semiauto.deriveConvert`

**Style conventions** (from `.scalafmt.conf`):
- Mark `case class`es and `case object`s `final` wherever possible
- Prefer `sealed abstract class` over `sealed trait`

**Compiler**: Targets Java 11 bytecode. `-Werror` is enabled on CI.

## Testing

- **Framework**: ScalaTest + ScalaCheck (MUnit for quine-language)
- Integration tests tagged with `com.thatdot.quine.test.tags.IntegrationTest` — excluded from default `test`, run via `Integration/test`
- License-required tests tagged with `com.thatdot.quine.test.tags.LicenseRequiredTest` — run via `LicenseTest/test`

## CI

GitHub Actions (`.github/workflows/ci.yml`): Java 21, runs `sbt test`, `quine/assembly`, `quine-docs/generateDocs`, scalafix check, scalafmt check. Caches Cassandra and Coursier dependencies.

## Key Conventions

- Dependencies are centrally managed in `project/Dependencies.scala`
- Common SBT settings live in `project/QuineSettings.scala`
- The package namespace is `com.thatdot.quine`
- The actor framework is Apache Pekko (not Akka) — imports are `org.apache.pekko`
