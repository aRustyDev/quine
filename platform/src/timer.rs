// platform/src/timer.rs

use crossbeam_channel::Sender;
use crate::channels::{ShardMsg, TAG_TIMER};

/// Start LRU check timers for all shards.
///
/// Creates a single-threaded tokio runtime. For each shard, spawns an
/// interval task that sends [TAG_TIMER, 0x00] (CheckLru) to the shard's
/// channel at the configured interval.
///
/// Returns the tokio Runtime. Caller must keep it alive — dropping stops all timers.
pub fn start_lru_timers(
    senders: Vec<Sender<ShardMsg>>,
    interval_ms: u64,
) -> tokio::runtime::Runtime {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime for timers");

    for (shard_id, sender) in senders.into_iter().enumerate() {
        rt.spawn(timer_task(shard_id, sender, interval_ms));
    }

    rt
}

/// A single timer task: ticks at `interval_ms` and sends TAG_TIMER to the shard.
async fn timer_task(shard_id: usize, sender: Sender<ShardMsg>, interval_ms: u64) {
    let mut interval = tokio::time::interval(std::time::Duration::from_millis(interval_ms));

    // The first tick completes immediately — skip it so the first real
    // timer fires after one full interval.
    interval.tick().await;

    loop {
        interval.tick().await;
        // 0x00 = CheckLru timer kind
        let msg = vec![TAG_TIMER, 0x00];
        if sender.send(msg).is_err() {
            eprintln!("timer: shard {} channel closed, stopping timer", shard_id);
            break;
        }
    }
}
