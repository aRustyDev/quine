// platform/src/api/health.rs

use std::sync::atomic::Ordering;
use std::sync::Arc;

use axum::extract::State;
use axum::routing::get;
use axum::{Json, Router};

use super::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new().route("/health", get(health))
}

#[derive(serde::Serialize)]
struct HealthResponse {
    status: &'static str,
    shards: u32,
    uptime_seconds: u64,
    ingest_jobs: IngestStats,
    standing_queries: SqStats,
}

#[derive(serde::Serialize)]
struct IngestStats {
    running: usize,
    complete: usize,
}

#[derive(serde::Serialize)]
struct SqStats {
    running: usize,
    results_emitted: u64,
}

async fn health(State(state): State<Arc<AppState>>) -> Json<HealthResponse> {
    let uptime = state.start_time.elapsed().as_secs();

    let (running, complete) = {
        let jobs = state.ingest_jobs.lock().unwrap();
        let mut r = 0;
        let mut c = 0;
        for job in jobs.values() {
            match *job.status.lock().unwrap() {
                crate::ingest::IngestStatus::Running => r += 1,
                crate::ingest::IngestStatus::Complete => c += 1,
                _ => {}
            }
        }
        (r, c)
    };

    let (sq_running, sq_results) = {
        let sqs = state.sq_registry.lock().unwrap();
        let count = sqs.len();
        let results: u64 = sqs
            .values()
            .map(|e| e.results_emitted.load(Ordering::Relaxed))
            .sum();
        (count, results)
    };

    Json(HealthResponse {
        status: "ok",
        shards: state.shard_count,
        uptime_seconds: uptime,
        ingest_jobs: IngestStats {
            running,
            complete,
        },
        standing_queries: SqStats {
            running: sq_running,
            results_emitted: sq_results,
        },
    })
}
