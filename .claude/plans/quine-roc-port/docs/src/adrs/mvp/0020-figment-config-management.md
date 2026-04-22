# ADR-020: Figment for Configuration Management

**Status:** Accepted
**Date:** 2026-04-22
**Context:** The platform uses hand-rolled CLI argument parsing with no
support for config files or environment variables. MVP needs a config
system that supports Docker deployments (env vars), local development
(config files), and CI overrides (CLI args).

**Related:** MVP spec `refs/specs/mvp-single-host.md` (S3), tech debt D8
(hardcoded shard_count=4 in graph-app.roc).

## Decision

Use **Figment** with TOML, YAML, and env providers. 12-factor app priority
chain:

```
CLI arguments (highest)  →  QUINE_* env vars  →  config file  →  defaults (lowest)
```

## Architecture

```rust
let config: PlatformConfig = Figment::new()
    .merge(Serialized::defaults(PlatformConfig::default()))
    .merge(Toml::file("quine-roc.toml"))
    .merge(Yaml::file("quine-roc.yaml"))
    .merge(Env::prefixed("QUINE_"))
    .merge(Serialized::globals(cli_overrides))
    .extract()?;
```

Config is read **only in Rust**. The Roc graph engine remains pure — it
receives config values from the host at `init_shard!` time. This maintains
the Roc/Rust boundary: Roc owns graph logic, Rust owns I/O and config.

### Config File Format

Both TOML and YAML are supported. Figment detects format from the file
extension. If both `quine-roc.toml` and `quine-roc.yaml` exist, YAML
wins (merged second).

```toml
[server]
port = 8080
shards = 4
channel_capacity = 4096

[persistence]
data_dir = "./quine-data"

[timers]
lru_check_interval_ms = 10000
shutdown_timeout_ms = 30000

[ingest]
stdin = false
```

### Environment Variables

Prefixed with `QUINE_`, nested with `_`:

```
QUINE_SERVER_PORT=8080
QUINE_SERVER_SHARDS=4
QUINE_PERSISTENCE_DATA_DIR=/data
QUINE_INGEST_STDIN=true
```

## Alternatives Considered

### A) Keep CLI-only, add env vars manually

No new dependency. But duplicates Figment's merge logic by hand, no config
file support, and every new config field requires updating the arg parser.

### B) clap + config crate

clap for CLI, the `config` crate for file + env merging. Two dependencies
instead of one. clap adds ~300KB for derive macros. Figment handles all
four sources (defaults, file, env, CLI overrides) in a single fluent API.

### C) Figment (chosen)

Single crate, ~50KB with toml+yaml+env features. Handles the full merge
chain. Type-safe extraction into PlatformConfig via serde Deserialize.
Native support for nested config keys and env var mapping.

## Rationale

Figment is the Rust-idiomatic choice for layered config. It's small, does
exactly what we need, and the 12-factor priority chain is expressed
declaratively (merge order = priority order). Supporting both TOML and YAML
costs one extra feature flag and lets users pick their preference.

## Consequences

- Replaces `parse_config()` in main.rs with Figment extraction.
- `PlatformConfig` struct gets `#[derive(Deserialize)]` and gains new
  fields (data_dir, shutdown_timeout_ms, ingest.stdin).
- The shard_count hardcoded in graph-app.roc (D8) is fixed by passing the
  config value through `init_shard!`. The Roc platform's `init_shard!`
  signature doesn't change (still takes `U32` shard_id), but graph-app.roc
  will need a way to receive the total shard count. Options: add a second
  parameter to `init_shard!`, or add a new platform function
  `shard_count! : {} => U32`.
- Docker: config via env vars (`-e QUINE_SERVER_SHARDS=4`) or mounted
  config file (`-v ./config.toml:/etc/quine-roc.toml`).
