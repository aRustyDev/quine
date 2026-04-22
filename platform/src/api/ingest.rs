// platform/src/api/ingest.rs

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use super::AppState;
use crate::ingest::{self, IngestJob, IngestSource, IngestStatus};

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/ingest", post(create_ingest).get(list_ingests))
        .route("/ingest/{name}", get(get_ingest).delete(cancel_ingest))
}

// ---- Request / Response types ----

#[derive(Deserialize)]
struct CreateIngestRequest {
    name: String,
    #[serde(rename = "type")]
    source_type: String,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    data: Option<Vec<String>>,
}

#[derive(Serialize)]
struct IngestResponse {
    name: String,
    status: String,
    records_processed: u64,
    records_failed: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    started_at: Option<String>,
}

fn job_to_response(job: &IngestJob) -> IngestResponse {
    let status = match *job.status.lock().unwrap() {
        IngestStatus::Running => "running",
        IngestStatus::Complete => "complete",
        IngestStatus::Errored(_) => "errored",
        IngestStatus::Cancelled => "cancelled",
    };
    IngestResponse {
        name: job.name.clone(),
        status: status.to_string(),
        records_processed: job.records_processed.load(Ordering::Relaxed),
        records_failed: job.records_failed.load(Ordering::Relaxed),
        started_at: None, // Instant doesn't convert to wall clock; omit for now
    }
}

// ---- Handlers ----

async fn create_ingest(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateIngestRequest>,
) -> Result<(StatusCode, Json<IngestResponse>), (StatusCode, Json<serde_json::Value>)> {
    // Check for duplicate name
    {
        let jobs = state.ingest_jobs.lock().unwrap();
        if jobs.contains_key(&req.name) {
            return Err((
                StatusCode::CONFLICT,
                Json(serde_json::json!({"error": "ingest job already exists", "name": req.name})),
            ));
        }
    }

    let source = match req.source_type.as_str() {
        "file" => {
            let path = req.path.ok_or_else(|| {
                (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"error": "file ingest requires 'path'"})),
                )
            })?;
            IngestSource::File {
                path: PathBuf::from(path),
            }
        }
        "inline" => {
            let data = req.data.ok_or_else(|| {
                (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"error": "inline ingest requires 'data'"})),
                )
            })?;
            IngestSource::Inline { data }
        }
        other => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": format!("unknown ingest type: '{}'", other)})),
            ));
        }
    };

    let job = Arc::new(IngestJob {
        name: req.name.clone(),
        source,
        status: Mutex::new(IngestStatus::Running),
        records_processed: AtomicU64::new(0),
        records_failed: AtomicU64::new(0),
        cancel: Arc::new(AtomicBool::new(false)),
        started_at: Instant::now(),
        completed_at: Mutex::new(None),
    });

    // Register before starting the background thread
    {
        let mut jobs = state.ingest_jobs.lock().unwrap();
        jobs.insert(req.name.clone(), job.clone());
    }

    ingest::start_file_ingest(job.clone(), state.channel_registry, state.shard_count);

    let resp = job_to_response(&job);
    Ok((StatusCode::CREATED, Json(resp)))
}

async fn list_ingests(State(state): State<Arc<AppState>>) -> Json<Vec<IngestResponse>> {
    let jobs = state.ingest_jobs.lock().unwrap();
    let list: Vec<IngestResponse> = jobs.values().map(|j| job_to_response(j)).collect();
    Json(list)
}

async fn get_ingest(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<IngestResponse>, StatusCode> {
    let jobs = state.ingest_jobs.lock().unwrap();
    match jobs.get(&name) {
        Some(job) => Ok(Json(job_to_response(job))),
        None => Err(StatusCode::NOT_FOUND),
    }
}

async fn cancel_ingest(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<IngestResponse>, (StatusCode, Json<serde_json::Value>)> {
    let jobs = state.ingest_jobs.lock().unwrap();
    match jobs.get(&name) {
        None => Err((
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "ingest job not found"})),
        )),
        Some(job) => {
            let current = job.status.lock().unwrap().clone();
            match current {
                IngestStatus::Complete | IngestStatus::Cancelled | IngestStatus::Errored(_) => {
                    Err((
                        StatusCode::BAD_REQUEST,
                        Json(serde_json::json!({"error": format!("job already {}", status_str(&current))})),
                    ))
                }
                IngestStatus::Running => {
                    job.cancel.store(true, Ordering::Relaxed);
                    // Status will be updated by the ingest thread
                    Ok(Json(IngestResponse {
                        name: name.clone(),
                        status: "cancelled".to_string(),
                        records_processed: job.records_processed.load(Ordering::Relaxed),
                        records_failed: job.records_failed.load(Ordering::Relaxed),
                        started_at: None,
                    }))
                }
            }
        }
    }
}

fn status_str(s: &IngestStatus) -> &'static str {
    match s {
        IngestStatus::Running => "running",
        IngestStatus::Complete => "complete",
        IngestStatus::Errored(_) => "errored",
        IngestStatus::Cancelled => "cancelled",
    }
}
