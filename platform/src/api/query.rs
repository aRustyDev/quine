// platform/src/api/query.rs
//
// POST /api/v1/query — execute a Cypher query against the graph.
//
// Mechanism:
//   1. Parse the JSON request (query string + optional node_id hints)
//   2. Convert node_id hints to QuineIds
//   3. Send the query to shard 0 for planning (Roc parses + plans)
//   4. Extract column names from the Project step
//   5. Execute the plan (fan-out to shards, filter, project)
//   6. Return JSON results with columns, rows, and timing

use std::sync::Arc;
use std::time::Instant;

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use serde::Deserialize;

use super::AppState;
use crate::cypher::executor;
use crate::cypher::plan::QueryPlan;
use crate::quine_id;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new().route("/query", post(execute_query))
}

#[derive(Deserialize)]
struct QueryRequest {
    query: String,
    #[serde(default)]
    node_ids: Vec<String>,
}

async fn execute_query(
    State(state): State<Arc<AppState>>,
    Json(req): Json<QueryRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let start = Instant::now();

    // Convert node_id hints to QuineIds
    let hint_qids: Vec<[u8; 16]> = req.node_ids.iter().map(|s| quine_id::quine_id_from_str(s)).collect();

    // Phase 1: Plan the query (send to shard, Roc parses + plans)
    let plan = executor::plan_query(
        &req.query,
        &hint_qids,
        &state.pending_requests,
        state.channel_registry,
    )
    .await
    .map_err(|e| error_response(&e))?;

    // Extract column names from the Project step
    let columns = extract_columns(&plan);

    // Phase 2: Execute the plan
    let rows = executor::execute(
        &plan,
        &state.pending_requests,
        state.channel_registry,
        state.shard_count,
    )
    .await
    .map_err(|e| error_response(&e))?;

    let took_ms = start.elapsed().as_millis() as u64;

    Ok(Json(serde_json::json!({
        "columns": columns,
        "rows": rows,
        "took_ms": took_ms,
    })))
}

/// Extract column names from the Project step in a QueryPlan.
fn extract_columns(plan: &QueryPlan) -> Vec<String> {
    for step in &plan.steps {
        if let crate::cypher::plan::PlanStep::Project { items } = step {
            return items
                .iter()
                .map(|item| match item {
                    crate::cypher::plan::ProjectItem::WholeNode(idx) => {
                        plan.aliases.get(*idx).cloned().unwrap_or_else(|| format!("_{}", idx))
                    }
                    crate::cypher::plan::ProjectItem::NodeProperty { output_name, .. } => {
                        output_name.clone()
                    }
                })
                .collect();
        }
    }
    vec![]
}

fn error_response(err: &executor::ExecuteError) -> (StatusCode, Json<serde_json::Value>) {
    let (status, msg) = match err {
        executor::ExecuteError::PlanError(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
        executor::ExecuteError::PlanDecode(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
        executor::ExecuteError::EvalError(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg.clone()),
        executor::ExecuteError::ShardTimeout => {
            (StatusCode::GATEWAY_TIMEOUT, "query timed out".into())
        }
        executor::ExecuteError::ShardUnavailable => {
            (StatusCode::SERVICE_UNAVAILABLE, "shard unavailable".into())
        }
    };
    (status, Json(serde_json::json!({"error": msg})))
}
