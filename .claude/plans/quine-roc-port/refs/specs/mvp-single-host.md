# MVP: Single-Host Quine-Roc

**Status:** Draft
**Date:** 2026-04-22
**Depends on:** Prototype (P1–P4, complete)
**Goal:** A deployable single-host graph engine that persists to disk, accepts streaming input, answers Cypher queries, and runs standing queries — proven on Raspberry Pi CM5.

---

## Overview

The prototype proves the pipeline works: JSONL → graph → SQ → API in Docker. The MVP closes the gaps that prevent real use: data survives restarts, users can query with Cypher instead of raw API calls, and input can stream continuously.

### Tiers

| Tier | Items | Scope |
|------|-------|-------|
| **Must-Have** | Disk persistence, Cypher read-only, stdin ingest, GetNodeState refactor, tech debt D1–D3 | Full spec, beads epics |
| **Should-Have** | SQ propagation at wake, graceful shutdown, Figment config | Draft spec, beads epics |
| **Nice-to-Have** | Multi-node clustering, WebSocket SQ, Web UI, output sinks, auth/TLS | Description only |

---

## Must-Have

### M1: Disk Persistence (redb)

#### Problem

All graph state lives in an in-memory HashMap. Restarting the process loses everything.

#### Decision

**redb** — pure Rust embedded KV store. ACID transactions, zero native dependencies, trivial cross-compilation to arm64 (RPi CM5). See ADR for redb vs sled vs RocksDB evaluation.

#### Architecture

The persistence pool thread (`persistence_io.rs`) currently holds a `HashMap<Vec<u8>, Vec<u8>>`. Replace with a redb `Database`:

```
persistence_io.rs (current):
  HashMap<Vec<u8>, Vec<u8>>     ← in-memory, lost on restart

persistence_io.rs (MVP):
  redb::Database                ← file-backed, ACID, survives restart
    TABLE: snapshots            ← key: QuineId bytes, value: snapshot bytes
```

**Wire format unchanged.** The snapshot bytes produced by `Codec.encode_node_snapshot` / `decode_node_snapshot` are stored as-is in redb. The Roc codec is the source of truth for serialization — redb is a dumb key-value store.

#### Changes

**Rust side:**

- `Cargo.toml`: Add `redb = "2"` (~200KB, pure Rust)
- `persistence_io.rs`:
  - Replace `HashMap` with `redb::Database`
  - `PersistSnapshot`: open write transaction, insert key→value, commit
  - `LoadSnapshot`: open read transaction, get key, return bytes or "not found"
  - Database file path from config (default: `./quine-data/snapshots.redb`)
- `config.rs`: Add `data_dir: PathBuf` (default `./quine-data/`)
- `main.rs`: Create data directory at startup if it doesn't exist

**Roc side:** No changes. Snapshot encoding/decoding already works.

**Docker:**
- Add `VOLUME /data` to Dockerfile
- docker-compose: mount `./data:/data` and set `--data-dir /data`

#### Data Model

Single redb table:

| Table | Key | Value |
|-------|-----|-------|
| `snapshots` | `[u8; 16]` (QuineId raw bytes) | `Vec<u8>` (NodeSnapshot encoded by Roc Codec) |

No secondary indexes needed for MVP. The persistence pool only does point lookups (load by QuineId) and point writes (store by QuineId).

#### Recovery

On startup:
1. Open existing redb file (or create new)
2. No eager loading — nodes are loaded on demand when messages arrive (existing LoadSnapshot flow)
3. redb handles crash recovery internally (WAL-based)

#### Testing

- Unit test: write snapshot → close DB → reopen → read snapshot → bytes match
- Integration test: ingest data → restart container → query node → properties preserved
- E2E: extend `run.sh` with a restart-and-verify step

#### Open question (deferred to research issue qr-u60)

Whether to use one redb file per shard or a single shared file. MVP uses a single shared file (simplest). The research issue evaluates the write contention implications.

---

### M2: Cypher Read-Only Subset

#### Problem

Users interact with the graph via raw REST API and JSON payloads. No query language.

#### Scope

Read-only MATCH + WHERE + RETURN. No mutations (CREATE, SET, DELETE). No aggregations (COUNT, SUM). No OPTIONAL MATCH, UNION, or subqueries.

#### Supported Grammar

```
query       := MATCH pattern (WHERE predicate)? RETURN return_items
pattern     := node_pattern (edge_pattern node_pattern)*
node_pattern := '(' alias (':' label)? ('{' prop_map '}')? ')'
edge_pattern := '-[' alias? (':' edge_type)? ']->' | '<-[' ... ']-' | '-[' ... ']-'
prop_map    := key ':' value (',' key ':' value)*
predicate   := expr (AND expr)* | expr (OR expr)*
expr        := alias '.' prop op value | alias '.' prop IS NULL | alias '.' prop IS NOT NULL
op          := '=' | '<>' | '<' | '>' | '<=' | '>='
return_items := return_item (',' return_item)*
return_item := alias | alias '.' prop (AS name)?
value       := string_lit | integer_lit | float_lit | boolean_lit | NULL
```

#### Examples

```cypher
-- Single node lookup by property
MATCH (n) WHERE n.name = "Alice" RETURN n

-- Node with label constraint
MATCH (n:Person) WHERE n.age > 25 RETURN n.name, n.age

-- Single hop traversal
MATCH (a)-[:KNOWS]->(b) RETURN a.name, b.name

-- Filtered traversal
MATCH (a)-[:KNOWS]->(b) WHERE a.name = "Alice" RETURN b

-- Multi-hop (2 hops)
MATCH (a)-[:KNOWS]->(b)-[:FOLLOWS]->(c) RETURN a.name, c.name
```

#### Architecture

```
REST API                    Cypher Engine                   Shard Workers
─────────                   ─────────────                   ─────────────
POST /api/v1/query    →     parse(cypher_str)         
  { "query": "..." }        → CypherAST                
                             plan(ast)                 
                             → QueryPlan (node lookups, 
                               traversals, filters)    
                             execute(plan, shard_tx)   →   GetNodeState / GetEdges
                             ← collect results         ←   Reply payloads
                             format(results)           
  ← JSON response            → Vec<Row>               
```

**Parser:** Hand-rolled recursive descent in Rust. Cypher's grammar for the read-only subset is small enough that a parser combinator or hand-written parser is simpler than ANTLR/pest. The Scala Quine uses ANTLR4, but for this subset (~10 grammar rules) a hand-rolled parser is appropriate.

**Planner:** Converts CypherAST to a QueryPlan — a sequence of operations:
- `ScanByProperty { prop, constraint }` — find nodes matching a property (requires iterating; no index in MVP)
- `GetNode { id }` — fetch a specific node
- `Traverse { from, edge_type, direction }` — follow edges from a set of nodes
- `Filter { predicate }` — filter result set
- `Project { columns }` — select return columns

**Executor:** Walks the QueryPlan, issuing GetNodeState/GetEdges commands to shards via the existing request-response mechanism (oneshot channels + `roc_fx_reply`).

**MVP limitation:** No index on properties. `MATCH (n) WHERE n.name = "Alice"` must scan all nodes or use a known node_id hint. For MVP, the `/query` endpoint accepts an optional `node_ids` hint parameter to scope the scan. Full property indexing is a future phase.

#### New Files

- `platform/src/cypher/mod.rs` — module root
- `platform/src/cypher/lexer.rs` — tokenizer
- `platform/src/cypher/parser.rs` — recursive descent → CypherAST
- `platform/src/cypher/planner.rs` — AST → QueryPlan
- `platform/src/cypher/executor.rs` — QueryPlan → results via shard communication
- `platform/src/api/query.rs` — POST /api/v1/query endpoint

#### API

**POST /api/v1/query**

Request:
```json
{
  "query": "MATCH (n) WHERE n.name = \"Alice\" RETURN n",
  "node_ids": ["alice"]
}
```

Response (200):
```json
{
  "columns": ["n"],
  "rows": [
    { "n": { "id": "alice", "properties": { "name": "Alice", "age": 30 } } }
  ],
  "took_ms": 12
}
```

Errors: 400 for parse errors (with position), 504 for timeout.

#### Testing

- Parser unit tests: valid queries parse, invalid queries produce clear errors
- Planner unit tests: AST → expected QueryPlan
- Integration test: ingest test data → run Cypher queries → verify results

---

### M3: Stdin Streaming Ingest

#### Problem

Ingest only works from files. No way to pipe continuous streaming data into the graph.

#### Design

Add `--ingest stdin` CLI flag. When set, the platform reads JSONL from stdin line by line, using the existing JSONL parser and shard routing from `ingest.rs`.

#### Changes

- `config.rs`: Add `ingest_stdin: bool` flag
- `main.rs`: After shard workers start, if `--ingest stdin`, spawn an ingest task reading from `tokio::io::stdin()`
- `ingest.rs`: Extract the per-line parse+route logic into a shared function usable by both file ingest and stdin ingest
- Register the stdin ingest job in `IngestJobRegistry` as `"stdin"` with status `Running`

#### Behavior

- Reads one JSONL line at a time from stdin
- Same backpressure behavior as file ingest (retry on channel full)
- On EOF (stdin closed): status transitions to `Complete`
- On parse error: increment `records_failed`, log warning, continue
- `DELETE /api/v1/ingest/stdin` closes stdin reader (cancellation)
- Composable: `tail -f events.jsonl | quine-roc --ingest stdin --shards 4`

#### Testing

- Unit test: pipe 8 lines via stdin, verify all 8 processed
- E2E: `echo '...' | docker run quine-roc --ingest stdin` completes

---

### M4: GetProps → GetNodeState Refactor

#### Problem

`GET /nodes/:id` only returns properties (no edges). This is technical debt — the endpoint should return the full node state.

#### Design

**Roc side:**
- Add `NodeState` variant to `ReplyPayload`: `NodeState { properties : Dict Str PropertyValue, edges : Dict Str (List HalfEdge) }`
- Change `GetProps` handler in Dispatch.roc to return `NodeState` instead of `Props`
- `encode_reply_payload` for `NodeState`: `[prop_count][props...][edge_count][edges...]` (same wire format, but with actual edges)
- Keep `GetEdges` as-is for edge-only queries

**Rust side:**
- `decode_node_reply` already reads both sections — just needs to work with non-zero edge counts (already does)
- Rename `TAG_GET_PROPS` → `TAG_GET_NODE_STATE` for clarity

**No wire format change.** The reply format `[props][edges]` is already what the Rust decoder expects. We're just filling in the edges section instead of sending 0.

#### Testing

- Dispatch.roc test: GetProps returns both properties and edges
- E2E: `GET /nodes/alice` returns `{ properties: { name: "Alice" }, edges: [{ type: "KNOWS", ... }] }`

---

### M5: Tech Debt Fixes (D1–D3)

#### D1: reply_to=0 Semantic Overload (qr-1hf)

**Fix:** Add `is_reciprocal: Bool` field to AddEdge and RemoveEdge LiteralCommand variants. The reciprocal guard in Dispatch.roc checks `is_reciprocal` instead of `reply_to == 0`. Ingest sends `reply_to: 0, is_reciprocal: Bool.false`. Reciprocal effects send `reply_to: 0, is_reciprocal: Bool.true`.

Wire format: Add 1 byte after the existing edge encoding for AddEdge/RemoveEdge commands. Rust codec.rs and Roc Codec.roc both updated.

#### D2: Missing PropertyValue Tags (qr-prr)

**Fix:** Add handlers for tag 0x07 (Serialized → return base64 string) and 0x08 (Id → return hex string) in `decode_quine_value` in nodes.rs. Also add 0x09 (List) and 0x0A (Map) stubs that return `null` with a log warning, so future Roc encoding doesn't silently break the decoder.

#### D3: Silent Broadcast Failures (qr-xuo)

**Fix:** `broadcast_to_shards` returns `(u32, u32)` — (succeeded, failed). `create_sq` handler checks: if 0 succeeded, return 503. If partial, include `"shards_registered": N` in the 201 response. `cancel_sq` same pattern.

---

## Should-Have (Draft)

### S1: SQ Result Propagation at Wake Time

#### Problem

Standing queries register on shards but nodes woken by ingest don't have SQ subscriptions installed. Results only propagate if the SQ registration broadcast happens to arrive after the node is awake but before the mutation.

#### Design

In `ShardState.complete_node_wake`, after transitioning a node from `Waking` to `Awake`, automatically install all subscriptions from `running_queries`:

```
complete_node_wake(state, qid, snapshot, now):
    ... existing wake logic ...
    # Install all running SQ subscriptions on the newly awake node
    for (sq_id, running_query) in state.running_queries:
        dispatch CreateSqSubscription to the node
    # Then replay queued messages (which may trigger SQ evaluation)
```

This ensures every awake node always has the current set of SQ subscriptions, regardless of message ordering.

#### Impact

- SQ results flow correctly for any ingest ordering
- No post-ingest sweep needed
- Slight overhead at wake time (one CreateSqSubscription per running query per woken node) — negligible for typical SQ counts

---

### S2: Graceful Shutdown

#### Problem

SIGTERM kills immediately. In-flight messages lost, snapshots not flushed (critical once redb lands).

#### Design

1. Catch SIGTERM/SIGINT via `tokio::signal`
2. Set a global `AtomicBool` shutdown flag
3. Stop accepting new ingest jobs, cancel running ingests
4. Stop LRU timers
5. For each shard: send a `Shutdown` command, shard worker drains remaining messages, persists all awake nodes, then exits
6. Close redb database
7. Exit 0

**Timeout:** 30 seconds. If shards don't drain in time, log warning and force-exit.

**New channel message:** `TAG_SHUTDOWN = 0xFD` — shard worker recognizes this, enters drain mode.

---

### S3: Configuration via Figment

#### Problem

CLI flags only. No config file, no env var support.

#### Design

Use the `figment` crate with TOML, YAML, and env providers:

```rust
use figment::{Figment, providers::{Format, Toml, Yaml, Env, Serialized}};

let config: PlatformConfig = Figment::new()
    .merge(Serialized::defaults(PlatformConfig::default()))
    .merge(Toml::file("quine-roc.toml"))
    .merge(Yaml::file("quine-roc.yaml"))
    .merge(Env::prefixed("QUINE_"))
    .merge(Serialized::globals(cli_overrides))
    .extract()?;
```

**Priority (12-factor):** CLI args > env vars (`QUINE_*`) > config file (TOML or YAML) > defaults.

**Config structure:**
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

**Roc integration:** `PlatformConfig` values are passed to Roc via `init_shard!` parameters. This fixes D8 (hardcoded `shard_count = 4` in graph-app.roc) — the shard count comes from the platform config.

**Dependencies:** `figment = { version = "0.10", features = ["toml", "yaml", "env"] }`

---

## Nice-to-Have (Draft)

### N1: Multi-Node Clustering (gRPC)

Distribute shards across multiple hosts. Each host runs a subset of shards; a routing layer forwards messages to the correct host based on QuineId → shard → host mapping.

**Architecture:** gRPC service (via `tonic`, already tokio-native) with two RPC methods:
- `DispatchMessage(shard_id, envelope_bytes)` — forward a shard message to a remote host
- `QueryNode(quine_id, command_bytes)` → reply bytes — request-response across hosts

**Cluster membership:** Static config for MVP clustering (list of host:port in config file). Dynamic membership (gossip, etcd, Consul) deferred.

**Shard assignment:** Hash-based. `shard_id % num_hosts` determines which host owns a shard. Rebalancing on host add/remove requires shard migration (snapshot transfer).

**Key challenge:** Cross-host request-response. The current `PendingRequests` oneshot pattern works within a process. For cross-host, the gRPC client sends the request and awaits the gRPC response, which carries the reply payload. The owning host's shard processes the command, `roc_fx_reply` sends the reply to a local gRPC response channel instead of the HTTP oneshot.

**Depends on:** Disk persistence (redb) for shard migration. Graceful shutdown for clean handoff.

**Target:** RPi CM5 cluster — 20 nodes, each running 1-2 shards. ~80 shards total for the personal deployment.

### N2: WebSocket Streaming SQ Results

Replace the poll-based `GET /standing-queries` result draining with a push-based WebSocket stream.

**Architecture:** New endpoint `GET /api/v1/standing-queries/:id/stream` upgrades to WebSocket. The server subscribes to the SQ result channel, filters by query_id, and pushes results as JSON frames.

**Backpressure:** If the WebSocket client falls behind, buffer up to N results (configurable, default 1000). If buffer fills, oldest results are dropped and a `"dropped": N` notification is sent.

**Protocol:**
```json
// Server → Client (result)
{ "type": "result", "is_positive_match": true, "data": { "n": "Alice" } }

// Server → Client (heartbeat, every 30s)
{ "type": "heartbeat", "results_emitted": 847 }

// Client → Server (cancel)
{ "type": "cancel" }
```

**Dependencies:** axum has built-in WebSocket support via `axum::extract::ws`. No additional crates needed.

**Depends on:** SQ result propagation (S1) working correctly.

### N3: Web UI

Browser-based graph visualization and query interface, similar to Quine's existing web UI but rebuilt for the Roc port.

**Components:**
- **Graph visualizer** — Interactive node-link diagram (vis-network or d3-force). Click a node to inspect properties/edges. Drag to rearrange. Zoom/pan.
- **Cypher query console** — Text editor with syntax highlighting, query history, tabular result display. Submit queries via `POST /api/v1/query`.
- **SQ dashboard** — List running standing queries, result counts, live result stream (via WebSocket N2). Register new SQs via Cypher (depends on deferred qr-c3m).
- **Ingest monitor** — Active ingest jobs, records processed, throughput chart.

**Tech stack:** Static SPA (Vite + TypeScript + vis-network). Served from the Rust binary as embedded static assets (`rust-embed` or `include_dir`). No separate frontend server.

**Depends on:** Cypher (M2), WebSocket SQ streaming (N2).

### N4: Output Sinks

Publish standing query results to external systems. Pattern: a sink subscribes to SQ results by query_id and forwards each result to an external destination.

**Sink types (ordered by priority):**
1. **Kafka producer** — publish SQ results as JSON messages to a Kafka topic
2. **Kinesis producer** — publish to AWS Kinesis stream
3. **Webhook** — POST each result to a configurable URL
4. **File** — append JSONL to a file (log-style output)

**Architecture:** Sink registry in `AppState`, similar to `IngestJobRegistry`. Each sink runs as a tokio task that reads from a per-sink bounded channel. SQ result routing: when `emit_sq_result!` fires, check if any sinks subscribe to that query_id, clone the result bytes to each subscriber's channel.

**Depends on:** SQ result propagation (S1).

### N5: Auth / TLS

Secure the REST API for production deployments.

**TLS:** `axum-server` with `rustls` for HTTPS. Config: `tls.cert_path`, `tls.key_path` in config file. No TLS by default (local/Docker use).

**Auth:** Bearer token authentication. Config: `auth.tokens = ["token1", "token2"]`. Middleware checks `Authorization: Bearer <token>` header. No token = 401. Simple but sufficient for edge deployments behind a firewall.

---

## Dependency Graph

```
Must-Have:
  M1 Disk Persistence ──────────────────────┐
  M2 Cypher Read-Only ──┐                   │
  M3 Stdin Ingest       │ (independent)     │
  M4 GetNodeState ──────┤                   │
  M5 Tech Debt D1-D3 ───┘                   │
                                             │
Should-Have:                                 │
  S1 SQ at Wake ──── (independent)          │
  S2 Graceful Shutdown ──── depends on ──── M1
  S3 Figment Config ──── (independent, fixes D8)
                                             │
Nice-to-Have:                                │
  N1 Clustering ──── depends on ──── M1, S2 │
  N2 WebSocket SQ ──── depends on ──── S1   │
  N3 Web UI ──── depends on ──── M2, N2     │
  N4 Output Sinks ──── depends on ──── S1   │
  N5 Auth/TLS ──── (independent)            │
```

---

## Build Order (Recommended)

**Phase A (foundation):** M5 (tech debt), M4 (GetNodeState), S3 (Figment config)
— Clean up the prototype before building on it. These are small, independent, and reduce risk for later phases.

**Phase B (persistence):** M1 (redb)
— Unlocks restart survival. Depends on clean codec (M5/D2 fixes value tags).

**Phase C (query + ingest):** M2 (Cypher), M3 (stdin ingest)
— Independent of each other. Can be parallelized.

**Phase D (reliability):** S1 (SQ at wake), S2 (graceful shutdown)
— S2 depends on M1 (need something to flush). S1 is independent.
