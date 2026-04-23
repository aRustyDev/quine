// platform/src/api/tests.rs
//
// Integration tests for the REST API endpoints.
// Uses axum's built-in test client (tower::ServiceExt) to exercise handlers
// with a real AppState but without starting the full platform or Roc runtime.

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, AtomicU64};
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt; // for oneshot

    use crate::api::{self, AppState};
    use crate::channels::ChannelRegistry;
    use crate::ingest::{self, IngestJob, IngestSource, IngestStatus};

    /// Create a test AppState with a real ChannelRegistry.
    fn test_state() -> Arc<AppState> {
        let registry = ChannelRegistry::new(4, 64);
        // Leak to get 'static reference (acceptable in tests)
        let registry: &'static ChannelRegistry = Box::leak(Box::new(registry));

        let (sq_tx, sq_rx) = crossbeam_channel::bounded::<Vec<u8>>(64);
        let _ = sq_tx; // kept alive by channel

        Arc::new(AppState {
            channel_registry: registry,
            ingest_jobs: ingest::new_registry(),
            sq_registry: api::new_sq_registry(),
            sq_result_rx: sq_rx,
            pending_requests: api::new_pending_requests(),
            shard_count: 4,
            start_time: Instant::now(),
        })
    }

    fn app(state: Arc<AppState>) -> axum::Router {
        api::api_routes(state)
    }

    // ---- Health Endpoint Tests ----

    #[tokio::test]
    async fn health_returns_ok() {
        let state = test_state();
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/v1/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["status"], "ok");
        assert_eq!(json["shards"], 4);
    }

    // ---- Ingest Endpoint Tests ----

    #[tokio::test]
    async fn create_inline_ingest() {
        let state = test_state();
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v1/ingest")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        r#"{"name":"test","type":"inline","data":["{\"type\":\"set_prop\",\"node_id\":\"a\",\"key\":\"x\",\"value\":1}"]}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["name"], "test");
        assert_eq!(json["status"], "running");
    }

    #[tokio::test]
    async fn duplicate_ingest_name_returns_409() {
        let state = test_state();

        // Pre-populate with a job
        {
            let job = Arc::new(IngestJob {
                name: "existing".into(),
                source: IngestSource::Inline {
                    data: vec![],
                },
                status: Mutex::new(IngestStatus::Running),
                records_processed: AtomicU64::new(0),
                records_failed: AtomicU64::new(0),
                cancel: Arc::new(AtomicBool::new(false)),
                started_at: Instant::now(),
                completed_at: Mutex::new(None),
            });
            state.ingest_jobs.lock().unwrap().insert("existing".into(), job);
        }

        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v1/ingest")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        r#"{"name":"existing","type":"inline","data":[]}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CONFLICT);
    }

    #[tokio::test]
    async fn list_ingests_returns_jobs() {
        let state = test_state();

        // Pre-populate with a job
        {
            let job = Arc::new(IngestJob {
                name: "job1".into(),
                source: IngestSource::Inline { data: vec![] },
                status: Mutex::new(IngestStatus::Complete),
                records_processed: AtomicU64::new(100),
                records_failed: AtomicU64::new(2),
                cancel: Arc::new(AtomicBool::new(false)),
                started_at: Instant::now(),
                completed_at: Mutex::new(Some(Instant::now())),
            });
            state.ingest_jobs.lock().unwrap().insert("job1".into(), job);
        }

        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/v1/ingest")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let arr = json.as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["name"], "job1");
        assert_eq!(arr[0]["status"], "complete");
        assert_eq!(arr[0]["records_processed"], 100);
    }

    #[tokio::test]
    async fn get_ingest_not_found() {
        let state = test_state();
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/v1/ingest/nonexistent")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn cancel_running_ingest() {
        let state = test_state();

        {
            let job = Arc::new(IngestJob {
                name: "cancellable".into(),
                source: IngestSource::Inline { data: vec![] },
                status: Mutex::new(IngestStatus::Running),
                records_processed: AtomicU64::new(50),
                records_failed: AtomicU64::new(0),
                cancel: Arc::new(AtomicBool::new(false)),
                started_at: Instant::now(),
                completed_at: Mutex::new(None),
            });
            state
                .ingest_jobs
                .lock()
                .unwrap()
                .insert("cancellable".into(), job);
        }

        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/api/v1/ingest/cancellable")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["status"], "cancelled");
    }

    #[tokio::test]
    async fn create_stdin_ingest() {
        let state = test_state();
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v1/ingest")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"name":"stdin-test","type":"stdin"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["name"], "stdin-test");
        assert_eq!(json["status"], "running");
    }

    // ---- Standing Query Endpoint Tests ----

    #[tokio::test]
    async fn create_standing_query() {
        let state = test_state();
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v1/standing-queries")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        r#"{"query":{"type":"LocalProperty","prop_key":"name","constraint":{"type":"Any"},"aliased_as":"n"},"include_cancellations":false}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(json["id"].is_string());
        assert_eq!(json["status"], "running");
    }

    #[tokio::test]
    async fn cancel_nonexistent_sq_returns_404() {
        let state = test_state();
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/api/v1/standing-queries/00000000000000000000000000000000")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    // ---- Node Query Endpoint Tests ----

    #[tokio::test]
    async fn node_query_timeout_returns_504() {
        let state = test_state();
        let pending = state.pending_requests.clone();
        assert!(pending.lock().unwrap().is_empty());

        let app = app(state);

        // Calls GetProps on the shard channel, but no worker is reading —
        // the oneshot will time out after 5s.
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/v1/nodes/test-node")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // Should timeout (504) since no shard worker is processing
        assert_eq!(resp.status(), StatusCode::GATEWAY_TIMEOUT);
    }

    // ---- SQ Result Decoding ----

    #[test]
    fn decode_sq_result_bytes() {
        // Construct a minimal SQ result: query_id=1, is_positive=true
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&1u64.to_le_bytes()); // lo
        bytes.extend_from_slice(&0u64.to_le_bytes()); // hi
        bytes.push(1); // is_positive_match = true
        bytes.extend_from_slice(&0u32.to_le_bytes()); // pair_count = 0

        let result = crate::api::standing_queries::decode_sq_result(&bytes);
        assert!(result.is_some());
        let (query_id, entry) = result.unwrap();
        assert_eq!(query_id, 1);
        assert!(entry.is_positive_match);
    }

    // ---- Node Reply Decoding ----

    #[test]
    fn decode_empty_node_reply() {
        // Empty props + empty edges
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&0u32.to_le_bytes()); // prop_count = 0
        bytes.extend_from_slice(&0u32.to_le_bytes()); // edge_count = 0

        let json = crate::api::nodes::decode_node_reply("test", &bytes);
        assert_eq!(json["id"], "test");
        assert_eq!(json["properties"], serde_json::json!({}));
        assert_eq!(json["edges"], serde_json::json!([]));
    }

    #[test]
    fn decode_node_reply_with_string_prop() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&1u32.to_le_bytes()); // prop_count = 1
        // key: "name" (len=4)
        bytes.extend_from_slice(&4u16.to_le_bytes());
        bytes.extend_from_slice(b"name");
        // value: Str "Alice" (tag=0x01, len=5)
        bytes.push(0x01);
        bytes.extend_from_slice(&5u16.to_le_bytes());
        bytes.extend_from_slice(b"Alice");
        // edges
        bytes.extend_from_slice(&0u32.to_le_bytes()); // edge_count = 0

        let json = crate::api::nodes::decode_node_reply("alice", &bytes);
        assert_eq!(json["id"], "alice");
        assert_eq!(json["properties"]["name"], "Alice");
    }

    #[test]
    fn decode_node_reply_with_integer_prop() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&1u32.to_le_bytes()); // prop_count = 1
        // key: "age" (len=3)
        bytes.extend_from_slice(&3u16.to_le_bytes());
        bytes.extend_from_slice(b"age");
        // value: Integer 30 (tag=0x02)
        bytes.push(0x02);
        bytes.extend_from_slice(&30u64.to_le_bytes());
        // edges
        bytes.extend_from_slice(&0u32.to_le_bytes());

        let json = crate::api::nodes::decode_node_reply("alice", &bytes);
        assert_eq!(json["properties"]["age"], 30);
    }
}
