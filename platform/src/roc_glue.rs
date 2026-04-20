// platform/src/roc_glue.rs

use roc_std::{RocBox, RocList, RocStr};
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
