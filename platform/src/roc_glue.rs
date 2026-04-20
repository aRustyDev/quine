// platform/src/roc_glue.rs

use roc_std::{RocBox, RocList, RocStr};
use std::ffi::c_void;
use std::sync::OnceLock;

use crate::channels::ChannelRegistry;
use crate::persistence_io::{self, PersistCommand};

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
// Signatures match basic-cli/basic-webserver: &RocStr, not raw ptr+len.
// ============================================================

#[no_mangle]
pub unsafe extern "C" fn roc_panic(msg: &RocStr, tag_id: u32) {
    match tag_id {
        0 => {
            eprintln!("Roc crashed with:\n\n\t{}\n", msg.as_str());
        }
        _ => {
            eprintln!("Roc crashed with tag {}:\n\n\t{}\n", tag_id, msg.as_str());
        }
    }
    std::process::exit(1);
}

#[no_mangle]
pub unsafe extern "C" fn roc_dbg(loc: &RocStr, msg: &RocStr, src: &RocStr) {
    eprintln!("[{}] {} = {}", loc.as_str(), src.as_str(), msg.as_str());
}

#[no_mangle]
pub unsafe extern "C" fn roc_memset(dst: *mut c_void, c: i32, n: usize) -> *mut c_void {
    libc::memset(dst, c, n)
}

// ============================================================
// Roc function declarations — the compiled Roc app exports these.
//
// Symbol naming convention: roc__<fn_name>_1_exposed_generic
//   - Uses output-pointer-first calling convention
//   - First arg is a pointer where the return value is written
//
// Also available: roc__<fn_name>_1_exposed (direct return for small types)
//   - Returns the value directly (for types that fit in registers)
//
// And: roc__<fn_name>_1_exposed_size (returns the byte size of the return type)
//
// Verified via `nm platform/libapp.dylib | grep roc__`:
//   _roc__init_shard_for_host_1_exposed_generic
//   _roc__init_shard_for_host_1_exposed
//   _roc__init_shard_for_host_1_exposed_size
//   _roc__handle_message_for_host_1_exposed_generic
//   _roc__handle_message_for_host_1_exposed
//   _roc__handle_message_for_host_1_exposed_size
//   _roc__on_timer_for_host_1_exposed_generic
//   _roc__on_timer_for_host_1_exposed
//   _roc__on_timer_for_host_1_exposed_size
// ============================================================

extern "C" {
    /// init_shard_for_host!(shard_id: U32) => Box ShardState
    /// Returns RocBox<()> (8 bytes, fits in a register).
    /// Following basic-webserver pattern: _exposed variant returns directly.
    #[link_name = "roc__init_shard_for_host_1_exposed"]
    fn roc_init_shard_for_host(shard_id: u32) -> RocBox<()>;

    /// handle_message_for_host!(Box ShardState, List U8) => Box ShardState
    /// Uses _exposed_generic (output-pointer-first) because List U8 is a
    /// 24-byte struct that may affect calling convention.
    #[link_name = "roc__handle_message_for_host_1_exposed_generic"]
    fn roc_handle_message_for_host(
        output: *mut RocBox<()>,
        boxed_state: RocBox<()>,
        msg: *const RocList<u8>,
    );

    /// on_timer_for_host!(Box ShardState, U8) => Box ShardState
    #[link_name = "roc__on_timer_for_host_1_exposed_generic"]
    fn roc_on_timer_for_host(output: *mut RocBox<()>, boxed_state: RocBox<()>, timer_kind: u8);
}

// ============================================================
// Refcount pinning — kingfisher/basic-webserver pattern.
//
// Roc uses reference counting for heap values. RocBox stores the
// refcount at (data_ptr - alloc_alignment). Setting refcount to 0
// (Storage::Readonly) means "host-owned — don't touch the refcount."
// This prevents Roc from freeing state between host calls.
//
// We use RocBox::as_refcount_ptr() which computes the correct offset
// via alloc_alignment, rather than raw pointer arithmetic.
// ============================================================

/// Pin the refcount of a RocBox to Readonly (0), preventing Roc GC.
/// Callers must ensure the RocBox remains valid for the host's lifetime.
unsafe fn pin_refcount(boxed: &RocBox<()>) {
    let rc_ptr = boxed.as_refcount_ptr() as *mut usize;
    *rc_ptr = 0;
}

// ============================================================
// Safe wrappers for calling Roc functions.
// ============================================================

/// Call Roc's init_shard!(shard_id) and return the boxed ShardState.
pub fn call_init_shard(shard_id: u32) -> RocBox<()> {
    unsafe {
        let result = roc_init_shard_for_host(shard_id);
        pin_refcount(&result);
        result
    }
}

/// Call Roc's handle_message!(state, msg) and return the new boxed ShardState.
pub fn call_handle_message(state: RocBox<()>, msg: &[u8]) -> RocBox<()> {
    unsafe {
        let roc_msg = RocList::from_slice(msg);
        let mut output = std::mem::MaybeUninit::<RocBox<()>>::uninit();
        roc_handle_message_for_host(output.as_mut_ptr(), state, &roc_msg);
        let output = output.assume_init();
        pin_refcount(&output);
        output
    }
}

/// Call Roc's on_timer!(state, timer_kind) and return the new boxed ShardState.
pub fn call_on_timer(state: RocBox<()>, timer_kind: u8) -> RocBox<()> {
    unsafe {
        let mut output = std::mem::MaybeUninit::<RocBox<()>>::uninit();
        roc_on_timer_for_host(output.as_mut_ptr(), state, timer_kind);
        let output = output.assume_init();
        pin_refcount(&output);
        output
    }
}

// ============================================================
// Global channel registry — used by roc_fx_send_to_shard.
// ============================================================

/// Global channel registry, set once at startup.
static CHANNEL_REGISTRY: OnceLock<ChannelRegistry> = OnceLock::new();

/// Initialize the global channel registry. Must be called before any Roc code
/// that uses send_to_shard!.
pub fn set_channel_registry(registry: ChannelRegistry) {
    if CHANNEL_REGISTRY.set(registry).is_err() {
        panic!("Channel registry already initialized");
    }
}

/// Get a reference to the global channel registry.
pub fn channel_registry() -> &'static ChannelRegistry {
    CHANNEL_REGISTRY
        .get()
        .expect("Channel registry not initialized")
}

// ============================================================
// Global persistence command sender — used by roc_fx_persist_async.
// ============================================================

static PERSIST_SENDER: OnceLock<crossbeam_channel::Sender<PersistCommand>> = OnceLock::new();

/// Set the global persistence command sender. Must be called before any
/// Roc code that uses persist_async!.
pub fn set_persist_sender(tx: crossbeam_channel::Sender<PersistCommand>) {
    if PERSIST_SENDER.set(tx).is_err() {
        panic!("Persist sender already initialized");
    }
}

/// Check if the persist sender has been initialized.
pub fn persist_sender_ready() -> bool {
    PERSIST_SENDER.get().is_some()
}

// ============================================================
// Host-provided effect functions — Roc calls these via roc_fx_*.
//
// Calling convention (verified from Zig host and nm output):
//   - Str args are passed as &RocStr (pointer to RocStr struct)
//   - List U8 args are passed as &RocList<u8> (pointer to RocList struct)
//   - Scalar args (U8, U32, U64) are passed directly by value
//   - Scalar returns (U8, U64) are returned directly
//   - {} return is void (no return value)
// ============================================================

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
        roc_fx_send_to_shard as _,
        roc_fx_persist_async as _,
    ];
    #[allow(forgetting_references)]
    std::mem::forget(std::hint::black_box(funcs));
}

/// Get the current wall-clock time in milliseconds since epoch.
/// Roc signature: current_time! : {} => U64
#[no_mangle]
pub extern "C" fn roc_fx_current_time() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// Emit a structured log message.
/// Roc signature: log! : U8, Str => {}
/// Roc passes Str as &RocStr (verified from test-platform-effects-zig pattern).
#[no_mangle]
pub extern "C" fn roc_fx_log(level: u8, msg: &RocStr) {
    let level_str = match level {
        0 => "ERROR",
        1 => "WARN",
        2 => "INFO",
        3 => "DEBUG",
        _ => "TRACE",
    };
    eprintln!("[{}] {}", level_str, msg.as_str());
}

/// Send a message to a shard's input channel.
/// Roc signature: send_to_shard! : U32, List U8 => U8
/// Returns 0 on success, 1 if the channel is full.
/// Roc passes List U8 as &RocList<u8> (verified from Zig host pattern).
#[no_mangle]
pub extern "C" fn roc_fx_send_to_shard(shard_id: u32, msg: &RocList<u8>) -> u8 {
    let registry = CHANNEL_REGISTRY
        .get()
        .expect("Channel registry not initialized");

    let msg_bytes = msg.as_slice();

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

/// Dispatch an async persistence command.
/// Roc signature: persist_async! : List U8 => U64
/// Returns a request ID. The persistence result will arrive later as a
/// message on the calling shard's channel (tagged TAG_PERSIST_RESULT).
///
/// Uses thread-local shard ID (set by shard_worker) to route the result
/// back to the correct shard.
#[no_mangle]
pub extern "C" fn roc_fx_persist_async(cmd: &RocList<u8>) -> u64 {
    let request_id = persistence_io::next_request_id();
    let shard_id = crate::shard_worker::current_shard_id();
    let payload = cmd.as_slice().to_vec();

    let command = PersistCommand {
        request_id,
        shard_id,
        payload,
    };

    if let Some(tx) = PERSIST_SENDER.get() {
        if tx.send(command).is_err() {
            eprintln!(
                "persist_async: failed to send command (pool shutdown?), shard={}",
                shard_id
            );
        }
    } else {
        eprintln!("persist_async: persist sender not initialized");
    }

    request_id
}
