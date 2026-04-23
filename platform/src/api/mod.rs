// platform/src/api/mod.rs
//
// axum REST API: router, shared state, and endpoint modules.

pub mod health;
pub mod ingest;
pub mod nodes;
pub mod query;
pub mod standing_queries;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use axum::Router;

use crate::channels::ChannelRegistry;
use crate::ingest::IngestJobRegistry;

// ============================================================
// Standing Query Registry (Rust-side metadata for GET/DELETE)
// ============================================================

/// Metadata about a registered standing query, stored on the Rust side
/// so the REST API can answer GET /standing-queries without querying shards.
pub struct SqEntry {
    pub id: u128,
    pub query_json: serde_json::Value,
    pub include_cancellations: bool,
    pub results_emitted: AtomicU64,
}

pub type SqRegistry = Arc<Mutex<HashMap<u128, Arc<SqEntry>>>>;

pub fn new_sq_registry() -> SqRegistry {
    Arc::new(Mutex::new(HashMap::new()))
}

// ============================================================
// Pending Requests (for node query request-response)
// ============================================================

/// Map of in-flight request_id → oneshot sender for reply routing.
/// The roc_fx_reply host function looks up the sender here and completes it.
pub type PendingRequests = Arc<Mutex<HashMap<u64, tokio::sync::oneshot::Sender<Vec<u8>>>>>;

pub fn new_pending_requests() -> PendingRequests {
    Arc::new(Mutex::new(HashMap::new()))
}

// ============================================================
// Shared Application State
// ============================================================

/// State shared across all axum handlers via `State<Arc<AppState>>`.
pub struct AppState {
    pub channel_registry: &'static ChannelRegistry,
    pub ingest_jobs: IngestJobRegistry,
    pub sq_registry: SqRegistry,
    pub sq_result_rx: crossbeam_channel::Receiver<Vec<u8>>,
    pub pending_requests: PendingRequests,
    pub shard_count: u32,
    pub start_time: Instant,
}

// ============================================================
// Router
// ============================================================

pub fn api_routes(state: Arc<AppState>) -> Router {
    Router::new()
        .nest("/api/v1", v1_routes())
        .with_state(state)
}

fn v1_routes() -> Router<Arc<AppState>> {
    Router::new()
        .merge(ingest::routes())
        .merge(standing_queries::routes())
        .merge(nodes::routes())
        .merge(query::routes())
        .merge(health::routes())
}
