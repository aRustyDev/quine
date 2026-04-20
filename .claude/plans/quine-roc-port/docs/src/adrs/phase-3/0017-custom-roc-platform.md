# ADR-017: Custom Roc Platform — Threading Model and Build Strategy

**Status:** Accepted
**Date:** 2026-04-19
**Context:** Phase 3a requires a custom Roc platform in Rust. The platform
provides six primitives to Roc (shard workers, channels, timers, persistence
I/O, current_time, structured logging). Key decisions: threading model for
shard workers and the build/packaging approach.

**Related:** ADR-016 (shard event loops), distribution analysis in
`refs/analysis/threading-distribution-matrix.md`

## Decision 1: Threading Model

**std::thread for shard workers + small tokio runtime for timers and
persistence I/O.**

### Rationale

The shard worker hot path is synchronous: `recv → call Roc → drain effects →
loop`. This is a blocking workload with no I/O to await. Wrapping it in
tokio's async executor adds overhead (`spawn_blocking` per Roc call, ~1-2μs)
with no benefit under the current ADR-016 concurrency model (Option A).

Timers and persistence I/O are genuinely async workloads where tokio helps:
- `tokio::time::interval` is cleaner than manual `thread::sleep` timer loops
- Persistence I/O benefits from async disk/network operations
- A small `current_thread` tokio runtime costs ~1-2MB, acceptable on RPi CM5

### Migration path to Option B (per-node tasks)

If ADR-016 is revisited and Option B is adopted:
1. Shard worker threads in `shard_worker.rs` → `tokio::spawn_blocking`
2. Timer and persistence code unchanged
3. Migration surface is isolated to one file

### Migration path to true distribution

When shards move to separate machines (post-Phase 7):
1. Add tokio-based RPC (tonic/tarpc) alongside existing shard threads
2. Shard worker loop unchanged — still `recv → Roc → effects`
3. Cross-shard `SendToShard` effects route to network instead of local channel

See `refs/analysis/threading-distribution-matrix.md` for the full 2×2×3
analysis (concurrency model × distribution × process topology).

## Decision 2: Build Strategy

**Option 2 (prebuilt host) for development. Option 1 (surgical linking)
deferred to platform publication.**

### Development (now)

`cargo build` produces a static library. The platform's `main.roc` header
points at the prebuilt binary. `roc build app.roc` links everything.

Build loop: `cargo build` → `roc build app.roc` → `./app`

### Publication (future)

When/if the platform is published as `quine-graph` (or similar), switch to
Option 1: `roc build --lib app.roc` produces a `.a`, then `cargo build`
links it. This lets users build without a Rust toolchain. This transition
happens naturally when the platform API stabilizes.

## Decision 3: FFI Encoding

**Hybrid (Option C): typed for simple values, bytes for complex messages.
Upgrade to fully typed FFI (Option B) after platform stabilizes.**

### Now (Phase 3a)

- `ShardId` (U32), `TimerKind` (U8), `RequestId` (U64) — typed directly
- `ShardState` — opaque `*mut u8`, host never inspects
- `ShardMessage`, `Effect` payloads — `List U8`, Roc encodes/decodes
- Effect discriminants — tag byte read by host to route effects

### Later

Run `roc glue` to generate Rust structs for `Effect`, `PersistCommand`,
`BackpressureSignal`. Replace byte-parsing in `effects.rs` with typed Rust
enums. No Roc-side changes needed — the migration is purely host-side.

## Risks

- Roc's platform ABI is pre-1.0; breaking changes may require host updates
- Effect interpreter model (planned by Roc team) may change how host
  functions are wired
- Mitigation: kingfisher and roc-wasm4 maintain custom platforms against
  nightly with low breakage cadence

## Alternatives Considered

### Threading

- **All tokio**: `spawn_blocking` for every Roc call. Adds ~2MB baseline +
  per-call overhead. No benefit until Option B. Rejected.
- **All std::thread**: Manual timer threads, manual persistence thread pool.
  Works but timer management is boilerplate. Rejected in favor of hybrid.

### Build

- **Option 1 (surgical linking)**: `roc build --lib` → `cargo build`.
  Unnecessary complexity for development. Deferred to publication.

### FFI Encoding

- **All bytes (Option A)**: Simple but loses type safety for even trivial
  values like ShardId. Rejected.
- **All typed (Option B)**: `roc glue` generated types. Good end state but
  premature during rapid iteration. Deferred.
