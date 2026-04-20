# Phase 3a: Custom Roc Platform — Design Spec

**Status:** Approved
**Date:** 2026-04-19
**Depends on:** Phase 2 (persistence interfaces), Phase 3b (Roc graph layer)
**Unblocks:** Phase 3b integration (wiring graph code to platform)
**ADRs:** ADR-016 (shard event loops), ADR-017 (custom platform threading/build/FFI)

---

## Overview

Phase 3a builds a custom Roc platform in Rust that provides six primitives
to Roc: shard worker threads, bounded channels, timers, persistence I/O
dispatch, wall-clock time, and structured logging. The host is a "dumb
runtime" — it does not know what a QuineId, edge, or standing query is.

Phase 3b (Roc graph layer) is already complete: 16 modules, 80 tests,
covering shard routing, dispatch, LRU, sleep/wake, and GraphOps. Phase 3a
provides the runtime that executes it.

---

## Platform Contract

```roc
platform "quine-graph"
    requires { ShardState } {
        init_shard! : U32 => ShardState,
        handle_message! : ShardState, List U8 => ShardState,
        on_timer! : ShardState, U8 => ShardState,
    }
```

- `init_shard!` — called once per shard at startup, receives the shard index
- `handle_message!` — called for each message on the shard's channel
- `on_timer!` — called on timer ticks (CheckLru, AskTimeout)
- `ShardState` — opaque to the host; held as a pinned pointer between calls

---

## Host Architecture

### Threading model (ADR-017)

- **N shard worker threads** (std::thread, configurable, default 4). Each
  runs a blocking recv-dispatch-drain loop via crossbeam channels.
- **1 small tokio runtime** (current_thread) for timers and persistence I/O.
  Timers send messages into shard channels. Persistence pool uses
  tokio::spawn_blocking.
- **Bounded crossbeam channels**: one per shard (incoming messages), one for
  persistence commands.

### Shard worker loop

```
loop {
    msg = shard_channel.recv()         // blocking
    if msg is timer:
        state = call_on_timer(state, timer_kind)
    else:
        state = call_handle_message(state, msg)
    drain_and_execute_effects(state)   // channel sends, persist, log
}
```

### Roc ABI (Box Model, kingfisher pattern)

The host holds a `*mut u8` pointer to each shard's `ShardState`. Between
calls, the refcount is pinned to infinity so Roc's GC does not free it.
After each Roc call, the host receives a new pointer (the Roc function
returns a new ShardState) and swaps it atomically.

Reference implementations:
- `roc-lang/basic-cli/crates/roc_host/` — Rust calling convention, roc_fx_*
- `ostcar/kingfisher/host/roc/roc.go` — Box Model, refcount pinning
- `lukewilliamboswell/roc-wasm4` — init/update pattern

### Memory callbacks

```rust
#[no_mangle] pub extern "C" fn roc_alloc(size: usize, align: usize) -> *mut u8
#[no_mangle] pub extern "C" fn roc_realloc(ptr: *mut u8, new: usize, old: usize, align: usize) -> *mut u8
#[no_mangle] pub extern "C" fn roc_dealloc(ptr: *mut u8, size: usize, align: usize)
```

---

## Roc-Exposed Host Functions

```rust
// Send a message to a shard's input channel.
// Returns 0 on success, 1 if channel is full.
#[no_mangle]
pub extern "C" fn roc_fx_send_to_shard(shard_id: u32, msg: &RocList<u8>) -> u8

// Dispatch an async persistence command. Returns a request ID.
#[no_mangle]
pub extern "C" fn roc_fx_persist_async(cmd: &RocList<u8>) -> u64

// Wall-clock time in milliseconds since epoch.
#[no_mangle]
pub extern "C" fn roc_fx_current_time() -> u64

// Structured log at the given level (0=error, 1=warn, 2=info, 3=debug).
#[no_mangle]
pub extern "C" fn roc_fx_log(level: u8, msg: &RocStr)
```

---

## FFI Encoding (ADR-017, Decision 3)

**Hybrid (Option C):** typed for simple values, bytes for complex messages.

| Type | FFI representation | Notes |
|------|-------------------|-------|
| ShardId | U32 | Direct |
| TimerKind | U8 | 0=CheckLru, 1=AskTimeout |
| RequestId | U64 | Direct |
| ShardState | `*mut u8` (opaque) | Host never inspects |
| ShardMessage | `List U8` (RocList) | Roc encodes/decodes via Encode/Decode |
| Effect list | `List U8` within ShardState | Host reads tag bytes to route |
| PersistCommand | `List U8` | Roc encodes, persistence pool decodes |

**Migration to typed FFI:** Run `roc glue` to generate Rust structs for
Effect, PersistCommand, BackpressureSignal. Replace byte-parsing in
effects.rs. No Roc-side changes needed.

---

## Effect Execution

After each Roc call, the host reads pending effects from the returned
ShardState (a `List U8` field) and routes by tag byte:

| Tag | Effect | Host action |
|-----|--------|-------------|
| 0x01 | Reply | Send response to requesting shard's reply channel |
| 0x02 | SendToNode | Re-enqueue on same shard's channel |
| 0x03 | SendToShard | try_send to target shard's crossbeam channel |
| 0x04 | Persist | Dispatch to tokio persistence pool |
| 0x05 | EmitBackpressure | Update shard's backpressure flag |
| 0x06 | UpdateCostToSleep | (consumed by Roc side, no host action) |

Tag byte values are provisional and will be determined by the actual Roc
Encode implementation.

---

## Build Strategy (ADR-017, Decision 2)

### Development (Phase 3a)

1. `cargo build` — produces the host binary/library
2. `roc build app.roc` — links against the prebuilt host
3. `./app` — run

### Publication (future)

Switch to surgical linking (`roc build --lib` → `cargo build`) when/if the
platform is published. This transition happens when the platform API
stabilizes, not during Phase 3a.

---

## Configuration

```rust
pub struct PlatformConfig {
    pub shard_count: u32,           // default 4
    pub channel_capacity: usize,    // default 4096
    pub lru_check_interval_ms: u64, // default 10_000
    pub persistence_pool_size: u32, // default 2
}
```

---

## File Structure

```
platform/
  Cargo.toml                # tokio, crossbeam-channel, roc_std (if available)
  src/
    main.rs                 # Entry point: parse config, spawn shards + tokio
    config.rs               # PlatformConfig with defaults
    roc_glue.rs             # Roc ABI: call_init/handle/timer, roc_alloc/dealloc
    shard_worker.rs         # Per-shard recv-dispatch-drain loop (std::thread)
    channels.rs             # Bounded crossbeam channels, ChannelRegistry
    timer.rs                # tokio::time tasks feeding into shard channels
    persistence_io.rs       # tokio blocking pool for persist commands
    effects.rs              # Drain pending_effects from ShardState, route by tag
  main.roc                  # Platform declaration (requires { ShardState })
  Effect.roc                # Roc-side effect stubs (send_to_shard!, etc.)

app/
  platform-test-echo.roc        # Shards initialize and echo messages
  platform-test-timer.roc       # Verify timer fires at expected intervals
  platform-test-persist.roc     # Persistence round-trip
  platform-test-backpressure.roc # Channel full behavior
```

---

## Implementation Approach

Incremental, research-first:

1. Scaffold Cargo project, verify `cargo build`
2. Research Roc ABI — get `roc_alloc`/`roc_dealloc` working, study basic-cli
3. Minimal platform: `main.roc` + trivial Roc app that compiles and runs
4. Add primitives one at a time: channels → shard workers → timers → persistence
5. Wire Phase 3b graph code to the platform last

Start with "can I call a Roc function from Rust and get a value back" before
building the full shard worker loop.

---

## Test Plan

Small Roc test apps exercising each primitive independently:

- **platform-test-echo.roc**: spawn 4 shards, each initializes with its ID,
  receives messages, logs receipt. Verifies init_shard! and handle_message!
  work end-to-end.
- **platform-test-timer.roc**: verify CheckLru timer fires at approximately
  the configured interval. Shard counts timer ticks and logs.
- **platform-test-persist.roc**: send a PersistSnapshot command, receive a
  PersistenceResult message back. Verifies the persistence I/O round-trip.
- **platform-test-backpressure.roc**: send messages until channel is full,
  verify send_to_shard! returns ChannelFull.

---

## Done Criteria

- All four test apps pass
- Phase 3b graph code compiles against the platform (not necessarily fully
  wired — that may require glue work)
- Host is frozen — changes only when a new primitive is needed (not expected
  until Phase 6)

---

## Estimated Scope

~500-800 lines of Rust. The Roc ABI research (Task 2) is the highest-risk
item — the ABI is pre-1.0 and details must be verified against the installed
nightly (commit d73ea109cc2, Sep 9 2025).

---

## Replication Readiness

The current architecture is naturally ready for Level 1 (warm follower)
shard replication with zero Roc code changes. See
`refs/analysis/threading-distribution-matrix.md` for the full analysis.

Key properties enabling this:
- Deterministic dispatch (no effectful calls in Roc dispatch path)
- Effects returned as data (List Effect), not executed inline
- Timing passed as parameter, not fetched during dispatch

No replication code is built in Phase 3a. The seams are architectural.
