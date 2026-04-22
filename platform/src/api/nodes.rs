// platform/src/api/nodes.rs
//
// GET /api/v1/nodes/:id — request-response node query through the shard.
//
// Mechanism:
//   1. Compute QuineId from :id string (FNV-1a hash)
//   2. Determine target shard
//   3. Create a tokio oneshot channel for the reply
//   4. Store the oneshot sender in PendingRequests keyed by request_id
//   5. Encode and send GetProps { reply_to: request_id } to the shard
//   6. Await the oneshot receiver with 5s timeout
//   7. roc_fx_reply (called from shard worker) completes the oneshot
//   8. Decode reply payload and return as JSON

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::get;
use axum::{Json, Router};

use super::AppState;
use crate::channels::TAG_SHARD_MSG;
use crate::quine_id;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new().route("/nodes/{id}", get(get_node))
}

/// Monotonic request ID counter for node queries.
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

fn next_request_id() -> u64 {
    NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
}

// GetProps / GetNodeState command tag (must match Roc Codec: GetProps = 0x01, GetEdges = 0x06)
const TAG_GET_NODE_STATE: u8 = 0x01;

/// Encode a GetNodeState shard message:
///   [TAG_SHARD_MSG][qid_len:U16LE][qid_bytes...][TAG_GET_NODE_STATE][reply_to:U64LE]
fn encode_get_node_state(qid: &[u8; 16], request_id: u64) -> Vec<u8> {
    // TAG_SHARD_MSG(1) + qid_len(2) + qid(16) + TAG_GET_NODE_STATE(1) + reply_to(8) = 28
    let mut buf = Vec::with_capacity(28);
    buf.push(TAG_SHARD_MSG);
    buf.extend_from_slice(&(qid.len() as u16).to_le_bytes());
    buf.extend_from_slice(qid);
    buf.push(TAG_GET_NODE_STATE);
    buf.extend_from_slice(&request_id.to_le_bytes());
    buf
}

async fn get_node(
    State(state): State<Arc<AppState>>,
    Path(id_str): Path<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let qid = quine_id::quine_id_from_str(&id_str);
    let target_shard = quine_id::shard_for_node(&qid, state.shard_count);

    let request_id = next_request_id();
    let (tx, rx) = tokio::sync::oneshot::channel::<Vec<u8>>();

    // Register pending request
    {
        let mut pending = state.pending_requests.lock().unwrap();
        pending.insert(request_id, tx);
    }

    // Send GetNodeState to shard
    let msg = encode_get_node_state(&qid, request_id);
    if !state.channel_registry.try_send(target_shard, msg) {
        // Clean up pending request on failure
        let mut pending = state.pending_requests.lock().unwrap();
        pending.remove(&request_id);
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }

    // Await reply with timeout
    match tokio::time::timeout(std::time::Duration::from_secs(5), rx).await {
        Ok(Ok(payload)) => {
            let response = decode_node_reply(&id_str, &payload);
            Ok(Json(response))
        }
        Ok(Err(_)) => {
            // Sender was dropped — shard didn't reply
            Err(StatusCode::NOT_FOUND)
        }
        Err(_) => {
            // Timeout — clean up pending request
            let mut pending = state.pending_requests.lock().unwrap();
            pending.remove(&request_id);
            Err(StatusCode::GATEWAY_TIMEOUT)
        }
    }
}

/// Decode the reply payload into a JSON response.
///
/// Reply format (from Roc Reply effect):
///   [prop_count:U32LE]
///     repeated: [key_len:U16LE][key_bytes...][value_tag:U8][value_data...]
///   [edge_count:U32LE]
///     repeated: [edge_type_len:U16LE][edge_type...][direction:U8][other_qid_len:U16LE][other_qid...]
///
/// For now, return the raw byte count as a diagnostic — full decoding
/// will be wired when the Roc-side Reply encoder is implemented.
pub(crate) fn decode_node_reply(id_str: &str, payload: &[u8]) -> serde_json::Value {
    // Attempt to decode properties and edges from the reply payload
    let mut offset = 0;
    let mut properties = serde_json::Map::new();
    let mut edges = Vec::new();

    // Try to decode properties
    if let Some(prop_count) = read_u32_le(payload, offset) {
        offset += 4;
        for _ in 0..prop_count {
            if let Some((key, new_offset)) = read_string(payload, offset) {
                offset = new_offset;
                if let Some((value, new_offset)) = decode_quine_value(payload, offset) {
                    offset = new_offset;
                    properties.insert(key, value);
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    // Try to decode edges
    if let Some(edge_count) = read_u32_le(payload, offset) {
        offset += 4;
        for _ in 0..edge_count {
            if let Some((edge, new_offset)) = decode_half_edge(payload, offset) {
                offset = new_offset;
                edges.push(edge);
            } else {
                break;
            }
        }
    }

    let _ = offset; // silence unused warning

    serde_json::json!({
        "id": id_str,
        "properties": properties,
        "edges": edges,
    })
}

// ---- Wire format decoders ----

fn read_u16_le(buf: &[u8], offset: usize) -> Option<u16> {
    if offset + 2 > buf.len() {
        return None;
    }
    Some(u16::from_le_bytes([buf[offset], buf[offset + 1]]))
}

fn read_u32_le(buf: &[u8], offset: usize) -> Option<u32> {
    if offset + 4 > buf.len() {
        return None;
    }
    Some(u32::from_le_bytes(
        buf[offset..offset + 4].try_into().ok()?,
    ))
}

fn read_u64_le(buf: &[u8], offset: usize) -> Option<u64> {
    if offset + 8 > buf.len() {
        return None;
    }
    Some(u64::from_le_bytes(
        buf[offset..offset + 8].try_into().ok()?,
    ))
}

fn read_string(buf: &[u8], offset: usize) -> Option<(String, usize)> {
    let len = read_u16_le(buf, offset)? as usize;
    let start = offset + 2;
    if start + len > buf.len() {
        return None;
    }
    let s = String::from_utf8(buf[start..start + len].to_vec()).ok()?;
    Some((s, start + len))
}

fn decode_quine_value(buf: &[u8], offset: usize) -> Option<(serde_json::Value, usize)> {
    if offset >= buf.len() {
        return None;
    }
    let tag = buf[offset];
    match tag {
        0x01 => {
            // Str
            let (s, next) = read_string(buf, offset + 1)?;
            Some((serde_json::Value::String(s), next))
        }
        0x02 => {
            // Integer (stored as U64)
            let n = read_u64_le(buf, offset + 1)?;
            Some((serde_json::json!(n), offset + 9))
        }
        0x03 => {
            // Floating
            let bits = read_u64_le(buf, offset + 1)?;
            let f = f64::from_bits(bits);
            Some((serde_json::json!(f), offset + 9))
        }
        0x04 => Some((serde_json::Value::Bool(true), offset + 1)),
        0x05 => Some((serde_json::Value::Bool(false), offset + 1)),
        0x06 => Some((serde_json::Value::Null, offset + 1)),
        0x07 => {
            // Serialized / Bytes — length-prefixed byte blob, render as hex
            let len = read_u16_le(buf, offset + 1)? as usize;
            let start = offset + 3;
            if start + len > buf.len() {
                return None;
            }
            let hex: String = buf[start..start + len].iter().map(|b| format!("{:02x}", b)).collect();
            Some((serde_json::json!(hex), start + len))
        }
        0x08 => {
            // Id(QuineId) — length-prefixed QID bytes, render as hex
            let len = read_u16_le(buf, offset + 1)? as usize;
            let start = offset + 3;
            if start + len > buf.len() {
                return None;
            }
            let hex: String = buf[start..start + len].iter().map(|b| format!("{:02x}", b)).collect();
            Some((serde_json::json!(hex), start + len))
        }
        _ => None,
    }
}

fn decode_half_edge(buf: &[u8], offset: usize) -> Option<(serde_json::Value, usize)> {
    let (edge_type, offset) = read_string(buf, offset)?;
    if offset >= buf.len() {
        return None;
    }
    let direction = match buf[offset] {
        0x01 => "outgoing",
        0x02 => "incoming",
        _ => return None,
    };
    let offset = offset + 1;
    let other_len = read_u16_le(buf, offset)? as usize;
    let offset = offset + 2;
    if offset + other_len > buf.len() {
        return None;
    }
    let other_hex: String = buf[offset..offset + other_len]
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect();
    let offset = offset + other_len;

    Some((
        serde_json::json!({
            "type": edge_type,
            "direction": direction,
            "other": other_hex,
        }),
        offset,
    ))
}
