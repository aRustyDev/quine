// platform/src/main.rs

mod api;
mod channels;
mod codec;
mod config;
mod cypher;
mod effects;
pub mod ingest;
mod persistence_io;
pub mod quine_id;
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

    // Store shard count globally for roc_fx_shard_count (before workers start)
    roc_glue::set_shard_count(config.shard_count);

    // Clone receivers before moving registry into the global OnceLock.
    // crossbeam Receiver is Clone (it's an Arc internally), so this is cheap.
    let receivers: Vec<_> = (0..config.shard_count)
        .map(|i| registry.receiver(i).clone())
        .collect();

    // Store registry globally for roc_fx_send_to_shard
    roc_glue::set_channel_registry(registry);

    // Open redb database for persistent storage.
    let data_dir = std::path::Path::new(&config.data_dir);
    std::fs::create_dir_all(data_dir).expect("Failed to create data directory");
    let db_path = data_dir.join("quine.redb");
    let db = persistence_io::open_database(&db_path);
    eprintln!("persistence: opened {}", db_path.display());

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
            let _cmd_tx = persistence_io::start_persistence_pool(persist_senders, &rt, db);
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

    // Start SQ result channel for standing query output.
    // Bounded channel with capacity matching the default SQ config buffer size.
    // The receiver is passed to the REST API for draining results.
    let (sq_result_tx, sq_result_rx) = crossbeam_channel::bounded::<Vec<u8>>(1024);
    roc_glue::set_sq_result_sender(sq_result_tx);

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

    // Build shared application state for the REST API.
    let app_state = std::sync::Arc::new(api::AppState {
        channel_registry: roc_glue::channel_registry(),
        ingest_jobs: ingest::new_registry(),
        sq_registry: api::new_sq_registry(),
        sq_result_rx,
        pending_requests: api::new_pending_requests(),
        shard_count: config.shard_count,
        start_time: std::time::Instant::now(),
    });

    // Store pending_requests globally for roc_fx_reply
    roc_glue::set_pending_requests(app_state.pending_requests.clone());

    // Start axum REST API server
    let api_port = config.api_port;
    let api_state = app_state;
    let _api_thread = std::thread::Builder::new()
        .name("api-server".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("Failed to create tokio runtime for API server");
            rt.block_on(async {
                let app = api::api_routes(api_state);
                let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", api_port))
                    .await
                    .expect("Failed to bind API server");
                eprintln!("REST API listening on 0.0.0.0:{}", api_port);
                axum::serve(listener, app).await.expect("API server error");
            });
        })
        .expect("failed to spawn API server thread");

    eprintln!(
        "quine-graph platform running: {} shard workers, timers every {}ms, API on port {}",
        config.shard_count, config.lru_check_interval_ms, api_port
    );

    // Keep main thread alive until all workers finish.
    // Workers block forever on recv until channels are closed.
    for handle in handles {
        handle.join().expect("shard worker panicked");
    }
}

fn parse_config() -> PlatformConfig {
    use figment::providers::{Env, Format, Serialized, Toml, Yaml};
    use figment::Figment;

    // Build config with priority: CLI args > env > config file > defaults
    let mut figment = Figment::from(Serialized::defaults(PlatformConfig::default()))
        .merge(Toml::file("quine.toml"))
        .merge(Yaml::file("quine.yaml"))
        .merge(Yaml::file("quine.yml"))
        .merge(Env::prefixed("QUINE_"));

    // Parse CLI args as overrides (highest priority)
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--shards" => {
                i += 1;
                if let Some(n) = args.get(i) {
                    let val: u32 = n.parse().expect("--shards must be a number");
                    figment = figment.merge(Serialized::default("shard_count", val));
                }
            }
            "--channel-capacity" => {
                i += 1;
                if let Some(n) = args.get(i) {
                    let val: usize = n.parse().expect("--channel-capacity must be a number");
                    figment = figment.merge(Serialized::default("channel_capacity", val));
                }
            }
            "--timer-interval" => {
                i += 1;
                if let Some(n) = args.get(i) {
                    let val: u64 = n.parse().expect("--timer-interval must be a number");
                    figment = figment.merge(Serialized::default("lru_check_interval_ms", val));
                }
            }
            "--port" => {
                i += 1;
                if let Some(n) = args.get(i) {
                    let val: u16 = n.parse().expect("--port must be a number");
                    figment = figment.merge(Serialized::default("api_port", val));
                }
            }
            _ => {}
        }
        i += 1;
    }

    figment
        .extract()
        .expect("Failed to load configuration")
}
