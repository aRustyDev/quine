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
mod watch_dir;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use channels::ChannelRegistry;
use config::PlatformConfig;

/// Global shutdown flag, set by the signal handler.
static SHUTDOWN: AtomicBool = AtomicBool::new(false);

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
    let api_state = app_state.clone();
    let api_state_for_thread = app_state;
    let _api_thread = std::thread::Builder::new()
        .name("api-server".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("Failed to create tokio runtime for API server");
            rt.block_on(async {
                let app = api::api_routes(api_state_for_thread);
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

    // If --ingest stdin was passed, auto-start a stdin ingest job.
    if has_stdin_ingest_flag() {
        let job = Arc::new(ingest::IngestJob {
            name: "stdin".into(),
            source: ingest::IngestSource::Stdin,
            status: std::sync::Mutex::new(ingest::IngestStatus::Running),
            records_processed: std::sync::atomic::AtomicU64::new(0),
            records_failed: std::sync::atomic::AtomicU64::new(0),
            cancel: Arc::new(AtomicBool::new(false)),
            started_at: std::time::Instant::now(),
            completed_at: std::sync::Mutex::new(None),
        });
        api_state
            .ingest_jobs
            .lock()
            .unwrap()
            .insert("stdin".into(), job.clone());
        ingest::start_file_ingest(job, api_state.channel_registry, api_state.shard_count);
        eprintln!("stdin ingest: reading JSONL from stdin");
    }

    // If --ingest watch-dir <path> was passed, auto-start a watch-dir ingest job.
    if let Some(watch_path) = watch_dir_ingest_path() {
        let path = std::path::PathBuf::from(&watch_path);
        if !path.is_dir() {
            eprintln!("watch-dir ingest: '{}' is not a directory", watch_path);
            std::process::exit(1);
        }
        let job = Arc::new(ingest::IngestJob {
            name: "watch-dir".into(),
            source: ingest::IngestSource::WatchDir { path },
            status: std::sync::Mutex::new(ingest::IngestStatus::Running),
            records_processed: std::sync::atomic::AtomicU64::new(0),
            records_failed: std::sync::atomic::AtomicU64::new(0),
            cancel: Arc::new(AtomicBool::new(false)),
            started_at: std::time::Instant::now(),
            completed_at: std::sync::Mutex::new(None),
        });
        api_state
            .ingest_jobs
            .lock()
            .unwrap()
            .insert("watch-dir".into(), job.clone());
        watch_dir::start_watch_dir_ingest(job, api_state.channel_registry, api_state.shard_count);
        eprintln!("watch-dir ingest: watching {}", watch_path);
    }

    // Spawn a dedicated thread to catch SIGINT/SIGTERM and initiate shutdown.
    let shutdown_registry = roc_glue::channel_registry();
    let shutdown_shard_count = config.shard_count;
    let shutdown_ingest_jobs = api_state.ingest_jobs.clone();
    std::thread::Builder::new()
        .name("signal-handler".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("Failed to create tokio runtime for signal handler");
            rt.block_on(async {
                wait_for_shutdown_signal().await;
            });

            if SHUTDOWN.swap(true, Ordering::SeqCst) {
                // Already shutting down (double signal) — force exit
                eprintln!("shutdown: forced exit (double signal)");
                std::process::exit(1);
            }

            eprintln!("shutdown: signal received, initiating graceful shutdown");

            // 1. Cancel all ingest jobs
            if let Ok(jobs) = shutdown_ingest_jobs.lock() {
                for (name, job) in jobs.iter() {
                    eprintln!("shutdown: cancelling ingest job '{}'", name);
                    job.cancel.store(true, Ordering::Relaxed);
                }
            }

            // 2. Send TAG_SHUTDOWN to each shard channel
            for shard_id in 0..shutdown_shard_count {
                let msg = vec![channels::TAG_SHUTDOWN];
                if shutdown_registry.sender(shard_id).send(msg).is_err() {
                    eprintln!("shutdown: failed to send shutdown to shard {}", shard_id);
                }
            }
        })
        .expect("failed to spawn signal handler thread");

    // Keep main thread alive until all shard workers finish.
    // Workers exit after processing TAG_SHUTDOWN.
    for handle in handles {
        handle.join().expect("shard worker panicked");
    }

    // If shutdown was triggered, flush the persistence pool.
    if SHUTDOWN.load(Ordering::SeqCst) {
        eprintln!("shutdown: shard workers stopped, flushing persistence");
        flush_persistence_pool();
        eprintln!("shutdown: complete");
    }
}

/// Wait for SIGINT or SIGTERM.
async fn wait_for_shutdown_signal() {
    use tokio::signal;

    let ctrl_c = signal::ctrl_c();

    #[cfg(unix)]
    {
        let mut sigterm =
            signal::unix::signal(signal::unix::SignalKind::terminate())
                .expect("failed to install SIGTERM handler");
        tokio::select! {
            _ = ctrl_c => {},
            _ = sigterm.recv() => {},
        }
    }

    #[cfg(not(unix))]
    {
        ctrl_c.await.expect("failed to listen for Ctrl+C");
    }
}

/// Send a flush sentinel to the persistence pool and wait for it to drain.
fn flush_persistence_pool() {
    if let Some(tx) = roc_glue::persist_sender() {
        let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
        let flush = persistence_io::PersistCommand::Flush { done: done_tx };
        if tx.send(flush).is_err() {
            eprintln!("shutdown: persistence pool already closed");
            return;
        }
        match done_rx.recv_timeout(std::time::Duration::from_secs(30)) {
            Ok(()) => eprintln!("shutdown: persistence flush complete"),
            Err(_) => eprintln!("shutdown: persistence flush timed out after 30s"),
        }
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

/// Check if `--ingest stdin` was passed on the command line.
fn has_stdin_ingest_flag() -> bool {
    let args: Vec<String> = std::env::args().collect();
    args.windows(2)
        .any(|w| w[0] == "--ingest" && w[1] == "stdin")
}

/// Return the path argument from `--ingest watch-dir <path>`, if present.
fn watch_dir_ingest_path() -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.windows(3)
        .find(|w| w[0] == "--ingest" && w[1] == "watch-dir")
        .map(|w| w[2].clone())
}
