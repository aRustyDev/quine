# Prototype: Single-Host Multi-Threaded Quine-Roc

**Status:** Draft
**Date:** 2026-04-21
**Depends on:** Phase 1 (graph model), Phase 2 (persistence interfaces), Phase 3a (custom platform), Phase 3b (graph structure), Phase 4 (standing queries)
**Goal:** A running single-host, multi-threaded prototype that ingests JSONL, builds a graph, evaluates standing queries, and exposes results via REST API — proven end-to-end in Docker.

---

## Overview

Phases 1–4 built the pure graph engine: types, persistence interfaces, shard dispatch,
standing query evaluation, and a Rust/tokio host platform shell. But the platform binary
doesn't fully build (missing modules), nodes can't actually persist (empty snapshot bytes),
there's no way to feed data in, and no way to query results out.

This spec covers the four work phases needed to produce a runnable prototype:

1. **P1: Platform Completion** — fill missing Rust modules, implement NodeSnapshot serialization
2. **P2: JSONL Ingest** — file-based ingest pipeline turning JSON lines into graph mutations
3. **P3: REST API** — 10 axum endpoints for ingest, standing queries, node inspection, health
4. **P4: Docker & E2E** — containerized build, docker-compose test topology, E2E test script

### What this prototype demonstrates

- JSONL file → graph mutations → standing query match → API-visible results
- Multi-threaded shard-per-thread architecture with crossbeam channels
- LRU eviction with in-memory snapshot persistence (sleep/wake cycle)
- Standing query registration, evaluation, result delivery, and cancellation
- Backpressure from full shard channels slowing ingest

### What this prototype does NOT include

- Cypher or any query language (SQs registered as MVSQ AST JSON) — Phase 5
- Kafka, Kinesis, SQS, or any streaming ingest — Phase 6 extension
- Webhook/Kafka/SNS output sinks — Phase 6 extension
- Disk-backed persistence (RocksDB/Cassandra) — data is in-memory, lost on restart
- Multi-node clustering or gRPC inter-node — future phase
- Authentication, TLS, rate limiting — future phase

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    REST API (axum)                        │
│  POST/GET/DELETE /ingest    POST/GET/DELETE /standing-q   │
│  GET /nodes/:id             GET /health                  │
└────────────────────────┬─────────────────────────────────┘
                         │ shared state (Arc)
┌────────────────────────▼─────────────────────────────────┐
│                  Rust Platform Host                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │ ingest   │  │ persist  │  │  timer   │  │ channels │ │
│  │ jobs     │  │ io pool  │  │ (tokio)  │  │ registry │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘ │
│       │              │             │              │       │
│  ┌────▼──────────────▼─────────────▼──────────────▼─────┐ │
│  │              Shard Worker Threads                     │ │
│  │  shard-0    shard-1    shard-2    shard-3             │ │
│  └──────────────────────┬───────────────────────────────┘ │
└─────────────────────────┼────────────────────────────────┘
                          │ roc_fx_* host calls
┌─────────────────────────▼────────────────────────────────┐
│                 Roc Graph Engine                          │
│  ShardState → Dispatch → SQ eval → Effects               │
│  graph-app.roc (effect interpreter)                      │
└──────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Ingest:** REST API or file reader produces JSONL lines → parsed into `(QuineId, NodeMessage)` → encoded as shard envelope → sent to owning shard's channel
2. **Dispatch:** Shard worker receives message → calls Roc `handle_message!` → ShardState dispatches to node → LiteralCommand executed → SQ events derived → SQ states updated → effects produced
3. **Effects:** `drain_effects!` executes each effect — `SendToNode` routes cross-shard, `EmitSqResult` sends to SQ result channel, `Persist` stores snapshot
4. **Results:** SQ results accumulate in a bounded channel → REST API exposes them via standing-queries endpoints
5. **Persistence:** On LRU eviction, `begin_sleep` serializes NodeSnapshot → `persist_async!` stores in HashMap → on wake, `LoadSnapshot` retrieves → `complete_wake` restores state

---

## Phase P1: Platform Completion

### Problem

The Rust platform binary references two modules that don't exist (`persistence_io`, `timer`), and NodeSnapshot serialization is stubbed (empty bytes). The platform compiles with errors and can't run.

### persistence_io.rs

**Responsibilities:**
- Receive `PersistCommand` from any shard via a bounded crossbeam channel
- Store snapshots in an in-memory `HashMap<Vec<u8>, Vec<u8>>` (QuineId bytes → snapshot bytes)
- Handle two command types:
  - `PersistSnapshot { request_id, shard_id, payload }` — parse QuineId from payload, store snapshot bytes
  - `LoadSnapshot { request_id, shard_id, payload }` — parse QuineId, look up snapshot, send result back to the requesting shard's channel as `TAG_PERSIST_RESULT`

**Wire format** (already defined in graph-app.roc `encode_persist_command`):
- PersistSnapshot: `[0x01][id_len:U16LE][id_bytes...][snapshot_bytes...]`
- LoadSnapshot: `[0x02][id_len:U16LE][id_bytes...]`

**Persist result format** (sent back to shard as `TAG_PERSIST_RESULT` message):
- Found: `[TAG_PERSIST_RESULT][0x01][id_len:U16LE][id_bytes...][snapshot_len:U32LE][snapshot_bytes...]`
- Not found: `[TAG_PERSIST_RESULT][0x00][id_len:U16LE][id_bytes...]`

**Threading:** Runs on the existing tokio persistence runtime thread. Uses `crossbeam_channel::Receiver` to receive commands, processes them synchronentially on that thread.

**Startup integration:** `main.rs` already has the persistence runtime thread scaffolded — `start_persistence_pool` needs to be implemented to return the command sender.

### timer.rs

**Responsibilities:**
- For each shard, spawn a tokio interval task
- Each tick sends `[TAG_TIMER, 0x00]` (CheckLru) to the shard's channel via the channel registry
- Interval configured by `PlatformConfig.lru_check_interval_ms` (default 10_000ms)

**API:**
```rust
pub fn start_lru_timers(
    senders: Vec<crossbeam_channel::Sender<ShardMsg>>,
    interval_ms: u64,
) -> tokio::runtime::Runtime
```

Returns a single-threaded tokio runtime with one interval task per shard.

### NodeSnapshot Serialization (Roc)

**New codec functions in `Codec.roc`:**

```
encode_node_snapshot : NodeSnapshot -> List U8
decode_node_snapshot : List U8, U64 -> Result { snapshot : NodeSnapshot, next : U64 } [OutOfBounds, ...]
```

**Encoding format:**
```
[prop_count:U32LE]
  repeated: [key_len:U16LE][key_bytes...][value_bytes (PropertyValue encoding)]
[edge_count:U32LE]
  repeated: [half_edge_bytes (HalfEdge encoding)]
[time_tag:U8][time_value:U64LE]  (0x00=NotSet, 0x01=AtTime)
[sq_count:U32LE]
  repeated: [global_id:U128LE][part_id:U64LE][state_len:U32LE][state_bytes...]
```

PropertyValue and HalfEdge encoding already exist in Codec.roc. SqPartState encoding exists in SqStateCodec.roc. This composes them.

**Wiring:**
- `SleepWake.begin_sleep`: change `snapshot_bytes: []` to `snapshot_bytes: Codec.encode_node_snapshot(create_snapshot(state))`
- `SleepWake.complete_wake`: decode the persist result payload into a NodeSnapshot, pass to existing restoration logic
- `graph-app.roc` `handle_message!`: handle `TAG_PERSIST_RESULT` by decoding the result and calling a new `ShardState.complete_node_wake` function

### Deliverables

- `platform/src/persistence_io.rs` — in-memory persistence pool
- `platform/src/timer.rs` — LRU timer tasks
- `encode_node_snapshot` / `decode_node_snapshot` in Codec.roc
- `begin_sleep` wired to encode real snapshots
- Persist result handling in graph-app.roc
- `cargo build` succeeds, platform binary starts and runs

---

## Phase P2: JSONL Ingest Pipeline

### Problem

There's no way to feed data into the graph. The only entry point is raw shard envelope bytes on the channel.

### JSONL Format

One JSON object per line. Each object is a graph mutation:

```json
{"type": "set_prop", "node_id": "alice", "key": "name", "value": "Alice"}
{"type": "set_prop", "node_id": "alice", "key": "age", "value": 30}
{"type": "add_edge", "node_id": "alice", "edge_type": "KNOWS", "direction": "outgoing", "other": "bob"}
{"type": "remove_prop", "node_id": "alice", "key": "temp_flag"}
{"type": "remove_edge", "node_id": "alice", "edge_type": "KNOWS", "direction": "outgoing", "other": "bob"}
```

**Mutation types:**

| Type | Required fields | Maps to |
|------|----------------|---------|
| `set_prop` | `node_id`, `key`, `value` | `SetProp { key, value, reply_to: 0 }` |
| `remove_prop` | `node_id`, `key` | `RemoveProp { key, reply_to: 0 }` |
| `add_edge` | `node_id`, `edge_type`, `direction`, `other` | `AddEdge { edge, reply_to: 0 }` |
| `remove_edge` | `node_id`, `edge_type`, `direction`, `other` | `RemoveEdge { edge, reply_to: 0 }` |

**Value mapping** (JSON → QuineValue):
- JSON string → `Str`
- JSON number (integer) → `Integer`
- JSON number (float) → `Floating`
- JSON boolean → `Bool`
- JSON null → `Null`
- JSON array → `List`
- JSON object → `Map`

**QuineId from node_id string:**
Deterministic: FNV-1a hash of the UTF-8 bytes, producing 16 bytes (U128). Same algorithm already used for `query_part_id` in `MvStandingQuery.roc`. This ensures the same `node_id` string always routes to the same shard.

### Roc Side — IngestParser

**New package:** `packages/ingest/` with `IngestParser.roc`

```roc
parse_jsonl_line : Str -> Result { target : QuineId, msg : NodeMessage } [ParseError Str]
```

Parses one JSON line into a target node and message. Uses Roc's built-in JSON decoding or a hand-rolled parser for the small schema.

Note: Roc's JSON library situation needs investigation at implementation time. If no suitable JSON parser exists, the parsing can happen on the Rust side instead (serde_json), with the Rust code producing the encoded shard envelope directly. This is the fallback approach and may actually be simpler.

### Rust Side — ingest.rs

**IngestJob:**
```rust
pub struct IngestJob {
    pub name: String,
    pub source: IngestSource,
    pub status: IngestStatus,
    pub records_processed: AtomicU64,
    pub records_failed: AtomicU64,
    pub cancel: CancellationToken,
    pub started_at: Instant,
    pub completed_at: Option<Instant>,
}

pub enum IngestSource {
    File { path: PathBuf },
    Inline { data: Vec<String> },
}

pub enum IngestStatus {
    Running,
    Complete,
    Errored(String),
    Cancelled,
}
```

**IngestJobRegistry:**
```rust
pub type IngestJobRegistry = Arc<Mutex<HashMap<String, Arc<IngestJob>>>>;
```

**File ingest loop:**
1. Open file, read line by line (tokio `BufReader`)
2. For each line: parse JSON → extract `node_id` → compute QuineId → determine target shard → encode as shard envelope → `try_send` to shard channel
3. If channel full: backoff (tokio sleep 1ms, retry)
4. Check cancellation token each line
5. On completion/error: update status

**Parsing approach (Rust-side, recommended):**
Since serde_json is already available (needed for axum), parse JSONL in Rust:
1. `serde_json::from_str` each line
2. Extract `type`, `node_id`, and mutation-specific fields
3. Compute QuineId via FNV-1a hash of `node_id` bytes
4. Encode as `NodeMessage` using the codec wire format (reuse tag bytes from Codec.roc)
5. Wrap in shard envelope with `TAG_SHARD_MSG` prefix

This avoids needing a JSON parser in Roc and keeps parsing at the boundary where it belongs.

### Deliverables

- `platform/src/ingest.rs` — IngestJob, IngestJobRegistry, file reader, JSONL parser
- Codec wire format documentation (or constants shared between Rust and Roc)
- Test data files in `test-data/`
- Integration test: ingest file → verify nodes have properties

---

## Phase P3: REST API (axum)

### Problem

No external interface exists. The only way to interact is by sending raw bytes to shard channels.

### Server Setup

**Dependencies (add to Cargo.toml):**
```toml
axum = "0.8"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["rt", "time", "net", "macros"] }
tower = "0.5"
tower-http = { version = "0.6", features = ["cors", "trace"] }
uuid = { version = "1", features = ["v4"] }
```

**Shared state (injected via axum `State`):**
```rust
pub struct AppState {
    pub channel_registry: &'static ChannelRegistry,
    pub ingest_jobs: IngestJobRegistry,
    pub sq_registry: SqRegistry,
    pub sq_result_rx: crossbeam_channel::Receiver<Vec<u8>>,
    pub shard_count: u32,
    pub start_time: Instant,
}
```

**Server startup** (in `main.rs`, after shard workers start):
```rust
let app = Router::new()
    .nest("/api/v1", api_routes())
    .with_state(app_state);

tokio::spawn(async move {
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    axum::serve(listener, app).await.unwrap();
});
```

### Endpoint Specifications

#### Ingest Group

**POST /api/v1/ingest**

Request:
```json
{
  "name": "my-ingest",
  "type": "file",
  "path": "/data/events.jsonl"
}
```
or inline:
```json
{
  "name": "quick-test",
  "type": "inline",
  "data": [
    "{\"type\":\"set_prop\",\"node_id\":\"a\",\"key\":\"x\",\"value\":1}"
  ]
}
```

Response (201 Created):
```json
{
  "name": "my-ingest",
  "status": "running",
  "records_processed": 0
}
```

Errors: 409 if name already exists, 400 if invalid body.

**GET /api/v1/ingest**

Response (200):
```json
[
  {
    "name": "my-ingest",
    "status": "running",
    "records_processed": 1542,
    "records_failed": 0,
    "started_at": "2026-04-21T10:00:00Z"
  }
]
```

**GET /api/v1/ingest/:name**

Response (200): single job object. 404 if not found.

**DELETE /api/v1/ingest/:name**

Response (200): `{ "name": "my-ingest", "status": "cancelled" }`. 404 if not found. 400 if already complete.

#### Standing Queries Group

**POST /api/v1/standing-queries**

Request (MVSQ AST as JSON):
```json
{
  "query": {
    "type": "LocalProperty",
    "prop_key": "name",
    "constraint": { "type": "Any" },
    "aliased_as": "n"
  },
  "include_cancellations": true
}
```

Response (201):
```json
{
  "id": "a1b2c3d4-...",
  "query": { ... },
  "status": "running",
  "results_emitted": 0
}
```

The handler:
1. Generates a UUID → StandingQueryId (U128 from uuid v4)
2. Converts JSON AST to `MvStandingQuery` wire bytes using a Rust-side encoder that mirrors the tag/field format in Codec.roc (tags 0x10-0x13 for SqCommand, plus the MvStandingQuery AST encoding). This is a Rust reimplementation of the Roc codec for the specific types needed at the API boundary.
3. For each shard: encodes a `CreateSqSubscription` command in a shard envelope and sends to the shard channel
4. Then for each shard: encodes an `UpdateStandingQueries` command and sends to the shard channel
5. Stores the query metadata in SqRegistry (Rust-side `Arc<Mutex<HashMap>>`) for GET/DELETE

**GET /api/v1/standing-queries**

Response (200): list of registered SQs with result counts.

Also includes recent results (drained from the SQ result channel):
```json
[
  {
    "id": "a1b2c3d4-...",
    "query": { ... },
    "status": "running",
    "results": [
      { "is_positive_match": true, "data": { "n": "Alice" } }
    ]
  }
]
```

**DELETE /api/v1/standing-queries/:id**

Sends cancellation to all shards, removes from registry. Response (200) or 404.

#### Node Query Group

**GET /api/v1/nodes/:id**

This is the most complex endpoint — requires request-response through the shard.

**Mechanism:**
1. Compute QuineId from `:id` string (same FNV-1a hash as ingest)
2. Determine target shard
3. Create a `tokio::sync::oneshot` channel for the reply
4. Store the oneshot sender in a `PendingRequests` map keyed by `request_id`
5. Encode and send `GetProps { reply_to: request_id }` to the shard
6. `await` the oneshot receiver (with timeout)
7. Shard processes GetProps, produces `Reply` effect
8. `graph-app.roc` executes the Reply effect → calls a new host function `roc_fx_reply` that looks up the pending request and sends on the oneshot
9. Return properties as JSON

Response (200):
```json
{
  "id": "alice",
  "properties": {
    "name": "Alice",
    "age": 30
  },
  "edges": [
    { "type": "KNOWS", "direction": "outgoing", "other": "bob" }
  ]
}
```

404 if node has never been seen (no properties, no edges). Timeout 504 if shard doesn't respond within 5s.

**New host function needed:** `roc_fx_reply : U64, List U8 => {}` — takes request_id and encoded reply payload, routes to the pending oneshot.

#### Health Group

**GET /api/v1/health**

Response (200):
```json
{
  "status": "ok",
  "shards": 4,
  "uptime_seconds": 142,
  "ingest_jobs": { "running": 1, "complete": 3 },
  "standing_queries": { "running": 2, "results_emitted": 847 }
}
```

No shard communication needed — reads from shared atomic counters and registries.

### Deliverables

- `platform/src/api/mod.rs` — axum Router setup
- `platform/src/api/ingest.rs` — 4 ingest endpoints
- `platform/src/api/standing_queries.rs` — 3 SQ endpoints
- `platform/src/api/nodes.rs` — node query with request-response
- `platform/src/api/health.rs` — health endpoint
- `roc_fx_reply` host function (Roc + Rust)
- MVSQ JSON → wire format converter
- Shared state types (AppState, SqRegistry, PendingRequests)

---

## Phase P4: Docker & E2E Testing

### Problem

No way to build, deploy, or test the prototype as a whole system.

### Dockerfile (multi-stage)

```dockerfile
# Stage 1: Build Rust platform
FROM rust:slim-bookworm AS rust-builder
WORKDIR /build
COPY platform/ platform/
RUN cd platform && cargo build --release

# Stage 2: Build Roc app
FROM ubuntu:24.04 AS roc-builder
# Install Roc nightly (specific commit for reproducibility)
RUN curl -fsSL https://github.com/roc-lang/roc/releases/download/nightly/roc_nightly-linux_x86_64-latest.tar.gz \
    | tar xz -C /usr/local/bin
WORKDIR /build
COPY packages/ packages/
COPY app/ app/
COPY platform/main.roc platform/main.roc
COPY platform/Effect.roc platform/Effect.roc
COPY platform/Host.roc platform/Host.roc
RUN roc build --lib app/graph-app.roc

# Stage 3: Runtime
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY --from=rust-builder /build/platform/target/release/quine-roc /usr/local/bin/
COPY --from=roc-builder /build/app/libapp.so /usr/local/lib/
ENV LD_LIBRARY_PATH=/usr/local/lib
EXPOSE 8080
ENTRYPOINT ["quine-roc"]
```

Note: The exact Roc build commands and library naming (`libapp.so` vs `libapp.dylib`) need verification at implementation time. The Roc platform linking model may require adjustments.

### docker-compose.yml

```yaml
version: "3.8"

services:
  quine-roc:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8080:8080"
    volumes:
      - ./test-data:/data:ro
    command: ["--shards", "4", "--port", "8080"]
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/api/v1/health"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 5s

  e2e-test:
    image: curlimages/curl:latest
    depends_on:
      quine-roc:
        condition: service_healthy
    volumes:
      - ./tests/e2e:/tests:ro
    entrypoint: ["sh", "/tests/run.sh"]
```

### E2E Test Script

**`tests/e2e/run.sh`:**

```bash
#!/bin/sh
set -e
BASE="http://quine-roc:8080/api/v1"
PASS=0; FAIL=0

assert_status() {
    test_name="$1"; expected="$2"; actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $test_name"; PASS=$((PASS+1))
    else
        echo "FAIL: $test_name (expected $expected, got $actual)"; FAIL=$((FAIL+1))
    fi
}

# 1. Health check
STATUS=$(curl -so /dev/null -w '%{http_code}' "$BASE/health")
assert_status "health check" "200" "$STATUS"

# 2. Register standing query
SQ_RESP=$(curl -s -X POST "$BASE/standing-queries" \
  -H "Content-Type: application/json" \
  -d '{"query":{"type":"LocalProperty","prop_key":"name","constraint":{"type":"Any"},"aliased_as":"n"},"include_cancellations":false}')
SQ_ID=$(echo "$SQ_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert_status "register SQ" "true" "$([ -n "$SQ_ID" ] && echo true || echo false)"

# 3. Start file ingest
STATUS=$(curl -so /dev/null -w '%{http_code}' -X POST "$BASE/ingest" \
  -H "Content-Type: application/json" \
  -d '{"name":"test-ingest","type":"file","path":"/data/test-events.jsonl"}')
assert_status "start ingest" "201" "$STATUS"

# 4. Wait for ingest completion (poll)
for i in $(seq 1 30); do
    INGEST_STATUS=$(curl -s "$BASE/ingest/test-ingest" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    [ "$INGEST_STATUS" = "complete" ] && break
    sleep 0.5
done
assert_status "ingest completes" "complete" "$INGEST_STATUS"

# 5. Check SQ has results
SQ_RESULTS=$(curl -s "$BASE/standing-queries")
HAS_RESULTS=$(echo "$SQ_RESULTS" | grep -c "is_positive_match" || true)
assert_status "SQ produced results" "true" "$([ "$HAS_RESULTS" -gt 0 ] && echo true || echo false)"

# 6. Query a node
NODE_RESP=$(curl -s "$BASE/nodes/alice")
HAS_NAME=$(echo "$NODE_RESP" | grep -c '"name"' || true)
assert_status "node has properties" "true" "$([ "$HAS_NAME" -gt 0 ] && echo true || echo false)"

# 7. Cancel SQ
STATUS=$(curl -so /dev/null -w '%{http_code}' -X DELETE "$BASE/standing-queries/$SQ_ID")
assert_status "cancel SQ" "200" "$STATUS"

# 8. Delete ingest
STATUS=$(curl -so /dev/null -w '%{http_code}' -X DELETE "$BASE/ingest/test-ingest")
assert_status "delete ingest" "200" "$STATUS"

# Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

### Test Data

**`test-data/test-events.jsonl`:**
```json
{"type":"set_prop","node_id":"alice","key":"name","value":"Alice"}
{"type":"set_prop","node_id":"alice","key":"age","value":30}
{"type":"set_prop","node_id":"bob","key":"name","value":"Bob"}
{"type":"set_prop","node_id":"bob","key":"age","value":25}
{"type":"add_edge","node_id":"alice","edge_type":"KNOWS","direction":"outgoing","other":"bob"}
{"type":"add_edge","node_id":"bob","edge_type":"KNOWS","direction":"outgoing","other":"alice"}
{"type":"set_prop","node_id":"charlie","key":"name","value":"Charlie"}
{"type":"add_edge","node_id":"alice","edge_type":"FOLLOWS","direction":"outgoing","other":"charlie"}
```

### Deliverables

- `Dockerfile` — multi-stage build (Rust + Roc + runtime)
- `docker-compose.yml` — service + test runner
- `tests/e2e/run.sh` — 8-assertion E2E script
- `test-data/test-events.jsonl` — sample graph data
- `.dockerignore` — exclude target/, .git, etc.

---

## Build Order & Dependencies

```
Phase P1: Platform Completion     (no deps — foundation)
    │
    ├── persistence_io.rs         (in-memory HashMap store)
    ├── timer.rs                  (tokio interval → TAG_TIMER)
    ├── NodeSnapshot codec        (encode/decode in Roc)
    ├── SleepWake wiring          (begin_sleep encodes, complete_wake decodes)
    └── Persist result handling   (graph-app.roc handles TAG_PERSIST_RESULT)
    │
Phase P2: JSONL Ingest            (depends on P1 — needs working shards)
    │
    ├── JSONL parser (Rust)       (serde_json → shard envelope bytes)
    ├── ingest.rs                 (file reader, job lifecycle, registry)
    ├── QuineId from string       (FNV-1a hash, matching Roc implementation)
    └── Codec constants shared    (tag bytes consistent Rust ↔ Roc)
    │
Phase P3: REST API                (depends on P1+P2 — needs shards + ingest)
    │
    ├── axum server setup         (Router, shared state, startup)
    ├── Ingest endpoints (4)      (talk to IngestJobRegistry)
    ├── SQ endpoints (3)          (SQ registration → shard messages)
    ├── Node query endpoint (1)   (request-response via oneshot + roc_fx_reply)
    ├── Health endpoint (1)       (read shared counters)
    └── MVSQ JSON → wire format   (AST conversion for SQ registration)
    │
Phase P4: Docker & E2E           (depends on P1+P2+P3 — full stack)
    │
    ├── Dockerfile (multi-stage)
    ├── docker-compose.yml
    ├── E2E test script (8 assertions)
    └── Test data
```

---

## Decisions & Rationale

### axum for HTTP

axum is tokio-native (already a dependency), supports REST + gRPC on the same port (future tonic integration), has built-in WebSocket support (future streaming SQ results), and is the actively maintained tokio-rs project. Binary size overhead (~1.1 MB) is negligible.

### JSONL parsing in Rust, not Roc

serde_json is already needed for the REST API. Parsing at the Rust boundary avoids needing a JSON library in Roc and keeps I/O concerns in the host. The Roc engine receives pre-encoded shard envelopes, same as cross-shard messages.

### In-memory persistence only

The prototype goal is proving the pipeline works, not durability. In-memory HashMap matches the existing Roc-side in-memory Persistor (Phase 2). Disk-backed persistence (RocksDB) is a future phase.

### Request-response for node queries

The node query endpoint needs synchronous request-response through the async shard worker. The oneshot channel pattern (with a `PendingRequests` map and a new `roc_fx_reply` host function) is the standard approach for bridging async callers with message-passing workers. The Reply effect already exists in the Roc Effect union but was previously logged as "routing deferred" — this wires it up.

### FNV-1a for QuineId from strings

Same hash algorithm already used in `MvStandingQuery.query_part_id`. Consistent between Rust ingest parser and Roc graph engine ensures the same `node_id` string always maps to the same QuineId and routes to the same shard.

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Roc JSON parsing unavailable | Ingest parser blocked | Fallback: parse in Rust (recommended approach anyway) |
| Roc build in Docker fails | Can't containerize | Pin exact Roc nightly commit; test Docker build early |
| Platform linking model changes | libapp.so path breaks | Verify Roc `--lib` output format before building Dockerfile |
| Request-response latency | Node queries slow under load | 5s timeout; prototype doesn't need high throughput |
| Shard channel backpressure | Ingest stalls | Backoff + retry already designed; acceptable for prototype |
| axum version churn | API breakage | Pin exact version in Cargo.toml |

---

## Open Questions

| Question | Current Decision | Revisit When |
|----------|-----------------|--------------|
| Should JSONL parsing happen in Roc or Rust? | Rust (serde_json) | If Roc JSON ecosystem matures |
| Disk persistence backend? | In-memory HashMap | When durability is needed (post-prototype) |
| SQ result delivery model? | Poll via GET endpoint | Phase 6 (WebSocket streaming, output sinks) |
| Node query edge serialization? | Return edges as flat list | Phase 5 (when Cypher MATCH needs traversal) |
| Multi-node gRPC protocol? | Not in scope | Post-prototype clustering phase |
