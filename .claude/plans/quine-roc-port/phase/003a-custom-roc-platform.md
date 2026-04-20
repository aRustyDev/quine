# Phase 3a: Custom Roc Platform — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Rust/tokio host binary that runs compiled Roc applications, providing shard worker threads, bounded channels, timers, persistence I/O, wall-clock time, and structured logging.

**Architecture:** The host is a "dumb runtime" — it provides six primitives to Roc and executes effects returned from Roc dispatch calls. Shard workers run on std::thread with crossbeam channels. A small tokio runtime handles timers and persistence I/O. The Roc ABI follows the kingfisher Box Model pattern: opaque state pointers with pinned refcounts.

**Tech Stack:** Rust (std::thread, crossbeam-channel, tokio current_thread), Roc nightly (commit d73ea109cc2, Sep 9 2025). Depends on `roc_std` crate from roc-lang/roc repo.

**Spec:** `.claude/plans/quine-roc-port/refs/specs/phase-3a-custom-roc-platform.md`

**Reference platforms studied:**
- `roc-lang/basic-cli` — Rust calling convention, `roc_fx_*` pattern, `roc_std` types
- `ostcar/kingfisher` — Box Model, refcount pinning, init/update/handle cycle
- `lukewilliamboswell/roc-wasm4` — init/update state lifecycle, Zig host

---

## File Structure

```
platform/
  Cargo.toml                    # Rust project: tokio, crossbeam-channel, roc_std
  build.rs                      # Link against compiled Roc app (libapp)
  src/
    main.rs                     # Entry point: parse config, spawn shards + tokio
    config.rs                   # PlatformConfig: shard_count, channel_capacity, etc.
    roc_glue.rs                 # Roc ABI: call_init/handle/timer, memory callbacks
    shard_worker.rs             # Per-shard recv-dispatch-drain loop (std::thread)
    channels.rs                 # Bounded crossbeam channels, ChannelRegistry
    timer.rs                    # tokio::time interval tasks feeding shard channels
    persistence_io.rs           # tokio blocking pool for persist commands
    effects.rs                  # Drain pending_effects, route by tag byte
  main.roc                      # Platform declaration (requires { ShardState })
  Host.roc                      # Hosted effect declarations (send_to_shard!, etc.)
  Effect.roc                    # Roc-side effect wrappers (public API for apps)

app/
  hello-platform.roc            # Minimal: init returns a counter, handle increments
  platform-test-echo.roc        # Shards initialize, echo messages, log receipt
  platform-test-timer.roc       # Verify CheckLru fires at expected intervals
  platform-test-persist.roc     # Persistence command → result round-trip
  platform-test-backpressure.roc # Send until ChannelFull, verify error
```

---

## Task 1: Scaffold Cargo project and build pipeline

**Files:**
- Create: `platform/Cargo.toml`
- Create: `platform/build.rs`
- Create: `platform/src/main.rs`
- Create: `platform/src/config.rs`

- [ ] **Step 1: Create Cargo.toml**

```toml
[package]
name = "quine-graph-platform"
version = "0.1.0"
edition = "2021"
links = "app"

[dependencies]
crossbeam-channel = "0.5"
tokio = { version = "1", features = ["rt", "time"] }
libc = "0.2"
roc_std = { git = "https://github.com/roc-lang/roc.git", rev = "d73ea109cc2" }

[lib]
name = "host"
crate-type = ["staticlib"]
```

Note: The `links = "app"` tells Cargo this crate links against a native
library called `app` (the compiled Roc application). The `rev` pins roc_std
to the same commit as the installed nightly. If `roc_std` is not available
at this rev, try the `main` branch or check `roc-lang/roc/crates/roc_std/`.

- [ ] **Step 2: Create build.rs**

```rust
// platform/build.rs
fn main() {
    let platform_path = std::env::current_dir()
        .expect("Failed to get current directory");

    println!(
        "cargo:rustc-link-search=native={}",
        platform_path.display()
    );
    println!("cargo:rustc-link-lib=static=app");
}
```

- [ ] **Step 3: Create config.rs**

```rust
// platform/src/config.rs

/// Configuration for the platform runtime.
pub struct PlatformConfig {
    pub shard_count: u32,
    pub channel_capacity: usize,
    pub lru_check_interval_ms: u64,
    pub persistence_pool_size: u32,
}

impl Default for PlatformConfig {
    fn default() -> Self {
        Self {
            shard_count: 4,
            channel_capacity: 4096,
            lru_check_interval_ms: 10_000,
            persistence_pool_size: 2,
        }
    }
}
```

- [ ] **Step 4: Create main.rs skeleton**

```rust
// platform/src/main.rs

mod config;

use config::PlatformConfig;

fn main() {
    let config = PlatformConfig::default();
    println!(
        "quine-graph platform starting with {} shards",
        config.shard_count
    );
}
```

- [ ] **Step 5: Verify Cargo.toml dependencies resolve**

Run: `cd platform && cargo check 2>&1`

Expected: Either compiles successfully, or `roc_std` dependency fails.
If `roc_std` fails, try:
- `roc_std = { git = "https://github.com/roc-lang/roc.git" }` (latest main)
- Check if the crate path changed (may be under `crates/compiler/roc_std`)
- If neither works, we'll vendor the types we need (RocStr, RocList) manually
  in a later task. Comment out the dependency for now and continue.

- [ ] **Step 6: Commit**

```bash
git add platform/Cargo.toml platform/build.rs platform/src/
git commit -m "phase-3a: scaffold Rust platform project"
```

---

## Task 2: Memory callbacks and panic handler

**Files:**
- Create: `platform/src/roc_glue.rs`
- Modify: `platform/src/main.rs`

These are required by every Roc platform. The compiled Roc code calls these
for all allocations. Without them, linking fails with undefined symbols.

- [ ] **Step 1: Write roc_glue.rs with memory callbacks**

```rust
// platform/src/roc_glue.rs

use std::ffi::c_void;

// ============================================================
// Memory callbacks — required by all Roc platforms.
// Roc's compiled code calls these for every allocation.
// ============================================================

#[no_mangle]
pub unsafe extern "C" fn roc_alloc(size: usize, _alignment: u32) -> *mut c_void {
    libc::malloc(size)
}

#[no_mangle]
pub unsafe extern "C" fn roc_realloc(
    c_ptr: *mut c_void,
    new_size: usize,
    _old_size: usize,
    _alignment: u32,
) -> *mut c_void {
    libc::realloc(c_ptr, new_size)
}

#[no_mangle]
pub unsafe extern "C" fn roc_dealloc(c_ptr: *mut c_void, _alignment: u32) {
    libc::free(c_ptr)
}

// ============================================================
// Panic and debug handlers — required by all Roc platforms.
// ============================================================

#[no_mangle]
pub unsafe extern "C" fn roc_panic(msg: *const u8, msg_len: usize, _tag_id: u32) {
    let msg_slice = std::slice::from_raw_parts(msg, msg_len);
    let msg_str = std::str::from_utf8_unchecked(msg_slice);
    eprintln!("Roc crashed with:\n\n\t{}\n", msg_str);
    std::process::exit(1);
}

#[no_mangle]
pub unsafe extern "C" fn roc_dbg(
    loc: *const u8,
    loc_len: usize,
    msg: *const u8,
    msg_len: usize,
) {
    let loc_str = std::str::from_utf8_unchecked(std::slice::from_raw_parts(loc, loc_len));
    let msg_str = std::str::from_utf8_unchecked(std::slice::from_raw_parts(msg, msg_len));
    eprintln!("[{}] {}", loc_str, msg_str);
}

#[no_mangle]
pub unsafe extern "C" fn roc_memset(dst: *mut c_void, c: i32, n: usize) -> *mut c_void {
    libc::memset(dst, c, n)
}
```

Note: The exact signatures for `roc_panic` and `roc_dbg` may differ from
what the nightly expects. If linking fails with signature mismatches, check:
- `roc-lang/roc/crates/compiler/gen_llvm/src/llvm/build.rs` for `roc_panic`
- `roc-lang/basic-cli/crates/roc_host/src/lib.rs` for the current signatures
Adjust the parameter types (e.g., `&RocStr` vs raw pointer + length) as needed.

- [ ] **Step 2: Add mod declaration to main.rs**

```rust
// platform/src/main.rs

mod config;
mod roc_glue;

use config::PlatformConfig;

fn main() {
    let config = PlatformConfig::default();
    println!(
        "quine-graph platform starting with {} shards",
        config.shard_count
    );
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cd platform && cargo check 2>&1`
Expected: Compiles (warnings about unused functions are fine)

- [ ] **Step 4: Commit**

```bash
git add platform/src/roc_glue.rs platform/src/main.rs
git commit -m "phase-3a: roc_alloc/dealloc/panic memory callbacks"
```

---

## Task 3: Platform declaration and hosted effects (Roc side)

**Files:**
- Create: `platform/main.roc`
- Create: `platform/Host.roc`
- Create: `platform/Effect.roc`

This task creates the Roc-side platform definition. The platform declares
what the app must provide (`init_shard!`, `handle_message!`, `on_timer!`)
and what the host provides (`send_to_shard!`, `persist_async!`, etc.).

- [ ] **Step 1: Write platform/main.roc**

```roc
platform "quine-graph"
    requires { ShardState } {
        init_shard! : U32 => ShardState,
        handle_message! : ShardState, List U8 => ShardState,
        on_timer! : ShardState, U8 => ShardState,
    }
    exposes [Effect]
    packages {}
    imports []
    provides [init_shard_for_host!, handle_message_for_host!, on_timer_for_host!]

import Effect

## Called once per shard at startup. Wraps the app's init_shard! with Box.
init_shard_for_host! : U32 => Box ShardState
init_shard_for_host! = |shard_id|
    Box.box(init_shard!(shard_id))

## Called for each message on a shard's channel.
handle_message_for_host! : Box ShardState, List U8 => Box ShardState
handle_message_for_host! = |boxed_state, msg|
    state = Box.unbox(boxed_state)
    new_state = handle_message!(state, msg)
    Box.box(new_state)

## Called on timer ticks (CheckLru=0, AskTimeout=1).
on_timer_for_host! : Box ShardState, U8 => Box ShardState
on_timer_for_host! = |boxed_state, timer_kind|
    state = Box.unbox(boxed_state)
    new_state = on_timer!(state, timer_kind)
    Box.box(new_state)
```

Note: The exact `platform` header syntax (especially `requires` with a type
parameter and `provides` with multiple functions) must be verified against
the installed Roc nightly. If the syntax has changed, compare with
kingfisher's `platform/main.roc` or basic-webserver's `platform/main.roc`.
Key things that may need adjustment:
- `requires { ShardState }` syntax — may need `requires {} { ... }` instead
- `provides` with multiple functions — may need a single `provides [main_for_host!]`
  that returns a record, like roc-wasm4 does
- `Box` import — may need explicit import if not a builtin

- [ ] **Step 2: Write platform/Host.roc**

```roc
hosted Host
    exposes [
        send_to_shard!,
        persist_async!,
        current_time!,
        log!,
    ]

## Send a message to a shard's input channel.
## Returns Err ChannelFull if the channel is at capacity.
send_to_shard! : U32, List U8 => Result {} [ChannelFull]

## Dispatch an async persistence command.
## Returns a request ID that will arrive later as a PersistenceResult message.
persist_async! : List U8 => U64

## Get the current wall-clock time in milliseconds since epoch.
current_time! : {} => U64

## Emit a structured log message.
## Levels: 0=error, 1=warn, 2=info, 3=debug
log! : U8, Str => {}
```

Note: The `hosted` syntax may need adjustment. Alternatives:
- `hosted [send_to_shard!, ...]` (basic-cli style, anonymous)
- The functions may need to be in a separate module that Host.roc imports
Check basic-cli's `platform/Host.roc` and kingfisher's `platform/Host.roc`
for the exact syntax expected by the current nightly.

- [ ] **Step 3: Write platform/Effect.roc**

```roc
## Public effect API for apps running on the quine-graph platform.
## Apps import this module to call host-provided functions.
module [
    send_to_shard!,
    persist_async!,
    current_time!,
    log!,
]

import Host

## Send a message to a shard's input channel.
send_to_shard! : U32, List U8 => Result {} [ChannelFull]
send_to_shard! = |shard_id, msg|
    Host.send_to_shard!(shard_id, msg)

## Dispatch an async persistence command.
persist_async! : List U8 => U64
persist_async! = |cmd|
    Host.persist_async!(cmd)

## Get the current wall-clock time in milliseconds since epoch.
current_time! : {} => U64
current_time! = |{}|
    Host.current_time!({})

## Emit a structured log message.
log! : U8, Str => {}
log! = |level, msg|
    Host.log!(level, msg)
```

- [ ] **Step 4: Commit**

```bash
git add platform/main.roc platform/Host.roc platform/Effect.roc
git commit -m "phase-3a: platform declaration and hosted effect stubs"
```

---

## Task 4: Hello world — verify Roc↔Rust cycle

**Files:**
- Create: `app/hello-platform.roc`
- Modify: `platform/src/roc_glue.rs`
- Modify: `platform/src/main.rs`

This is the critical verification step: can Rust call a Roc function and get
a value back? Everything else builds on this. Expect to iterate on ABI
details here.

- [ ] **Step 1: Write a minimal Roc app**

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

ShardState : { shard_id : U32, count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    { shard_id, count: 0 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, _msg|
    { state & count: state.count + 1 }

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    state
```

- [ ] **Step 2: Try to compile the Roc app as a library**

Run: `roc build --lib app/hello-platform.roc --output platform/libapp.a 2>&1`

Expected: Either succeeds (producing `platform/libapp.a`) or fails with
syntax errors in the platform declaration. If it fails:
- Read the error messages carefully — they indicate what the nightly expects
- Adjust `platform/main.roc`, `platform/Host.roc` syntax accordingly
- Common issues: `requires` syntax, `hosted` syntax, `Box` import, `provides` format
- Re-run until `roc build --lib` succeeds

This step may take several iterations. Do not proceed until the Roc app
compiles to a static library.

- [ ] **Step 3: Add Roc function declarations to roc_glue.rs**

Add to `platform/src/roc_glue.rs`:

```rust
// ============================================================
// Roc function declarations — the compiled Roc app exports these.
// The exact signatures depend on the Roc ABI for the platform's
// `provides` functions. These are our best guess based on
// basic-cli and kingfisher; adjust based on linker errors.
// ============================================================

extern "C" {
    /// Roc's init_shard_for_host!(shard_id: U32) => Box ShardState
    /// Output is written to the pointer passed as the first argument.
    #[link_name = "roc__init_shard_for_host_1_exposed_generic"]
    fn roc_init_shard_for_host(output: *mut *mut u8, shard_id: u32);

    #[link_name = "roc__init_shard_for_host_1_exposed_size"]
    fn roc_init_shard_for_host_size() -> usize;

    /// Roc's handle_message_for_host!(Box ShardState, List U8) => Box ShardState
    #[link_name = "roc__handle_message_for_host_1_exposed_generic"]
    fn roc_handle_message_for_host(
        output: *mut *mut u8,
        state: *mut u8,
        msg_ptr: *const u8,
        msg_len: usize,
    );

    /// Roc's on_timer_for_host!(Box ShardState, U8) => Box ShardState
    #[link_name = "roc__on_timer_for_host_1_exposed_generic"]
    fn roc_on_timer_for_host(output: *mut *mut u8, state: *mut u8, timer_kind: u8);
}

// ============================================================
// Refcount pinning — kingfisher pattern.
// Roc stores refcount at (ptr - 8). Setting it to 0 means
// "host owns this, don't modify the refcount."
// ============================================================

const REFCOUNT_OFFSET: usize = 8;

/// Pin the refcount of a Roc Box value to infinity (0).
/// This prevents Roc's GC from freeing the value between calls.
unsafe fn pin_refcount(ptr: *mut u8) {
    if !ptr.is_null() {
        let rc_ptr = ptr.sub(REFCOUNT_OFFSET) as *mut usize;
        *rc_ptr = 0;
    }
}

// ============================================================
// Safe wrappers for calling Roc functions.
// ============================================================

/// Call Roc's init_shard!(shard_id) and return the boxed ShardState pointer.
pub fn call_init_shard(shard_id: u32) -> *mut u8 {
    unsafe {
        let mut output: *mut u8 = std::ptr::null_mut();
        roc_init_shard_for_host(&mut output, shard_id);
        pin_refcount(output);
        output
    }
}

/// Call Roc's handle_message!(state, msg) and return the new boxed ShardState.
pub fn call_handle_message(state: *mut u8, msg: &[u8]) -> *mut u8 {
    unsafe {
        let mut output: *mut u8 = std::ptr::null_mut();
        roc_handle_message_for_host(&mut output, state, msg.as_ptr(), msg.len());
        pin_refcount(output);
        output
    }
}

/// Call Roc's on_timer!(state, timer_kind) and return the new boxed ShardState.
pub fn call_on_timer(state: *mut u8, timer_kind: u8) -> *mut u8 {
    unsafe {
        let mut output: *mut u8 = std::ptr::null_mut();
        roc_on_timer_for_host(&mut output, state, timer_kind);
        pin_refcount(output);
        output
    }
}
```

Note: The `extern "C"` function signatures are our best guess. The actual
ABI may differ in several ways:
- Output parameter may not be first argument
- `List U8` may be passed as a `RocList<u8>` struct, not raw ptr+len
- Function name mangling may differ (check `nm platform/libapp.a | grep roc__`)
- Refcount offset may be different from 8 bytes

If linking fails, run `nm platform/libapp.a | grep roc__` to see the actual
exported symbol names and adjust the `link_name` attributes.

- [ ] **Step 4: Update main.rs to call init_shard**

```rust
// platform/src/main.rs

mod config;
mod roc_glue;

use config::PlatformConfig;

fn main() {
    let config = PlatformConfig::default();
    println!(
        "quine-graph platform starting with {} shards",
        config.shard_count
    );

    // Initialize one shard as a smoke test
    let state = roc_glue::call_init_shard(0);
    println!("shard 0 initialized, state ptr: {:?}", state);

    // Send a dummy message
    let msg = b"hello";
    let state2 = roc_glue::call_handle_message(state, msg);
    println!("shard 0 after message, state ptr: {:?}", state2);

    println!("hello-platform: Roc<->Rust cycle works!");
}
```

- [ ] **Step 5: Build and run end-to-end**

Run:
```bash
cd /Users/adam/code/proj/rewrite/quine-roc
roc build --lib app/hello-platform.roc --output platform/libapp.a 2>&1
cd platform && cargo build 2>&1
./target/debug/quine-graph-platform 2>&1
```

Expected: Prints shard initialization and message handling output.

If this fails, this is where the real debugging happens:
1. `nm platform/libapp.a | grep roc__` — check actual symbol names
2. Adjust `link_name` attributes in `roc_glue.rs`
3. Check if parameter passing convention matches (output param first?)
4. Check if `RocList` needs to be passed as a struct instead of ptr+len
5. Check refcount offset (try `REFCOUNT_OFFSET = 4` on 32-bit)

Do not proceed until this step produces output. This is the foundation
for everything else.

- [ ] **Step 6: Commit**

```bash
git add app/hello-platform.roc platform/src/roc_glue.rs platform/src/main.rs
git commit -m "phase-3a: hello world — Roc<->Rust ABI verified"
```

---

## Task 5: Implement current_time! and log! host functions

**Files:**
- Modify: `platform/src/roc_glue.rs`
- Modify: `app/hello-platform.roc`

The simplest host functions. Adding these verifies that the `roc_fx_*`
calling convention works (Roc calling into Rust).

- [ ] **Step 1: Update hello-platform.roc to call effects**

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

import pf.Effect

ShardState : { shard_id : U32, count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "shard $(Num.to_str(shard_id)) initialized")
    { shard_id, count: 0 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, _msg|
    now = Effect.current_time!({})
    new_count = state.count + 1
    Effect.log!(2, "shard $(Num.to_str(state.shard_id)) msg #$(Num.to_str(new_count)) at $(Num.to_str(now))ms")
    { state & count: new_count }

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, kind|
    Effect.log!(3, "shard $(Num.to_str(state.shard_id)) timer kind=$(Num.to_str(kind))")
    state
```

- [ ] **Step 2: Implement roc_fx_current_time and roc_fx_log**

Add to `platform/src/roc_glue.rs`:

```rust
// ============================================================
// Host-provided effect functions — Roc calls these via roc_fx_*.
// ============================================================

#[no_mangle]
pub extern "C" fn roc_fx_current_time() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

#[no_mangle]
pub extern "C" fn roc_fx_log(level: u8, msg_ptr: *const u8, msg_len: usize) {
    let msg = unsafe { std::str::from_utf8_unchecked(std::slice::from_raw_parts(msg_ptr, msg_len)) };
    let level_str = match level {
        0 => "ERROR",
        1 => "WARN",
        2 => "INFO",
        3 => "DEBUG",
        _ => "TRACE",
    };
    eprintln!("[{}] {}", level_str, msg);
}
```

Note: The `roc_fx_log` signature assumes Roc passes `Str` as raw pointer +
length. If the nightly passes `&RocStr` instead, change to:
```rust
pub extern "C" fn roc_fx_log(level: u8, msg: &roc_std::RocStr) {
    eprintln!("[{}] {}", level_str, msg.as_str());
}
```
Check by compiling — linker errors will indicate the expected signature.

- [ ] **Step 3: Register effect functions in init()**

Add to `platform/src/roc_glue.rs`:

```rust
/// Must be called before any Roc code executes.
/// Prevents the compiler from optimizing away effect function pointers.
pub fn init() {
    let funcs: &[*const extern "C" fn()] = &[
        roc_alloc as _,
        roc_realloc as _,
        roc_dealloc as _,
        roc_panic as _,
        roc_dbg as _,
        roc_memset as _,
        roc_fx_current_time as _,
        roc_fx_log as _,
    ];
    #[allow(forgetting_references)]
    std::mem::forget(std::hint::black_box(funcs));
}
```

Update `main()` in `main.rs` to call `roc_glue::init()` before any Roc calls.

- [ ] **Step 4: Rebuild and test**

Run:
```bash
roc build --lib app/hello-platform.roc --output platform/libapp.a && \
cd platform && cargo build && \
./target/debug/quine-graph-platform
```

Expected: Output showing "[INFO] shard 0 initialized" and timestamp-stamped
message logs.

- [ ] **Step 5: Commit**

```bash
git add platform/src/roc_glue.rs platform/src/main.rs app/hello-platform.roc
git commit -m "phase-3a: current_time! and log! host functions verified"
```

---

## Task 6: Channels and ChannelRegistry

**Files:**
- Create: `platform/src/channels.rs`
- Modify: `platform/src/main.rs`

- [ ] **Step 1: Write channels.rs**

```rust
// platform/src/channels.rs

use crossbeam_channel::{bounded, Receiver, Sender, TrySendError};

/// Message tag bytes — shard workers use these to distinguish message types
/// on the shared channel.
pub const TAG_SHARD_MSG: u8 = 0x01;
pub const TAG_TIMER: u8 = 0xFF;
pub const TAG_PERSIST_RESULT: u8 = 0xFE;

/// A tagged message on a shard's channel. The first byte is a tag
/// distinguishing shard messages from timer ticks and persist results.
pub type ShardMsg = Vec<u8>;

/// Registry of all shard channels, indexed by shard ID.
pub struct ChannelRegistry {
    senders: Vec<Sender<ShardMsg>>,
    receivers: Vec<Receiver<ShardMsg>>,
}

impl ChannelRegistry {
    pub fn new(shard_count: u32, capacity: usize) -> Self {
        let mut senders = Vec::with_capacity(shard_count as usize);
        let mut receivers = Vec::with_capacity(shard_count as usize);

        for _ in 0..shard_count {
            let (tx, rx) = bounded(capacity);
            senders.push(tx);
            receivers.push(rx);
        }

        Self { senders, receivers }
    }

    pub fn sender(&self, shard_id: u32) -> &Sender<ShardMsg> {
        &self.senders[shard_id as usize]
    }

    pub fn receiver(&self, shard_id: u32) -> &Receiver<ShardMsg> {
        &self.receivers[shard_id as usize]
    }

    /// Try to send a message to a shard. Returns false if the channel is full.
    pub fn try_send(&self, shard_id: u32, msg: ShardMsg) -> bool {
        match self.senders[shard_id as usize].try_send(msg) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) => false,
            Err(TrySendError::Disconnected(_)) => false,
        }
    }

    pub fn shard_count(&self) -> u32 {
        self.senders.len() as u32
    }
}
```

- [ ] **Step 2: Add mod declaration and create registry in main.rs**

```rust
// platform/src/main.rs

mod config;
mod channels;
mod roc_glue;

use config::PlatformConfig;
use channels::ChannelRegistry;

fn main() {
    roc_glue::init();

    let config = PlatformConfig::default();
    let registry = ChannelRegistry::new(config.shard_count, config.channel_capacity);

    println!(
        "quine-graph platform: {} shards, channel capacity {}",
        registry.shard_count(),
        config.channel_capacity
    );

    // Smoke test: send a message to shard 0 and receive it
    let msg = vec![channels::TAG_SHARD_MSG, 0x01, 0x02, 0x03];
    assert!(registry.try_send(0, msg));
    let received = registry.receiver(0).try_recv().unwrap();
    assert_eq!(received[0], channels::TAG_SHARD_MSG);
    println!("channel smoke test passed");
}
```

- [ ] **Step 3: Verify it compiles and channel smoke test passes**

Run: `cd platform && cargo build && ./target/debug/quine-graph-platform`
Expected: "channel smoke test passed"

- [ ] **Step 4: Commit**

```bash
git add platform/src/channels.rs platform/src/main.rs
git commit -m "phase-3a: bounded crossbeam channels with ChannelRegistry"
```

---

## Task 7: Implement send_to_shard! host function

**Files:**
- Modify: `platform/src/roc_glue.rs`

This wires the `roc_fx_send_to_shard` function to the ChannelRegistry.
The challenge is that `roc_fx_*` functions are `extern "C"` with no `self`
parameter, so they need access to the global ChannelRegistry.

- [ ] **Step 1: Add global ChannelRegistry**

Add to `platform/src/roc_glue.rs`:

```rust
use crate::channels::ChannelRegistry;
use std::sync::OnceLock;

/// Global channel registry, set once at startup.
static CHANNEL_REGISTRY: OnceLock<ChannelRegistry> = OnceLock::new();

/// Initialize the global channel registry. Must be called before any Roc code
/// that uses send_to_shard!.
pub fn set_channel_registry(registry: ChannelRegistry) {
    CHANNEL_REGISTRY
        .set(registry)
        .expect("Channel registry already initialized");
}
```

- [ ] **Step 2: Implement roc_fx_send_to_shard**

Add to `platform/src/roc_glue.rs`:

```rust
/// Roc calls this for send_to_shard!(shard_id, msg_bytes).
/// Returns 0 on success, 1 if channel is full.
#[no_mangle]
pub extern "C" fn roc_fx_send_to_shard(shard_id: u32, msg_ptr: *const u8, msg_len: usize) -> u8 {
    let registry = CHANNEL_REGISTRY.get().expect("Channel registry not initialized");
    let msg_bytes = unsafe { std::slice::from_raw_parts(msg_ptr, msg_len) };

    // Prepend TAG_SHARD_MSG so the worker loop knows this is a regular message
    let mut tagged_msg = Vec::with_capacity(1 + msg_bytes.len());
    tagged_msg.push(crate::channels::TAG_SHARD_MSG);
    tagged_msg.extend_from_slice(msg_bytes);

    if registry.try_send(shard_id, tagged_msg) {
        0 // success
    } else {
        1 // channel full
    }
}
```

Note: Same caveat as `roc_fx_log` — if Roc passes `List U8` as `&RocList<u8>`
instead of raw pointer + length, adjust the signature accordingly.

- [ ] **Step 3: Register in init() and update main.rs**

Add `roc_fx_send_to_shard as _` to the `init()` function's `funcs` array.

Update `main.rs` to call `roc_glue::set_channel_registry(registry)` before
any Roc calls.

- [ ] **Step 4: Commit**

```bash
git add platform/src/roc_glue.rs platform/src/main.rs
git commit -m "phase-3a: send_to_shard! host function wired to channels"
```

---

## Task 8: Shard worker loop

**Files:**
- Create: `platform/src/shard_worker.rs`
- Modify: `platform/src/main.rs`

- [ ] **Step 1: Write shard_worker.rs**

```rust
// platform/src/shard_worker.rs

use crossbeam_channel::Receiver;
use crate::channels::{ShardMsg, TAG_SHARD_MSG, TAG_TIMER, TAG_PERSIST_RESULT};
use crate::roc_glue;

/// Run the recv-dispatch-drain loop for a single shard.
/// Spawned on a dedicated std::thread.
pub fn run_shard_worker(shard_id: u32, rx: Receiver<ShardMsg>) {
    // Initialize shard state via Roc
    let mut state = roc_glue::call_init_shard(shard_id);

    loop {
        match rx.recv() {
            Ok(msg) => {
                if msg.is_empty() {
                    continue;
                }

                match msg[0] {
                    TAG_TIMER => {
                        let timer_kind = msg.get(1).copied().unwrap_or(0);
                        state = roc_glue::call_on_timer(state, timer_kind);
                    }
                    TAG_PERSIST_RESULT => {
                        // Pass the full message (including tag) to handle_message
                        // The Roc side will decode it as a PersistenceResult
                        state = roc_glue::call_handle_message(state, &msg);
                    }
                    TAG_SHARD_MSG | _ => {
                        // Strip the tag byte, pass payload to handle_message
                        state = roc_glue::call_handle_message(state, &msg[1..]);
                    }
                }

                // TODO(Task 11): drain pending_effects from state
            }
            Err(_) => {
                // Channel closed — shutdown
                eprintln!("shard {} shutting down", shard_id);
                break;
            }
        }
    }
}
```

- [ ] **Step 2: Update main.rs to spawn shard workers**

```rust
// platform/src/main.rs

mod config;
mod channels;
mod roc_glue;
mod shard_worker;

use config::PlatformConfig;
use channels::ChannelRegistry;

fn main() {
    roc_glue::init();

    let config = PlatformConfig::default();
    let registry = ChannelRegistry::new(config.shard_count, config.channel_capacity);

    // Store registry globally for roc_fx_send_to_shard
    // We need to clone receivers before moving registry into the global
    let receivers: Vec<_> = (0..config.shard_count)
        .map(|i| registry.receiver(i).clone())
        .collect();

    roc_glue::set_channel_registry(registry);

    // Spawn one worker thread per shard
    let mut handles = Vec::new();
    for (shard_id, rx) in receivers.into_iter().enumerate() {
        let handle = std::thread::spawn(move || {
            shard_worker::run_shard_worker(shard_id as u32, rx);
        });
        handles.push(handle);
    }

    eprintln!(
        "quine-graph platform running: {} shards",
        config.shard_count
    );

    // Keep main thread alive until all workers finish
    for handle in handles {
        handle.join().expect("shard worker panicked");
    }
}
```

- [ ] **Step 3: Rebuild and test with hello-platform app**

Run:
```bash
roc build --lib app/hello-platform.roc --output platform/libapp.a && \
cd platform && cargo build && \
timeout 5 ./target/debug/quine-graph-platform || true
```

Expected: Output showing 4 shards initializing via log! calls. The process
will block on channel recv (no messages to process), so use `timeout`.

- [ ] **Step 4: Commit**

```bash
git add platform/src/shard_worker.rs platform/src/main.rs
git commit -m "phase-3a: shard worker recv-dispatch loop on std::thread"
```

---

## Task 9: Timer wheel (tokio)

**Files:**
- Create: `platform/src/timer.rs`
- Modify: `platform/src/main.rs`

- [ ] **Step 1: Write timer.rs**

```rust
// platform/src/timer.rs

use crossbeam_channel::Sender;
use std::time::Duration;
use crate::channels::{ShardMsg, TAG_TIMER};

/// Timer kind constants, matched by Roc's on_timer!
pub const TIMER_CHECK_LRU: u8 = 0;
pub const TIMER_ASK_TIMEOUT: u8 = 1;

/// Start LRU check timers for all shards on a tokio runtime.
/// Each shard gets a periodic timer that sends CheckLru messages
/// to its channel.
pub fn start_lru_timers(
    shard_senders: Vec<Sender<ShardMsg>>,
    interval_ms: u64,
) -> tokio::runtime::Runtime {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .expect("Failed to create tokio runtime for timers");

    let interval = Duration::from_millis(interval_ms);

    for (shard_id, tx) in shard_senders.into_iter().enumerate() {
        rt.spawn(async move {
            let mut interval_timer = tokio::time::interval(interval);
            // Skip the first tick (fires immediately)
            interval_timer.tick().await;

            loop {
                interval_timer.tick().await;
                let timer_msg = vec![TAG_TIMER, TIMER_CHECK_LRU];
                if tx.send(timer_msg).is_err() {
                    eprintln!("timer: shard {} channel closed", shard_id);
                    break;
                }
            }
        });
    }

    rt
}
```

- [ ] **Step 2: Update main.rs to start timers**

Add after spawning shard workers, before the join loop:

```rust
    // Collect senders for timer threads
    let timer_senders: Vec<_> = {
        let reg = roc_glue::channel_registry();
        (0..config.shard_count)
            .map(|i| reg.sender(i).clone())
            .collect()
    };

    // Start LRU check timers on a dedicated tokio runtime
    let _timer_rt = timer::start_lru_timers(timer_senders, config.lru_check_interval_ms);
```

Add `mod timer;` to the module declarations.

Also add a `pub fn channel_registry() -> &'static ChannelRegistry` accessor
to `roc_glue.rs`:

```rust
pub fn channel_registry() -> &'static ChannelRegistry {
    CHANNEL_REGISTRY.get().expect("Channel registry not initialized")
}
```

- [ ] **Step 3: Write platform-test-timer.roc**

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

import pf.Effect

ShardState : { shard_id : U32, timer_count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "shard $(Num.to_str(shard_id)) ready, waiting for timers...")
    { shard_id, timer_count: 0 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, _msg|
    state

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, kind|
    new_count = state.timer_count + 1
    Effect.log!(2, "shard $(Num.to_str(state.shard_id)) timer #$(Num.to_str(new_count)) kind=$(Num.to_str(kind))")
    { state & timer_count: new_count }
```

- [ ] **Step 4: Build and test (with short timer interval)**

Temporarily change `lru_check_interval_ms` default to `1_000` (1 second)
in `config.rs` for testing. Then:

Run:
```bash
roc build --lib app/platform-test-timer.roc --output platform/libapp.a && \
cd platform && cargo build && \
timeout 5 ./target/debug/quine-graph-platform
```

Expected: Each shard logs timer ticks approximately once per second.
Restore `lru_check_interval_ms` to `10_000` after verifying.

- [ ] **Step 5: Commit**

```bash
git add platform/src/timer.rs platform/src/main.rs app/platform-test-timer.roc
git commit -m "phase-3a: tokio timer wheel for CheckLru ticks"
```

---

## Task 10: Persistence I/O pool and persist_async!

**Files:**
- Create: `platform/src/persistence_io.rs`
- Modify: `platform/src/roc_glue.rs`

- [ ] **Step 1: Write persistence_io.rs**

```rust
// platform/src/persistence_io.rs

use crossbeam_channel::Sender;
use std::sync::atomic::{AtomicU64, Ordering};
use crate::channels::{ShardMsg, TAG_PERSIST_RESULT};

static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

pub fn next_request_id() -> u64 {
    NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
}

/// A persistence command from a shard.
pub struct PersistCommand {
    pub request_id: u64,
    pub shard_id: u32,
    pub payload: Vec<u8>,
}

/// Start the persistence I/O pool. Commands arrive on the returned sender.
/// Results are routed back to shard channels via `shard_senders`.
pub fn start_persistence_pool(
    shard_senders: Vec<Sender<ShardMsg>>,
    rt: &tokio::runtime::Runtime,
) -> Sender<PersistCommand> {
    let (cmd_tx, cmd_rx) = crossbeam_channel::bounded::<PersistCommand>(4096);

    let senders = shard_senders;
    rt.spawn(async move {
        // Process persistence commands on the tokio runtime
        loop {
            match cmd_rx.recv() {
                Ok(cmd) => {
                    // For Phase 3a: immediately return a success result.
                    // The actual persistence backend (Phase 2 persistor) will
                    // be wired in a later phase.
                    let result_msg = encode_persist_result(cmd.request_id);

                    if let Some(tx) = senders.get(cmd.shard_id as usize) {
                        let _ = tx.send(result_msg);
                    }
                }
                Err(_) => break, // All senders dropped
            }
        }
    });

    cmd_tx
}

fn encode_persist_result(request_id: u64) -> ShardMsg {
    let mut msg = Vec::with_capacity(1 + 8);
    msg.push(TAG_PERSIST_RESULT);
    msg.extend_from_slice(&request_id.to_le_bytes());
    msg
}
```

- [ ] **Step 2: Implement roc_fx_persist_async**

Add to `platform/src/roc_glue.rs`:

```rust
use crate::persistence_io::{self, PersistCommand};

static PERSIST_SENDER: OnceLock<crossbeam_channel::Sender<PersistCommand>> = OnceLock::new();

pub fn set_persist_sender(tx: crossbeam_channel::Sender<PersistCommand>) {
    PERSIST_SENDER
        .set(tx)
        .expect("Persist sender already initialized");
}

/// Roc calls this for persist_async!(command_bytes).
/// Returns a request ID that will arrive later as a PersistenceResult.
#[no_mangle]
pub extern "C" fn roc_fx_persist_async(cmd_ptr: *const u8, cmd_len: usize) -> u64 {
    let request_id = persistence_io::next_request_id();
    let payload = unsafe { std::slice::from_raw_parts(cmd_ptr, cmd_len) }.to_vec();

    let cmd = PersistCommand {
        request_id,
        shard_id: 0, // TODO: need shard context — see note below
        payload,
    };

    if let Some(tx) = PERSIST_SENDER.get() {
        let _ = tx.send(cmd);
    }

    request_id
}
```

Note: `persist_async!` needs to know which shard is calling so it can route
the result back. Options:
- Thread-local shard ID (set at the start of each worker loop iteration)
- Additional parameter in the Roc signature
- Encode shard_id in the command payload (Roc side)

Thread-local is simplest. Add to `shard_worker.rs`:

```rust
thread_local! {
    static CURRENT_SHARD_ID: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

pub fn set_current_shard_id(id: u32) {
    CURRENT_SHARD_ID.with(|cell| cell.set(id));
}

pub fn current_shard_id() -> u32 {
    CURRENT_SHARD_ID.with(|cell| cell.get())
}
```

Then in `roc_fx_persist_async`, use `crate::shard_worker::current_shard_id()`.
And in the worker loop, call `set_current_shard_id(shard_id)` before each
Roc call.

- [ ] **Step 3: Register and wire up**

Add `roc_fx_persist_async as _` to `init()`.
In `main.rs`, start the persistence pool and call `set_persist_sender`.

- [ ] **Step 4: Commit**

```bash
git add platform/src/persistence_io.rs platform/src/roc_glue.rs \
    platform/src/shard_worker.rs platform/src/main.rs
git commit -m "phase-3a: persistence I/O pool and persist_async! host function"
```

---

## Task 11: Effect executor

**Files:**
- Create: `platform/src/effects.rs`
- Modify: `platform/src/shard_worker.rs`

This task wires up the effect drain loop. After each Roc call, the host
reads `pending_effects` from the ShardState and routes each effect.

In the hybrid FFI approach, effects are encoded as `List U8` within
ShardState. The host reads tag bytes to determine what to do.

- [ ] **Step 1: Write effects.rs**

```rust
// platform/src/effects.rs

use crate::channels::ChannelRegistry;
use crate::persistence_io::PersistCommand;
use crate::roc_glue;
use crate::shard_worker;

/// Effect tag bytes — must match the Roc Encode implementation.
/// These are provisional and will be adjusted once the Roc encoding
/// is verified.
pub const EFFECT_REPLY: u8 = 0x01;
pub const EFFECT_SEND_TO_NODE: u8 = 0x02;
pub const EFFECT_SEND_TO_SHARD: u8 = 0x03;
pub const EFFECT_PERSIST: u8 = 0x04;
pub const EFFECT_BACKPRESSURE: u8 = 0x05;
pub const EFFECT_UPDATE_COST: u8 = 0x06;

/// Drain and execute all pending effects from the ShardState.
///
/// In the hybrid FFI approach, we cannot directly read the effects from
/// the opaque ShardState pointer. Instead, the Roc side encodes effects
/// into a `List U8` field that the host reads via a known offset.
///
/// For Phase 3a, this is a placeholder that will be filled in once the
/// effect encoding format is established between the Roc graph layer
/// and the platform.
pub fn drain_effects(_state: *mut u8, _shard_id: u32) {
    // Phase 3a placeholder:
    // The full effect executor requires knowing the memory layout of
    // ShardState (specifically, where the pending_effects field is).
    // This will be wired when the Phase 3b graph layer is connected
    // to the platform.
    //
    // For now, effects produced by the hello-platform and test apps
    // are no-ops (those apps don't produce effects beyond log!,
    // which is handled directly as a host function).
}
```

- [ ] **Step 2: Wire into shard_worker.rs**

Replace the `// TODO(Task 11)` comment in `shard_worker.rs`:

```rust
                // Drain and execute any effects the Roc dispatch produced
                crate::effects::drain_effects(state, shard_id);
```

- [ ] **Step 3: Commit**

```bash
git add platform/src/effects.rs platform/src/shard_worker.rs
git commit -m "phase-3a: effect executor skeleton (placeholder for Phase 3b wiring)"
```

---

## Task 12: Echo test app — full integration test

**Files:**
- Create: `app/platform-test-echo.roc`

- [ ] **Step 1: Write platform-test-echo.roc**

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

import pf.Effect

ShardState : { shard_id : U32, msg_count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "echo shard $(Num.to_str(shard_id)) initialized")
    { shard_id, msg_count: 0 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, msg|
    new_count = state.msg_count + 1
    msg_len = List.len(msg) |> Num.to_str
    Effect.log!(2, "echo shard $(Num.to_str(state.shard_id)): msg #$(Num.to_str(new_count)) ($(msg_len) bytes)")

    # Echo: send the message to the next shard (round-robin)
    next_shard = Num.rem(state.shard_id + 1, 4)
    when Effect.send_to_shard!(next_shard, msg) is
        Ok({}) ->
            Effect.log!(3, "  forwarded to shard $(Num.to_str(next_shard))")
        Err(ChannelFull) ->
            Effect.log!(1, "  channel full on shard $(Num.to_str(next_shard))")

    { state & msg_count: new_count }

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    Effect.log!(2, "echo shard $(Num.to_str(state.shard_id)): $(Num.to_str(state.msg_count)) messages processed")
    state
```

- [ ] **Step 2: Build and run**

Run:
```bash
roc build --lib app/platform-test-echo.roc --output platform/libapp.a && \
cd platform && cargo build && \
timeout 5 ./target/debug/quine-graph-platform
```

Expected: 4 shards initialize, timer ticks fire, message counts logged.
The echo forwarding creates a chain of messages between shards.

- [ ] **Step 3: Commit**

```bash
git add app/platform-test-echo.roc
git commit -m "phase-3a: echo test app — full shard integration"
```

---

## Task 13: Backpressure test app

**Files:**
- Create: `app/platform-test-backpressure.roc`

- [ ] **Step 1: Write platform-test-backpressure.roc**

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

import pf.Effect

ShardState : { shard_id : U32, sent : U64, full_count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "backpressure test shard $(Num.to_str(shard_id)) ready")

    # Shard 0 floods shard 1 on init
    if shard_id == 0 then
        result = flood_shard!(1, 0, 0)
        Effect.log!(2, "shard 0 sent $(Num.to_str(result.sent)), full $(Num.to_str(result.full_count))")
        { shard_id, sent: result.sent, full_count: result.full_count }
    else
        { shard_id, sent: 0, full_count: 0 }

flood_shard! : U32, U64, U64 => { sent : U64, full_count : U64 }
flood_shard! = |target, sent, full_count|
    if sent >= 10_000 then
        { sent, full_count }
    else
        msg = [0x42] # 1-byte dummy message
        when Effect.send_to_shard!(target, msg) is
            Ok({}) -> flood_shard!(target, sent + 1, full_count)
            Err(ChannelFull) ->
                Effect.log!(1, "ChannelFull after $(Num.to_str(sent)) sends")
                { sent, full_count: full_count + 1 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, _msg| state

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind| state
```

- [ ] **Step 2: Build and run**

Run:
```bash
roc build --lib app/platform-test-backpressure.roc --output platform/libapp.a && \
cd platform && cargo build && \
timeout 5 ./target/debug/quine-graph-platform
```

Expected: Shard 0 sends messages until the channel fills (at capacity 4096),
then logs "ChannelFull after 4096 sends".

- [ ] **Step 3: Commit**

```bash
git add app/platform-test-backpressure.roc
git commit -m "phase-3a: backpressure test — verify channel full behavior"
```

---

## Task 14: Persistence test app

**Files:**
- Create: `app/platform-test-persist.roc`

- [ ] **Step 1: Write platform-test-persist.roc**

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

import pf.Effect

ShardState : { shard_id : U32, pending_request : [None, Waiting U64] }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "persist test shard $(Num.to_str(shard_id)) ready")

    # Shard 0 sends a persistence command on init
    if shard_id == 0 then
        request_id = Effect.persist_async!([0x01, 0x02, 0x03])
        Effect.log!(2, "shard 0: persist_async! returned request_id=$(Num.to_str(request_id))")
        { shard_id, pending_request: Waiting(request_id) }
    else
        { shard_id, pending_request: None }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, msg|
    # Check if this is a persistence result (tag 0xFE)
    when List.first(msg) is
        Ok(0xFE) ->
            Effect.log!(2, "shard $(Num.to_str(state.shard_id)): received persist result ($(Num.to_str(List.len(msg))) bytes)")
            { state & pending_request: None }
        _ ->
            state

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind| state
```

- [ ] **Step 2: Build and run**

Run:
```bash
roc build --lib app/platform-test-persist.roc --output platform/libapp.a && \
cd platform && cargo build && \
timeout 5 ./target/debug/quine-graph-platform
```

Expected: Shard 0 sends a persist command, receives a result back with
the request ID.

- [ ] **Step 3: Commit**

```bash
git add app/platform-test-persist.roc
git commit -m "phase-3a: persistence round-trip test"
```

---

## Task 15: Final wiring and cleanup

**Files:**
- Modify: `platform/src/main.rs`
- Modify: `platform/src/config.rs`

- [ ] **Step 1: Add CLI argument parsing for shard_count**

Update `main.rs` to accept `--shards N` from command line:

```rust
fn parse_config() -> PlatformConfig {
    let mut config = PlatformConfig::default();
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--shards" => {
                i += 1;
                if let Some(n) = args.get(i) {
                    config.shard_count = n.parse().expect("--shards must be a number");
                }
            }
            "--channel-capacity" => {
                i += 1;
                if let Some(n) = args.get(i) {
                    config.channel_capacity = n.parse().expect("--channel-capacity must be a number");
                }
            }
            _ => {}
        }
        i += 1;
    }
    config
}
```

- [ ] **Step 2: Verify all test apps work**

Run each test app:
```bash
# Echo test
roc build --lib app/platform-test-echo.roc --output platform/libapp.a && \
cd platform && cargo build && timeout 5 ./target/debug/quine-graph-platform; cd ..

# Timer test
roc build --lib app/platform-test-timer.roc --output platform/libapp.a && \
cd platform && cargo build && timeout 5 ./target/debug/quine-graph-platform; cd ..

# Backpressure test
roc build --lib app/platform-test-backpressure.roc --output platform/libapp.a && \
cd platform && cargo build && timeout 5 ./target/debug/quine-graph-platform; cd ..

# Persistence test
roc build --lib app/platform-test-persist.roc --output platform/libapp.a && \
cd platform && cargo build && timeout 5 ./target/debug/quine-graph-platform; cd ..
```

Expected: All four apps produce expected output.

- [ ] **Step 3: Commit**

```bash
git add platform/src/main.rs platform/src/config.rs
git commit -m "phase-3a: CLI args and final wiring"
```

---

## Task 16: Documentation — commit ADR-017

**Files:**
- Already created: `.claude/plans/quine-roc-port/docs/src/adrs/phase-3/0017-custom-roc-platform.md`
- Already updated: `.claude/plans/quine-roc-port/docs/src/adrs/phase-3/0016-shard-managed-event-loops.md`
- Already created: `.claude/plans/quine-roc-port/refs/analysis/threading-distribution-matrix.md`

- [ ] **Step 1: Verify all docs are staged**

```bash
git add .claude/plans/quine-roc-port/docs/src/adrs/phase-3/0017-custom-roc-platform.md
git add .claude/plans/quine-roc-port/docs/src/adrs/phase-3/0016-shard-managed-event-loops.md
git add .claude/plans/quine-roc-port/refs/analysis/threading-distribution-matrix.md
git add .claude/plans/quine-roc-port/refs/specs/phase-3a-custom-roc-platform.md
```

- [ ] **Step 2: Commit**

```bash
git commit -m "phase-3a: ADR-016 update, ADR-017, threading analysis, and spec"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Shard worker threads (std::thread) → Tasks 8, 15
- [x] Bounded crossbeam channels → Task 6
- [x] Timer wheel (tokio) → Task 9
- [x] Persistence I/O pool → Task 10
- [x] current_time! → Task 5
- [x] log! → Task 5
- [x] send_to_shard! → Task 7
- [x] persist_async! → Task 10
- [x] Platform declaration (main.roc, Host.roc, Effect.roc) → Task 3
- [x] Memory callbacks (roc_alloc, roc_dealloc) → Task 2
- [x] Roc ABI glue (Box Model, refcount pinning) → Task 4
- [x] Effect executor (drain pending_effects) → Task 11
- [x] PlatformConfig → Tasks 1, 15
- [x] Build pipeline (prebuilt host, Option 2) → Tasks 1, 4
- [x] Hello world verification → Task 4
- [x] Test apps: echo, timer, backpressure, persist → Tasks 12-14
- [x] ADR-017 → Task 16
- [x] ADR-016 update → Task 16
- [x] Threading/distribution analysis → Task 16

**Placeholder scan:**
- Task 4 Step 5: ABI debugging instructions are specific (nm, link_name, etc.)
- Task 11: drain_effects is explicitly a placeholder, clearly documented
- No TBD/TODO without explanation

**Type consistency:**
- `ShardMsg = Vec<u8>` consistent across channels.rs, shard_worker.rs, timer.rs
- `*mut u8` for ShardState pointer consistent across roc_glue.rs, shard_worker.rs
- Tag bytes (TAG_SHARD_MSG=0x01, TAG_TIMER=0xFF, TAG_PERSIST_RESULT=0xFE) consistent
- `PlatformConfig` fields consistent between config.rs and usage in main.rs
