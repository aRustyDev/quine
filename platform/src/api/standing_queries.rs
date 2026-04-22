// platform/src/api/standing_queries.rs

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{delete, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use super::{AppState, SqEntry};
use crate::channels::TAG_SHARD_MSG;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/standing-queries",
            post(create_sq).get(list_sqs),
        )
        .route("/standing-queries/{id}", delete(cancel_sq))
}

// ---- Request / Response types ----

#[derive(Deserialize)]
struct CreateSqRequest {
    query: serde_json::Value,
    #[serde(default)]
    include_cancellations: bool,
}

#[derive(Serialize)]
struct SqResponse {
    id: String,
    query: serde_json::Value,
    status: &'static str,
    results_emitted: u64,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    results: Vec<SqResultEntry>,
}

#[derive(Serialize)]
pub(crate) struct SqResultEntry {
    pub(crate) is_positive_match: bool,
    pub(crate) data: serde_json::Value,
}

// ---- SQ Command Wire Format ----
//
// Standing query commands are sent to shards as shard messages with
// special command tags. These mirror the Roc-side SqCommand encoding.
//
// CreateSqSubscription: TAG_SQ_CREATE (0x10)
//   [0x10][query_id:U128LE][include_cancel:U8][mvsq_bytes...]
//
// UpdateStandingQueries: TAG_SQ_UPDATE (0x11)
//   [0x11]
//
// CancelSqSubscription: TAG_SQ_CANCEL (0x12)
//   [0x12][query_id:U128LE]

const TAG_SQ_CREATE: u8 = 0x10;
const TAG_SQ_UPDATE: u8 = 0x11;
const TAG_SQ_CANCEL: u8 = 0x12;

/// Encode the MVSQ AST JSON into wire format bytes.
/// For now this is a passthrough: store the JSON bytes as the "query" field.
/// A proper AST→wire encoder will be added when we have real SQ evaluation.
fn encode_mvsq_json(query: &serde_json::Value) -> Vec<u8> {
    serde_json::to_vec(query).unwrap_or_default()
}

fn encode_create_sq_command(query_id: u128, include_cancel: bool, query: &serde_json::Value) -> Vec<u8> {
    let mvsq = encode_mvsq_json(query);
    let mut buf = Vec::with_capacity(1 + 16 + 1 + mvsq.len());
    buf.push(TAG_SQ_CREATE);
    buf.extend_from_slice(&query_id.to_le_bytes());
    buf.push(if include_cancel { 1 } else { 0 });
    buf.extend_from_slice(&mvsq);
    buf
}

fn encode_update_sq_command() -> Vec<u8> {
    vec![TAG_SQ_UPDATE]
}

fn encode_cancel_sq_command(query_id: u128) -> Vec<u8> {
    let mut buf = Vec::with_capacity(1 + 16);
    buf.push(TAG_SQ_CANCEL);
    buf.extend_from_slice(&query_id.to_le_bytes());
    buf
}

/// Send a command to all shards, prepending TAG_SHARD_MSG for channel routing.
fn broadcast_to_shards(state: &AppState, payload: &[u8]) {
    for shard_id in 0..state.shard_count {
        let mut msg = Vec::with_capacity(1 + payload.len());
        msg.push(TAG_SHARD_MSG);
        msg.extend_from_slice(payload);
        // Best-effort: if a shard channel is full, log and skip
        if !state.channel_registry.try_send(shard_id, msg) {
            eprintln!(
                "standing_queries: channel full for shard {} during broadcast",
                shard_id
            );
        }
    }
}

// ---- Handlers ----

async fn create_sq(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateSqRequest>,
) -> (StatusCode, Json<SqResponse>) {
    let query_id = uuid::Uuid::new_v4().as_u128();

    // Register in SqRegistry
    let entry = Arc::new(SqEntry {
        id: query_id,
        query_json: req.query.clone(),
        include_cancellations: req.include_cancellations,
        results_emitted: AtomicU64::new(0),
    });
    {
        let mut sqs = state.sq_registry.lock().unwrap();
        sqs.insert(query_id, entry);
    }

    // Send CreateSqSubscription to all shards
    let create_cmd = encode_create_sq_command(query_id, req.include_cancellations, &req.query);
    broadcast_to_shards(&state, &create_cmd);

    // Send UpdateStandingQueries to all shards
    let update_cmd = encode_update_sq_command();
    broadcast_to_shards(&state, &update_cmd);

    let id_str = format!("{:032x}", query_id);
    (
        StatusCode::CREATED,
        Json(SqResponse {
            id: id_str,
            query: req.query,
            status: "running",
            results_emitted: 0,
            results: Vec::new(),
        }),
    )
}

async fn list_sqs(State(state): State<Arc<AppState>>) -> Json<Vec<SqResponse>> {
    // Drain any pending results from the SQ result channel
    let mut raw_results: Vec<Vec<u8>> = Vec::new();
    while let Ok(bytes) = state.sq_result_rx.try_recv() {
        raw_results.push(bytes);
    }

    // Decode results and group by query_id
    let mut results_by_query: std::collections::HashMap<u128, Vec<SqResultEntry>> =
        std::collections::HashMap::new();
    for bytes in &raw_results {
        if let Some((query_id, entry)) = decode_sq_result(bytes) {
            // Increment counter on the SqEntry
            let sqs = state.sq_registry.lock().unwrap();
            if let Some(sq) = sqs.get(&query_id) {
                sq.results_emitted.fetch_add(1, Ordering::Relaxed);
            }
            results_by_query
                .entry(query_id)
                .or_default()
                .push(entry);
        }
    }

    let sqs = state.sq_registry.lock().unwrap();
    let list: Vec<SqResponse> = sqs
        .values()
        .map(|entry| {
            let id_str = format!("{:032x}", entry.id);
            let results = results_by_query.remove(&entry.id).unwrap_or_default();
            SqResponse {
                id: id_str,
                query: entry.query_json.clone(),
                status: "running",
                results_emitted: entry.results_emitted.load(Ordering::Relaxed),
                results,
            }
        })
        .collect();
    Json(list)
}

async fn cancel_sq(
    State(state): State<Arc<AppState>>,
    Path(id_str): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let query_id = u128::from_str_radix(&id_str, 16).map_err(|_| StatusCode::BAD_REQUEST)?;

    let removed = {
        let mut sqs = state.sq_registry.lock().unwrap();
        sqs.remove(&query_id)
    };

    match removed {
        None => Err(StatusCode::NOT_FOUND),
        Some(_entry) => {
            // Send CancelSqSubscription to all shards
            let cancel_cmd = encode_cancel_sq_command(query_id);
            broadcast_to_shards(&state, &cancel_cmd);

            Ok(Json(serde_json::json!({
                "id": id_str,
                "status": "cancelled"
            })))
        }
    }
}

// ---- SQ Result Decoding ----
//
// Format (from graph-app.roc encode_sq_result_payload):
//   [query_id_lo:U64LE][query_id_hi:U64LE][is_positive:U8][pair_count:U32LE]
//
// Full data pairs deferred to Phase 5; for now we return the match flag only.

pub(crate) fn decode_sq_result(bytes: &[u8]) -> Option<(u128, SqResultEntry)> {
    if bytes.len() < 17 {
        return None;
    }
    let lo = u64::from_le_bytes(bytes[0..8].try_into().ok()?);
    let hi = u64::from_le_bytes(bytes[8..16].try_into().ok()?);
    let query_id = (hi as u128) << 64 | (lo as u128);
    let is_positive = bytes[16] != 0;

    Some((
        query_id,
        SqResultEntry {
            is_positive_match: is_positive,
            data: serde_json::json!({}), // Data decoding deferred to Phase 5
        },
    ))
}
