// platform/src/effects.rs
//
// Effect executor — drains pending effects from ShardState after each Roc call.
//
// In the hybrid FFI approach, the host cannot directly read fields from the
// opaque ShardState pointer without knowing its memory layout. That layout is
// determined by the Roc compiler and is not stable across platform changes.
//
// Phase 3a approach: effects are dispatched *eagerly* via direct host calls
// (roc_fx_send_to_shard, roc_fx_persist_async, etc.) rather than being
// buffered in ShardState. This avoids the layout problem entirely.
//
// Phase 3b wiring: once the graph layer encodes effects as a List U8 field
// in ShardState (with a stable known offset), drain_effects will accept the
// RocBox pointer and read that field, routing each effect by tag byte.
// The constants below define the tag byte assignments for when that
// encoding is implemented.

/// Effect tag bytes — must match the Roc Encode implementation in Phase 3b.
/// Provisional values; finalize when the graph layer effect encoding is set.
pub const EFFECT_REPLY: u8 = 0x01;
pub const EFFECT_SEND_TO_NODE: u8 = 0x02;
pub const EFFECT_SEND_TO_SHARD: u8 = 0x03;
pub const EFFECT_PERSIST: u8 = 0x04;
pub const EFFECT_BACKPRESSURE: u8 = 0x05;
pub const EFFECT_UPDATE_COST: u8 = 0x06;

/// Drain and execute all pending effects produced by a Roc dispatch call.
///
/// Phase 3a: no-op placeholder. Effects are dispatched eagerly through
/// roc_fx_* host calls (send_to_shard!, persist_async!, log!, current_time!),
/// so there is nothing to drain from the state after the call returns.
///
/// Phase 3b wiring steps:
/// 1. Change signature to accept `state: &roc_std::RocBox<()>`
/// 2. Establish the byte offset of `pending_effects : List U8` within ShardState
///    (export an accessor from the Roc platform, or derive from layout rules)
/// 3. Read the RocList<u8> at that offset via unsafe pointer arithmetic
/// 4. Iterate encoded effects and dispatch by EFFECT_* tag byte:
///    - EFFECT_SEND_TO_SHARD  → crate::roc_glue::channel_registry().try_send(...)
///    - EFFECT_PERSIST        → route to persistence pool via PERSIST_SENDER
///    - EFFECT_REPLY          → send response back to caller shard
///    - EFFECT_BACKPRESSURE   → signal caller that target is at capacity
///    - EFFECT_UPDATE_COST    → update LRU cost for eviction
/// 5. Clear the list so effects are not executed twice
#[allow(unused_variables)]
pub fn drain_effects(shard_id: u32) {
    // Phase 3a: effects are handled inline by roc_fx_* calls during
    // Roc execution. Nothing to drain post-call.
}
