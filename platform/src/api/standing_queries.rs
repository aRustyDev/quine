// platform/src/api/standing_queries.rs

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{delete, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use super::{AppState, SqEntry};
use crate::channels::TAG_SHARD_CMD;

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
    #[serde(skip_serializing_if = "Option::is_none")]
    shards_reached: Option<u32>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    results: Vec<SqResultEntry>,
}

#[derive(Serialize)]
pub(crate) struct SqResultEntry {
    pub(crate) is_positive_match: bool,
    pub(crate) data: serde_json::Value,
}

// ---- Shard Command Wire Format ----
//
// Standing query commands are shard-level (not node-targeted), so they use
// TAG_SHARD_CMD (0x02) instead of TAG_SHARD_MSG (0x01).
//
// Shard command sub-tags (decoded by Codec.decode_shard_cmd in Roc):
//   0x01 = RegisterSq:  [global_id:U128LE][include_cancel:U8][mvsq_bytes...]
//   0x02 = UpdateSqs:   (no data)
//   0x03 = CancelSq:    [global_id:U128LE]

const CMD_REGISTER_SQ: u8 = 0x01;
const CMD_UPDATE_SQS: u8 = 0x02;
const CMD_CANCEL_SQ: u8 = 0x03;

/// Encode an MVSQ AST JSON value to binary wire format matching the Roc decoder.
///
/// Supported query types (matching Codec.decode_mvsq tags):
///   0x00 = UnitSq
///   0x02 = LocalProperty
///   0x03 = LocalId
///   0x04 = AllProperties
fn encode_mvsq_binary(query: &serde_json::Value) -> Vec<u8> {
    match query.get("type").and_then(|v| v.as_str()) {
        Some("UnitSq") => vec![0x00],
        Some("LocalProperty") => {
            let mut buf = vec![0x02];
            let key = query.get("prop_key").and_then(|v| v.as_str()).unwrap_or("");
            buf.extend_from_slice(&(key.len() as u16).to_le_bytes());
            buf.extend_from_slice(key.as_bytes());
            // ValueConstraint
            buf.extend_from_slice(&encode_value_constraint(
                query.get("constraint").unwrap_or(&serde_json::Value::Null),
            ));
            // Alias
            match query.get("aliased_as").and_then(|v| v.as_str()) {
                Some(alias) => {
                    buf.push(0x01);
                    buf.extend_from_slice(&(alias.len() as u16).to_le_bytes());
                    buf.extend_from_slice(alias.as_bytes());
                }
                None => buf.push(0x00),
            }
            buf
        }
        Some("LocalId") => {
            let mut buf = vec![0x03];
            let alias = query.get("aliased_as").and_then(|v| v.as_str()).unwrap_or("id");
            buf.extend_from_slice(&(alias.len() as u16).to_le_bytes());
            buf.extend_from_slice(alias.as_bytes());
            let format_str = query.get("format_as_string").and_then(|v| v.as_bool()).unwrap_or(false);
            buf.push(if format_str { 1 } else { 0 });
            buf
        }
        Some("AllProperties") => {
            let mut buf = vec![0x04];
            let alias = query.get("aliased_as").and_then(|v| v.as_str()).unwrap_or("props");
            buf.extend_from_slice(&(alias.len() as u16).to_le_bytes());
            buf.extend_from_slice(alias.as_bytes());
            buf
        }
        _ => vec![0x00], // Fallback to UnitSq
    }
}

fn encode_value_constraint(constraint: &serde_json::Value) -> Vec<u8> {
    match constraint.get("type").and_then(|v| v.as_str()) {
        Some("Any") => vec![0x00],
        Some("None") => vec![0x01],
        Some("Unconditional") => vec![0x02],
        Some("Regex") => {
            let pattern = constraint.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
            let mut buf = vec![0x05];
            buf.extend_from_slice(&(pattern.len() as u16).to_le_bytes());
            buf.extend_from_slice(pattern.as_bytes());
            buf
        }
        _ => vec![0x00], // Default to Any
    }
}

fn encode_register_sq_command(query_id: u128, include_cancel: bool, query: &serde_json::Value) -> Vec<u8> {
    let mvsq = encode_mvsq_binary(query);
    let mut buf = Vec::with_capacity(1 + 16 + 1 + mvsq.len());
    buf.push(CMD_REGISTER_SQ);
    buf.extend_from_slice(&query_id.to_le_bytes());
    buf.push(if include_cancel { 1 } else { 0 });
    buf.extend_from_slice(&mvsq);
    buf
}

fn encode_update_sqs_command() -> Vec<u8> {
    vec![CMD_UPDATE_SQS]
}

fn encode_cancel_sq_command(query_id: u128) -> Vec<u8> {
    let mut buf = Vec::with_capacity(1 + 16);
    buf.push(CMD_CANCEL_SQ);
    buf.extend_from_slice(&query_id.to_le_bytes());
    buf
}

/// Send a shard-level command to all shards, prepending TAG_SHARD_CMD.
/// Returns the number of shards that successfully received the command.
fn broadcast_to_shards(state: &AppState, payload: &[u8]) -> u32 {
    let mut success_count = 0u32;
    for shard_id in 0..state.shard_count {
        let mut msg = Vec::with_capacity(1 + payload.len());
        msg.push(TAG_SHARD_CMD);
        msg.extend_from_slice(payload);
        if state.channel_registry.try_send(shard_id, msg) {
            success_count += 1;
        } else {
            eprintln!(
                "standing_queries: channel full for shard {} during broadcast",
                shard_id
            );
        }
    }
    success_count
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

    // Send RegisterSq to all shards
    let create_cmd = encode_register_sq_command(query_id, req.include_cancellations, &req.query);
    let shards_reached = broadcast_to_shards(&state, &create_cmd);

    // Send UpdateSqs to all shards (broadcasts to awake nodes)
    let update_cmd = encode_update_sqs_command();
    broadcast_to_shards(&state, &update_cmd);

    if shards_reached == 0 {
        // No shards received the command — remove from registry and return 503
        let mut sqs = state.sq_registry.lock().unwrap();
        sqs.remove(&query_id);
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(SqResponse {
                id: format!("{:032x}", query_id),
                query: req.query,
                status: "failed",
                results_emitted: 0,
                shards_reached: Some(0),
                results: Vec::new(),
            }),
        );
    }

    let id_str = format!("{:032x}", query_id);
    (
        StatusCode::CREATED,
        Json(SqResponse {
            id: id_str,
            query: req.query,
            status: "running",
            results_emitted: 0,
            shards_reached: Some(shards_reached),
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
                shards_reached: None,
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
