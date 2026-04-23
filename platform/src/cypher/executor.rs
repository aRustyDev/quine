// platform/src/cypher/executor.rs
//
// Cypher query executor — orchestrates plan steps against the graph.
// Walks a decoded QueryPlan, issues parallel GetNodeState requests to shards,
// filters and projects results.

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use super::eval::{self, HalfEdge, NodeData, Row};
use super::expr::{self, QuineValue};
use super::plan::{Direction, PlanStep, ProjectItem, QueryPlan};
use crate::api::PendingRequests;
use crate::channels::{ChannelRegistry, TAG_SHARD_CMD, TAG_SHARD_MSG};
use crate::quine_id;

// ===== Error Type =====

#[derive(Debug)]
pub enum ExecuteError {
    PlanDecode(String),
    ShardTimeout,
    ShardUnavailable,
    EvalError(String),
    PlanError(String),
}

impl fmt::Display for ExecuteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ExecuteError::PlanDecode(msg) => write!(f, "plan decode error: {}", msg),
            ExecuteError::ShardTimeout => write!(f, "shard request timed out"),
            ExecuteError::ShardUnavailable => write!(f, "shard channel unavailable"),
            ExecuteError::EvalError(msg) => write!(f, "eval error: {}", msg),
            ExecuteError::PlanError(msg) => write!(f, "plan error: {}", msg),
        }
    }
}

// ===== Request ID =====

/// Separate counter from nodes.rs — executor request IDs start at 1_000_000.
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1_000_000);

fn next_request_id() -> u64 {
    NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
}

// ===== GetNodeState Encoding =====

const TAG_GET_NODE_STATE: u8 = 0x01;

/// Encode a GetNodeState shard message.
///
/// Wire format: `[TAG_SHARD_MSG(0x01)][qid_len:U16LE=16][qid:16bytes][0x01][reply_to:U64LE]`
fn encode_get_node_state(qid: &[u8; 16], request_id: u64) -> Vec<u8> {
    let mut buf = Vec::with_capacity(28);
    buf.push(TAG_SHARD_MSG);
    buf.extend_from_slice(&(qid.len() as u16).to_le_bytes());
    buf.extend_from_slice(qid);
    buf.push(TAG_GET_NODE_STATE);
    buf.extend_from_slice(&request_id.to_le_bytes());
    buf
}

// ===== PlanQuery Encoding =====

/// Shard command sub-tag for PlanQuery (matches Codec.decode_shard_cmd tag 0x04).
const CMD_PLAN_QUERY: u8 = 0x04;

/// Encode a PlanQuery shard command.
///
/// Wire format:
///   [TAG_SHARD_CMD (0x02)]
///   [CMD_PLAN_QUERY (0x04)]
///   [reply_to: U64LE]
///   [query_len: U16LE]
///   [query_utf8...]
///   [hint_count: U16LE]
///   [hint_qid: 16 bytes] * hint_count
fn encode_plan_query(query: &str, hint_qids: &[[u8; 16]], request_id: u64) -> Vec<u8> {
    let query_bytes = query.as_bytes();
    let capacity = 1 + 1 + 8 + 2 + query_bytes.len() + 2 + hint_qids.len() * 16;
    let mut buf = Vec::with_capacity(capacity);
    buf.push(TAG_SHARD_CMD);
    buf.push(CMD_PLAN_QUERY);
    buf.extend_from_slice(&request_id.to_le_bytes());
    buf.extend_from_slice(&(query_bytes.len() as u16).to_le_bytes());
    buf.extend_from_slice(query_bytes);
    buf.extend_from_slice(&(hint_qids.len() as u16).to_le_bytes());
    for qid in hint_qids {
        buf.extend_from_slice(qid);
    }
    buf
}

/// Send a Cypher query to shard 0 for planning. Returns the decoded QueryPlan.
pub async fn plan_query(
    query: &str,
    hint_qids: &[[u8; 16]],
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
) -> Result<QueryPlan, ExecuteError> {
    let request_id = next_request_id();
    let (tx, rx) = tokio::sync::oneshot::channel::<Vec<u8>>();

    // Register pending request
    {
        let mut map = pending.lock().unwrap();
        map.insert(request_id, tx);
    }

    // Encode and send PlanQuery to shard 0
    let msg = encode_plan_query(query, hint_qids, request_id);
    if !registry.try_send(0, msg) {
        let mut map = pending.lock().unwrap();
        map.remove(&request_id);
        return Err(ExecuteError::ShardUnavailable);
    }

    // Await reply with 10s timeout (longer than node queries)
    let timeout_dur = Duration::from_secs(10);
    match tokio::time::timeout(timeout_dur, rx).await {
        Ok(Ok(payload)) => {
            // Check for error reply: first byte 0xFF
            if !payload.is_empty() && payload[0] == 0xFF {
                let len = if payload.len() >= 3 {
                    u16::from_le_bytes([payload[1], payload[2]]) as usize
                } else {
                    0
                };
                let error_msg = if len > 0 && 3 + len <= payload.len() {
                    String::from_utf8_lossy(&payload[3..3 + len]).into_owned()
                } else {
                    "unknown plan error".to_string()
                };
                Err(ExecuteError::PlanError(error_msg))
            } else {
                super::plan::decode_plan(&payload)
                    .map_err(|e| ExecuteError::PlanDecode(format!("{:?}", e)))
            }
        }
        Ok(Err(_)) => {
            // Sender dropped — shard didn't reply
            Err(ExecuteError::ShardTimeout)
        }
        Err(_) => {
            // Timeout — clean up pending
            let mut map = pending.lock().unwrap();
            map.remove(&request_id);
            Err(ExecuteError::ShardTimeout)
        }
    }
}

// ===== Wire Format Helpers =====

fn read_u16_le(buf: &[u8], offset: usize) -> Option<(u16, usize)> {
    if offset + 2 > buf.len() {
        return None;
    }
    let val = u16::from_le_bytes([buf[offset], buf[offset + 1]]);
    Some((val, offset + 2))
}

fn read_u32_le(buf: &[u8], offset: usize) -> Option<(u32, usize)> {
    if offset + 4 > buf.len() {
        return None;
    }
    let val = u32::from_le_bytes(buf[offset..offset + 4].try_into().ok()?);
    Some((val, offset + 4))
}

fn read_u64_le(buf: &[u8], offset: usize) -> Option<(u64, usize)> {
    if offset + 8 > buf.len() {
        return None;
    }
    let val = u64::from_le_bytes(buf[offset..offset + 8].try_into().ok()?);
    Some((val, offset + 8))
}

fn read_string(buf: &[u8], offset: usize) -> Option<(String, usize)> {
    let (len, data_start) = read_u16_le(buf, offset)?;
    let len = len as usize;
    if data_start + len > buf.len() {
        return None;
    }
    let s = String::from_utf8(buf[data_start..data_start + len].to_vec()).ok()?;
    Some((s, data_start + len))
}

fn decode_quine_value(buf: &[u8], offset: usize) -> Option<(QuineValue, usize)> {
    if offset >= buf.len() {
        return None;
    }
    let tag = buf[offset];
    match tag {
        0x01 => {
            // Str
            let (s, next) = read_string(buf, offset + 1)?;
            Some((QuineValue::Str(s), next))
        }
        0x02 => {
            // Integer (stored as i64 in U64LE)
            let (bits, next) = read_u64_le(buf, offset + 1)?;
            Some((QuineValue::Integer(bits as i64), next))
        }
        0x04 => Some((QuineValue::True, offset + 1)),
        0x05 => Some((QuineValue::False, offset + 1)),
        0x06 => Some((QuineValue::Null, offset + 1)),
        _ => None,
    }
}

fn qid_to_string(qid: &[u8; 16]) -> String {
    qid.iter().map(|b| format!("{:02x}", b)).collect()
}

// ===== decode_node_data =====

/// Decode a NodeData from a reply payload.
///
/// Reply format (matches Roc encode_reply_payload NodeState):
/// - `[prop_count:U32LE]` then repeated `[key_len:U16LE][key...][value_tag:U8][value_data...]`
/// - `[edge_count:U32LE]` then repeated `[edge_type_len:U16LE][edge_type...][direction:U8][other_qid_len:U16LE][other_qid...]`
///
/// Direction bytes: 0x01=Outgoing, 0x02=Incoming, else=Undirected
fn decode_node_data(qid: &[u8; 16], payload: &[u8]) -> Result<NodeData, ExecuteError> {
    let mut offset = 0;
    let mut properties = HashMap::new();
    let mut edges = Vec::new();

    // Properties
    let (prop_count, new_offset) = read_u32_le(payload, offset)
        .ok_or_else(|| ExecuteError::PlanDecode("truncated prop_count".into()))?;
    offset = new_offset;

    for _ in 0..prop_count {
        let (key, new_offset) = read_string(payload, offset)
            .ok_or_else(|| ExecuteError::PlanDecode("truncated property key".into()))?;
        offset = new_offset;

        let (value, new_offset) = decode_quine_value(payload, offset)
            .ok_or_else(|| ExecuteError::PlanDecode("truncated property value".into()))?;
        offset = new_offset;

        properties.insert(key, value);
    }

    // Edges
    let (edge_count, new_offset) = read_u32_le(payload, offset)
        .ok_or_else(|| ExecuteError::PlanDecode("truncated edge_count".into()))?;
    offset = new_offset;

    for _ in 0..edge_count {
        let (edge_type, new_offset) = read_string(payload, offset)
            .ok_or_else(|| ExecuteError::PlanDecode("truncated edge type".into()))?;
        offset = new_offset;

        if offset >= payload.len() {
            return Err(ExecuteError::PlanDecode("truncated edge direction".into()));
        }
        let direction = match payload[offset] {
            0x01 => Direction::Outgoing,
            0x02 => Direction::Incoming,
            _ => Direction::Undirected,
        };
        offset += 1;

        let (other_len, new_offset) = read_u16_le(payload, offset)
            .ok_or_else(|| ExecuteError::PlanDecode("truncated other_qid len".into()))?;
        offset = new_offset;
        let other_len = other_len as usize;

        if offset + other_len > payload.len() {
            return Err(ExecuteError::PlanDecode("truncated other_qid bytes".into()));
        }
        let mut other_id = [0u8; 16];
        if other_len >= 16 {
            other_id.copy_from_slice(&payload[offset..offset + 16]);
        } else {
            other_id[..other_len].copy_from_slice(&payload[offset..offset + other_len]);
        }
        offset += other_len;

        edges.push(HalfEdge {
            edge_type,
            direction,
            other_id,
        });
    }

    Ok(NodeData {
        id: *qid,
        id_str: qid_to_string(qid),
        properties,
        edges,
    })
}

// ===== fan_out_get_nodes =====

/// Fan out GetNodeState requests to shards and collect replies.
///
/// For each target (qid, shard_id):
///   1. Create a oneshot channel
///   2. Register the sender in PendingRequests keyed by request_id
///   3. Encode and send the GetNodeState message to the shard
///   4. Await the oneshot with 5s timeout
pub async fn fan_out_get_nodes(
    targets: &[([u8; 16], u32)],
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
) -> Vec<Result<NodeData, ExecuteError>> {
    if targets.is_empty() {
        return vec![];
    }

    // Set up all oneshot channels and send messages
    let mut receivers = Vec::with_capacity(targets.len());
    let mut request_ids = Vec::with_capacity(targets.len());

    for (qid, shard_id) in targets {
        let request_id = next_request_id();
        let (tx, rx) = tokio::sync::oneshot::channel::<Vec<u8>>();

        // Register pending request
        {
            let mut map = pending.lock().unwrap();
            map.insert(request_id, tx);
        }

        // Send GetNodeState to shard
        let msg = encode_get_node_state(qid, request_id);
        if !registry.try_send(*shard_id, msg) {
            // Clean up and record failure
            let mut map = pending.lock().unwrap();
            map.remove(&request_id);
            receivers.push(None);
            request_ids.push(request_id);
            continue;
        }

        receivers.push(Some(rx));
        request_ids.push(request_id);
    }

    // Await all replies with timeout
    let mut results = Vec::with_capacity(targets.len());
    let timeout_dur = Duration::from_secs(5);

    for (i, maybe_rx) in receivers.into_iter().enumerate() {
        let qid = &targets[i].0;
        let request_id = request_ids[i];

        match maybe_rx {
            None => {
                results.push(Err(ExecuteError::ShardUnavailable));
            }
            Some(rx) => match tokio::time::timeout(timeout_dur, rx).await {
                Ok(Ok(payload)) => {
                    results.push(decode_node_data(qid, &payload));
                }
                Ok(Err(_)) => {
                    // Sender dropped — shard didn't reply
                    results.push(Err(ExecuteError::ShardTimeout));
                }
                Err(_) => {
                    // Timeout — clean up pending
                    let mut map = pending.lock().unwrap();
                    map.remove(&request_id);
                    results.push(Err(ExecuteError::ShardTimeout));
                }
            },
        }
    }

    results
}

// ===== Plan Step Execution =====

/// Execute a query plan against the graph, returning JSON result rows.
pub async fn execute(
    plan: &QueryPlan,
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) -> Result<Vec<serde_json::Value>, ExecuteError> {
    let mut rows: Vec<Row> = vec![];

    for step in &plan.steps {
        match step {
            PlanStep::ScanSeeds {
                alias_idx,
                label: _,
                inline_props,
                node_ids,
            } => {
                rows = exec_scan_seeds(
                    *alias_idx,
                    node_ids,
                    inline_props,
                    &plan.aliases,
                    pending,
                    registry,
                    shard_count,
                )
                .await?;
            }
            PlanStep::Traverse {
                from_alias_idx,
                to_alias_idx,
                direction,
                edge_type,
                to_label: _,
            } => {
                rows = exec_traverse(
                    &rows,
                    *from_alias_idx,
                    *to_alias_idx,
                    *direction,
                    edge_type.as_deref(),
                    &plan.aliases,
                    pending,
                    registry,
                    shard_count,
                )
                .await?;
            }
            PlanStep::Filter { expr_bytes } => {
                rows = exec_filter(&rows, expr_bytes, &plan.aliases)?;
            }
            PlanStep::Project { items } => {
                return Ok(exec_project(&rows, items, &plan.aliases));
            }
        }
    }

    // If no Project step, return empty results
    Ok(vec![])
}

// ===== exec_scan_seeds =====

async fn exec_scan_seeds(
    alias_idx: usize,
    node_ids: &[[u8; 16]],
    inline_props: &[(String, QuineValue)],
    aliases: &[String],
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) -> Result<Vec<Row>, ExecuteError> {
    // Build targets: (qid, shard_id)
    let targets: Vec<([u8; 16], u32)> = node_ids
        .iter()
        .map(|qid| (*qid, quine_id::shard_for_node(qid, shard_count)))
        .collect();

    let results = fan_out_get_nodes(&targets, pending, registry).await;

    let alias_count = aliases.len();
    let mut rows = Vec::new();

    for result in results {
        match result {
            Ok(node) => {
                // Filter by inline_props: all must match
                let matches = inline_props.iter().all(|(key, value)| {
                    node.properties.get(key).map_or(false, |v| v == value)
                });

                if matches {
                    let mut row: Row = vec![None; alias_count];
                    row[alias_idx] = Some(node);
                    rows.push(row);
                }
            }
            Err(_) => {
                // Skip nodes that couldn't be fetched
                continue;
            }
        }
    }

    Ok(rows)
}

// ===== exec_traverse =====

async fn exec_traverse(
    rows: &[Row],
    from_alias_idx: usize,
    to_alias_idx: usize,
    direction: Direction,
    edge_type: Option<&str>,
    aliases: &[String],
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) -> Result<Vec<Row>, ExecuteError> {
    // Collect all target node IDs from edges, deduplicating
    let mut all_other_ids: Vec<[u8; 16]> = Vec::new();
    let mut seen: HashMap<[u8; 16], usize> = HashMap::new(); // qid -> index in all_other_ids

    // For each row, collect matching edges
    let mut row_edge_targets: Vec<Vec<[u8; 16]>> = Vec::with_capacity(rows.len());

    for row in rows {
        let mut targets_for_row = Vec::new();

        if let Some(Some(from_node)) = row.get(from_alias_idx) {
            for edge in &from_node.edges {
                // Filter by direction
                let dir_matches = match direction {
                    Direction::Outgoing => matches!(edge.direction, Direction::Outgoing),
                    Direction::Incoming => matches!(edge.direction, Direction::Incoming),
                    Direction::Undirected => true,
                };

                // Filter by edge type
                let type_matches = edge_type.map_or(true, |et| edge.edge_type == et);

                if dir_matches && type_matches {
                    targets_for_row.push(edge.other_id);

                    if !seen.contains_key(&edge.other_id) {
                        seen.insert(edge.other_id, all_other_ids.len());
                        all_other_ids.push(edge.other_id);
                    }
                }
            }
        }

        row_edge_targets.push(targets_for_row);
    }

    // Fan out to get all unique target nodes
    let targets: Vec<([u8; 16], u32)> = all_other_ids
        .iter()
        .map(|qid| (*qid, quine_id::shard_for_node(qid, shard_count)))
        .collect();

    let node_results = fan_out_get_nodes(&targets, pending, registry).await;

    // Build lookup map: qid -> NodeData
    let mut node_map: HashMap<[u8; 16], NodeData> = HashMap::new();
    for (i, result) in node_results.into_iter().enumerate() {
        if let Ok(node) = result {
            node_map.insert(all_other_ids[i], node);
        }
    }

    // Expand rows
    let alias_count = aliases.len();
    let mut new_rows = Vec::new();

    for (row_idx, row) in rows.iter().enumerate() {
        for other_id in &row_edge_targets[row_idx] {
            if let Some(to_node) = node_map.get(other_id) {
                let mut new_row = row.clone();
                // Ensure row has enough slots
                while new_row.len() < alias_count {
                    new_row.push(None);
                }
                new_row[to_alias_idx] = Some(to_node.clone());
                new_rows.push(new_row);
            }
        }
    }

    Ok(new_rows)
}

// ===== exec_filter =====

fn exec_filter(
    rows: &[Row],
    expr_bytes: &[u8],
    aliases: &[String],
) -> Result<Vec<Row>, ExecuteError> {
    let (predicate, _) = expr::decode_expr(expr_bytes, 0)
        .map_err(|e| ExecuteError::EvalError(format!("failed to decode filter expr: {}", e)))?;

    let mut result = Vec::new();
    for row in rows {
        let value = eval::eval_expr(&predicate, row, aliases);
        if eval::is_truthy(&value) {
            result.push(row.clone());
        }
    }

    Ok(result)
}

// ===== exec_project =====

fn exec_project(
    rows: &[Row],
    items: &[ProjectItem],
    aliases: &[String],
) -> Vec<serde_json::Value> {
    rows.iter()
        .map(|row| eval::project_row(items, row, aliases))
        .collect()
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quine_id::quine_id_from_str;

    // ---- Task 4 Tests: decode_node_data ----

    #[test]
    fn decode_empty_node_reply() {
        let qid = quine_id_from_str("alice");

        // 0 properties, 0 edges
        let mut payload = Vec::new();
        payload.extend_from_slice(&0u32.to_le_bytes()); // prop_count = 0
        payload.extend_from_slice(&0u32.to_le_bytes()); // edge_count = 0

        let node = decode_node_data(&qid, &payload).unwrap();
        assert_eq!(node.id, qid);
        assert!(node.properties.is_empty());
        assert!(node.edges.is_empty());
    }

    #[test]
    fn decode_node_with_string_prop() {
        let qid = quine_id_from_str("alice");

        let mut payload = Vec::new();
        // 1 property
        payload.extend_from_slice(&1u32.to_le_bytes());

        // key: "name"
        let key_bytes = b"name";
        payload.extend_from_slice(&(key_bytes.len() as u16).to_le_bytes());
        payload.extend_from_slice(key_bytes);

        // value: Str("Alice") — tag 0x01 + len-prefixed utf8
        payload.push(0x01);
        let val_bytes = b"Alice";
        payload.extend_from_slice(&(val_bytes.len() as u16).to_le_bytes());
        payload.extend_from_slice(val_bytes);

        // 0 edges
        payload.extend_from_slice(&0u32.to_le_bytes());

        let node = decode_node_data(&qid, &payload).unwrap();
        assert_eq!(
            node.properties.get("name"),
            Some(&QuineValue::Str("Alice".into()))
        );
        assert!(node.edges.is_empty());
    }

    #[test]
    fn decode_node_with_edge() {
        let qid = quine_id_from_str("alice");
        let other_qid = quine_id_from_str("bob");

        let mut payload = Vec::new();
        // 0 properties
        payload.extend_from_slice(&0u32.to_le_bytes());

        // 1 edge
        payload.extend_from_slice(&1u32.to_le_bytes());

        // edge_type: "KNOWS"
        let edge_type_bytes = b"KNOWS";
        payload.extend_from_slice(&(edge_type_bytes.len() as u16).to_le_bytes());
        payload.extend_from_slice(edge_type_bytes);

        // direction: Outgoing (0x01)
        payload.push(0x01);

        // other_qid
        payload.extend_from_slice(&(other_qid.len() as u16).to_le_bytes());
        payload.extend_from_slice(&other_qid);

        let node = decode_node_data(&qid, &payload).unwrap();
        assert!(node.properties.is_empty());
        assert_eq!(node.edges.len(), 1);
        assert_eq!(node.edges[0].edge_type, "KNOWS");
        assert!(matches!(node.edges[0].direction, Direction::Outgoing));
        assert_eq!(node.edges[0].other_id, other_qid);
    }

    #[test]
    fn decode_truncated_payload_errors() {
        let qid = quine_id_from_str("alice");

        // Completely empty payload — can't even read prop_count
        let result = decode_node_data(&qid, &[]);
        assert!(result.is_err());

        // Has prop_count = 1 but no actual property data
        let mut payload = Vec::new();
        payload.extend_from_slice(&1u32.to_le_bytes()); // prop_count = 1
        let result = decode_node_data(&qid, &payload);
        assert!(result.is_err());
    }

    // ---- Task 5 Tests: exec_filter, exec_project ----

    /// Build a test NodeData with the given id string and properties.
    fn make_node(id_str: &str, props: Vec<(&str, QuineValue)>) -> NodeData {
        let id = quine_id_from_str(id_str);
        let properties: HashMap<String, QuineValue> =
            props.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        NodeData {
            id,
            id_str: id_str.to_string(),
            properties,
            edges: vec![],
        }
    }

    #[test]
    fn exec_filter_keeps_matching_rows() {
        // Two rows: alice (age=25) and bob (age=18)
        // Filter: n.age > 20
        let aliases = vec!["n".to_string()];

        let alice = make_node(
            "alice",
            vec![
                ("name", QuineValue::Str("Alice".into())),
                ("age", QuineValue::Integer(25)),
            ],
        );
        let bob = make_node(
            "bob",
            vec![
                ("name", QuineValue::Str("Bob".into())),
                ("age", QuineValue::Integer(18)),
            ],
        );

        let rows: Vec<Row> = vec![vec![Some(alice)], vec![Some(bob)]];

        // Build filter expr bytes for: n.age > 20
        // Comparison { Property { Variable("n"), "age" }, Gt, Literal(Integer(20)) }
        let mut expr_bytes = Vec::new();
        // TAG_COMPARISON
        expr_bytes.push(0x43);
        // left: TAG_PROPERTY
        expr_bytes.push(0x42);
        // inner: TAG_VARIABLE
        expr_bytes.push(0x41);
        // variable name "n"
        expr_bytes.extend_from_slice(&1u16.to_le_bytes());
        expr_bytes.push(b'n');
        // property key "age"
        expr_bytes.extend_from_slice(&3u16.to_le_bytes());
        expr_bytes.extend_from_slice(b"age");
        // CompOp::Gt = 0x03
        expr_bytes.push(0x03);
        // right: TAG_LITERAL
        expr_bytes.push(0x40);
        // QV_INTEGER = 0x02
        expr_bytes.push(0x02);
        expr_bytes.extend_from_slice(&20u64.to_le_bytes());

        let result = exec_filter(&rows, &expr_bytes, &aliases).unwrap();
        assert_eq!(result.len(), 1);
        // The remaining row should be alice (age=25)
        let node = result[0][0].as_ref().unwrap();
        assert_eq!(node.id_str, "alice");
    }

    #[test]
    fn exec_project_extracts_fields() {
        let aliases = vec!["n".to_string()];
        let node = make_node("alice", vec![("name", QuineValue::Str("Alice".into()))]);
        let rows: Vec<Row> = vec![vec![Some(node)]];

        let items = vec![ProjectItem::NodeProperty {
            alias_idx: 0,
            prop: "name".into(),
            output_name: "name".into(),
        }];

        let result = exec_project(&rows, &items, &aliases);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0]["name"], "Alice");
    }

    // ---- Task 6 Tests: PlanQuery encoding ----

    #[test]
    fn encode_plan_query_wire_format() {
        let msg = encode_plan_query("MATCH (n) RETURN n", &[], 42);
        assert_eq!(msg[0], 0x02); // TAG_SHARD_CMD
        assert_eq!(msg[1], 0x04); // CMD_PLAN_QUERY
        assert_eq!(u64::from_le_bytes(msg[2..10].try_into().unwrap()), 42);
        let query_len = u16::from_le_bytes([msg[10], msg[11]]) as usize;
        assert_eq!(query_len, 18);
        assert_eq!(&msg[12..12 + query_len], b"MATCH (n) RETURN n");
        let hint_offset = 12 + query_len;
        let hint_count = u16::from_le_bytes([msg[hint_offset], msg[hint_offset + 1]]);
        assert_eq!(hint_count, 0);
    }

    #[test]
    fn encode_plan_query_with_hints() {
        let hint1 = [0xAA; 16];
        let hint2 = [0xBB; 16];
        let msg = encode_plan_query("MATCH (n) RETURN n", &[hint1, hint2], 1);
        let query_len = u16::from_le_bytes([msg[10], msg[11]]) as usize;
        let hint_offset = 12 + query_len;
        let hint_count = u16::from_le_bytes([msg[hint_offset], msg[hint_offset + 1]]);
        assert_eq!(hint_count, 2);
        let h1_start = hint_offset + 2;
        assert_eq!(&msg[h1_start..h1_start + 16], &[0xAA; 16]);
        let h2_start = h1_start + 16;
        assert_eq!(&msg[h2_start..h2_start + 16], &[0xBB; 16]);
    }

    #[test]
    fn plan_error_reply_decoding() {
        let error_msg = "parse error";
        let mut payload = vec![0xFF];
        payload.extend_from_slice(&(error_msg.len() as u16).to_le_bytes());
        payload.extend_from_slice(error_msg.as_bytes());
        assert_eq!(payload[0], 0xFF);
        let len = u16::from_le_bytes([payload[1], payload[2]]) as usize;
        let decoded = String::from_utf8_lossy(&payload[3..3 + len]);
        assert_eq!(decoded, "parse error");
    }
}
