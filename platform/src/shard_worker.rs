// platform/src/shard_worker.rs

use crossbeam_channel::Receiver;

use crate::channels::{ShardMsg, TAG_PERSIST_RESULT, TAG_SHARD_MSG, TAG_TIMER};
use crate::roc_glue;

// ============================================================
// Thread-local shard ID — allows roc_fx_persist_async to know
// which shard is calling without an extra parameter.
// ============================================================

thread_local! {
    static CURRENT_SHARD_ID: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

pub fn set_current_shard_id(id: u32) {
    CURRENT_SHARD_ID.with(|cell| cell.set(id));
}

pub fn current_shard_id() -> u32 {
    CURRENT_SHARD_ID.with(|cell| cell.get())
}

// ============================================================
// Shard worker — recv-dispatch loop on a dedicated std::thread.
// ============================================================

/// Run the recv-dispatch loop for a single shard.
/// Spawned on a dedicated std::thread. Blocks forever on recv
/// until the channel is closed.
pub fn run_shard_worker(shard_id: u32, rx: Receiver<ShardMsg>) {
    // Set thread-local shard ID so host functions (persist_async!) know the caller
    set_current_shard_id(shard_id);

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
                    TAG_SHARD_MSG | TAG_PERSIST_RESULT => {
                        state = roc_glue::call_handle_message(state, &msg);
                    }
                    _ => {
                        // Unknown tag — log and skip
                        eprintln!(
                            "shard {}: unknown message tag 0x{:02X}, dropping",
                            shard_id, msg[0]
                        );
                    }
                }

                // Drain and execute any effects the Roc dispatch produced.
                // Phase 3a: no-op (effects dispatched eagerly via roc_fx_*).
                // Phase 3b: will read pending_effects List U8 from ShardState.
                crate::effects::drain_effects(shard_id);
            }
            Err(_) => {
                // Channel closed — shutdown
                eprintln!("shard {} shutting down", shard_id);
                break;
            }
        }
    }
}
