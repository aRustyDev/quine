// platform/src/main.rs

mod channels;
mod config;
mod effects;
mod persistence_io;
mod roc_glue;
mod shard_worker;
mod timer;

use channels::ChannelRegistry;
use config::PlatformConfig;

fn main() {
    roc_glue::init();

    let config = parse_config();
    let registry = ChannelRegistry::new(config.shard_count, config.channel_capacity);

    eprintln!(
        "quine-graph platform: {} shards, channel capacity {}",
        registry.shard_count(),
        config.channel_capacity
    );

    // Clone receivers before moving registry into the global OnceLock.
    // crossbeam Receiver is Clone (it's an Arc internally), so this is cheap.
    let receivers: Vec<_> = (0..config.shard_count)
        .map(|i| registry.receiver(i).clone())
        .collect();

    // Store registry globally for roc_fx_send_to_shard
    roc_glue::set_channel_registry(registry);

    // Start persistence I/O pool on a dedicated tokio runtime thread.
    // Must be set up before shard workers start (workers call persist_async!).
    let persist_senders: Vec<_> = {
        let reg = roc_glue::channel_registry();
        (0..config.shard_count)
            .map(|i| reg.sender(i).clone())
            .collect()
    };
    let _persist_rt = std::thread::Builder::new()
        .name("persist-runtime".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("Failed to create tokio runtime for persistence");
            let _cmd_tx = persistence_io::start_persistence_pool(persist_senders, &rt);
            // Store the command sender globally before blocking
            roc_glue::set_persist_sender(_cmd_tx);
            rt.block_on(std::future::pending::<()>());
        })
        .expect("failed to spawn persistence runtime thread");

    // Brief pause to let persistence pool initialize before workers start.
    // The persist sender must be set before any shard calls persist_async!.
    while !roc_glue::persist_sender_ready() {
        std::thread::yield_now();
    }

    // Spawn one worker thread per shard
    let mut handles = Vec::new();
    for (shard_id, rx) in receivers.into_iter().enumerate() {
        let handle = std::thread::Builder::new()
            .name(format!("shard-{}", shard_id))
            .spawn(move || {
                shard_worker::run_shard_worker(shard_id as u32, rx);
            })
            .expect("failed to spawn shard worker thread");
        handles.push(handle);
    }

    // Collect senders for timer tasks
    let timer_senders: Vec<_> = {
        let reg = roc_glue::channel_registry();
        (0..config.shard_count)
            .map(|i| reg.sender(i).clone())
            .collect()
    };

    // Start LRU check timers on a dedicated tokio runtime.
    // The runtime is single-threaded (current_thread) since timer tasks
    // are lightweight. Must keep _timer_rt alive — dropping it stops timers.
    let _timer_rt = std::thread::Builder::new()
        .name("timer-runtime".into())
        .spawn(move || {
            let rt = timer::start_lru_timers(timer_senders, config.lru_check_interval_ms);
            // block_on keeps the tokio runtime running
            rt.block_on(std::future::pending::<()>());
        })
        .expect("failed to spawn timer runtime thread");

    eprintln!(
        "quine-graph platform running: {} shard workers, timers every {}ms",
        config.shard_count, config.lru_check_interval_ms
    );

    // Keep main thread alive until all workers finish.
    // Workers block forever on recv until channels are closed.
    for handle in handles {
        handle.join().expect("shard worker panicked");
    }
}

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
            "--timer-interval" => {
                i += 1;
                if let Some(n) = args.get(i) {
                    config.lru_check_interval_ms = n.parse().expect("--timer-interval must be a number");
                }
            }
            _ => {}
        }
        i += 1;
    }
    config
}
