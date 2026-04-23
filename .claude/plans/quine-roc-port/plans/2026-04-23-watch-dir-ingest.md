# Watch-Directory Ingest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--ingest watch-dir /path` CLI flag that watches a directory for `.jsonl` files, ingests each through the existing pipeline, and moves them to `processed/`.

**Architecture:** New `watch_dir.rs` module alongside `ingest.rs`. Core logic is pure functions (filter, move, scan) that are easy to test, composed in a watch loop that uses the `notify` crate for filesystem events. Reuses `process_line` from `ingest.rs` for actual JSONL parsing/routing.

**Tech Stack:** Rust, `notify` v7 (filesystem watcher), existing `crossbeam-channel`, `ingest::process_line`

**Spec:** `.claude/plans/quine-roc-port/refs/specs/watch-dir-ingest.md`

---

### Task 1: Add `notify` dependency

**Files:**
- Modify: `platform/Cargo.toml`

- [ ] **Step 1: Add notify to dependencies**

In `platform/Cargo.toml`, add to `[dependencies]`:

```toml
notify = "7"
```

- [ ] **Step 2: Verify it compiles**

Run: `cd platform && cargo check`
Expected: compiles with no new errors

- [ ] **Step 3: Commit**

```bash
git add platform/Cargo.toml platform/Cargo.lock
git commit -m "deps: add notify crate for filesystem watching"
```

---

### Task 2: Add `WatchDir` variant and `watch_dir` module skeleton

**Files:**
- Modify: `platform/src/ingest.rs` (add enum variant)
- Create: `platform/src/watch_dir.rs` (new module)
- Modify: `platform/src/main.rs` (register module)

- [ ] **Step 1: Add WatchDir variant to IngestSource**

In `platform/src/ingest.rs`, add to the `IngestSource` enum:

```rust
pub enum IngestSource {
    File { path: PathBuf },
    Inline { data: Vec<String> },
    Stdin,
    WatchDir { path: PathBuf },
}
```

- [ ] **Step 2: Handle WatchDir in run_ingest**

In `platform/src/ingest.rs`, the `run_ingest` function matches on `job.source`. Add a branch so it doesn't panic:

```rust
IngestSource::WatchDir { .. } => {
    // Watch-dir jobs use run_watch_dir, not run_ingest
    eprintln!("ingest {}: WatchDir source should use start_watch_dir_ingest", job.name);
    *job.status.lock().unwrap() = IngestStatus::Errored("wrong entry point".into());
    *job.completed_at.lock().unwrap() = Some(Instant::now());
    return;
}
```

Add this arm to the `let lines: Box<...> = match &job.source {` block, before the closing `};`.

- [ ] **Step 3: Create watch_dir.rs skeleton**

Create `platform/src/watch_dir.rs`:

```rust
// platform/src/watch_dir.rs
//
// Watch-directory ingest: monitors a directory for new .jsonl files,
// ingests each through process_line, moves to processed/.

use std::path::{Path, PathBuf};

/// Check if a path has a .jsonl extension.
pub fn is_jsonl_file(path: &Path) -> bool {
    path.extension()
        .map(|ext| ext == "jsonl")
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_jsonl_true() {
        assert!(is_jsonl_file(Path::new("foo.jsonl")));
        assert!(is_jsonl_file(Path::new("/data/incoming/events.jsonl")));
    }

    #[test]
    fn is_jsonl_false() {
        assert!(!is_jsonl_file(Path::new("foo.tmp")));
        assert!(!is_jsonl_file(Path::new("foo.jsonl.partial")));
        assert!(!is_jsonl_file(Path::new("foo.csv")));
        assert!(!is_jsonl_file(Path::new("foo")));
        assert!(!is_jsonl_file(Path::new(".jsonl"))); // hidden file, no stem
    }
}
```

- [ ] **Step 4: Register module in main.rs**

In `platform/src/main.rs`, add after the existing `mod` declarations:

```rust
mod watch_dir;
```

- [ ] **Step 5: Verify it compiles and tests pass**

Run: `cd platform && cargo test watch_dir`
Expected: 2 tests pass (is_jsonl_true, is_jsonl_false)

- [ ] **Step 6: Commit**

```bash
git add platform/src/ingest.rs platform/src/watch_dir.rs platform/src/main.rs
git commit -m "feat: WatchDir source variant and watch_dir module skeleton"
```

---

### Task 3: `move_to_processed` with duplicate handling

**Files:**
- Modify: `platform/src/watch_dir.rs`

- [ ] **Step 1: Write failing tests for move_to_processed**

Add to the `tests` module in `watch_dir.rs`:

```rust
#[test]
fn move_to_processed_basic() {
    let dir = tempfile::tempdir().unwrap();
    let processed = dir.path().join("processed");
    std::fs::create_dir(&processed).unwrap();

    let file = dir.path().join("events.jsonl");
    std::fs::write(&file, "test data").unwrap();

    let dest = move_to_processed(&file, &processed).unwrap();
    assert_eq!(dest, processed.join("events.jsonl"));
    assert!(!file.exists());
    assert!(dest.exists());
    assert_eq!(std::fs::read_to_string(&dest).unwrap(), "test data");
}

#[test]
fn move_to_processed_duplicate_gets_timestamp() {
    let dir = tempfile::tempdir().unwrap();
    let processed = dir.path().join("processed");
    std::fs::create_dir(&processed).unwrap();

    // Pre-existing file in processed/
    std::fs::write(processed.join("events.jsonl"), "old").unwrap();

    let file = dir.path().join("events.jsonl");
    std::fs::write(&file, "new data").unwrap();

    let dest = move_to_processed(&file, &processed).unwrap();
    // Should NOT be the plain name (that's taken)
    assert_ne!(dest, processed.join("events.jsonl"));
    // Should be in processed/ with a timestamp suffix
    assert!(dest.starts_with(&processed));
    let name = dest.file_name().unwrap().to_str().unwrap();
    assert!(name.starts_with("events."));
    assert!(name.ends_with(".jsonl"));
    assert!(!file.exists());
    assert!(dest.exists());
}
```

Add `use tempfile;` is not needed since it's a dev-dependency already used by persistence tests — `tempfile` is in `[dev-dependencies]`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd platform && cargo test watch_dir`
Expected: 2 pass (is_jsonl), 2 FAIL (move_to_processed not found)

- [ ] **Step 3: Implement move_to_processed**

Add to `watch_dir.rs` above the tests module:

```rust
use std::time::SystemTime;

/// Move a file into the processed directory.
/// If a file with the same name already exists, appends a unix timestamp
/// before the extension: `events.1745398800.jsonl`.
pub fn move_to_processed(file: &Path, processed_dir: &Path) -> std::io::Result<PathBuf> {
    let file_name = file.file_name().unwrap_or_default();
    let mut dest = processed_dir.join(file_name);

    if dest.exists() {
        let stem = file.file_stem().unwrap_or_default().to_str().unwrap_or("file");
        let ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        dest = processed_dir.join(format!("{}.{}.jsonl", stem, ts));
    }

    std::fs::rename(file, &dest)?;
    Ok(dest)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd platform && cargo test watch_dir`
Expected: 4 tests pass

- [ ] **Step 5: Commit**

```bash
git add platform/src/watch_dir.rs
git commit -m "feat: move_to_processed with duplicate timestamp handling"
```

---

### Task 4: `scan_existing_files` and `ingest_single_file`

**Files:**
- Modify: `platform/src/watch_dir.rs`

- [ ] **Step 1: Write failing test for scan_existing_files**

Add to tests:

```rust
#[test]
fn scan_finds_jsonl_only() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.jsonl"), "{}").unwrap();
    std::fs::write(dir.path().join("b.jsonl"), "{}").unwrap();
    std::fs::write(dir.path().join("c.tmp"), "{}").unwrap();
    std::fs::write(dir.path().join("d.csv"), "{}").unwrap();
    std::fs::create_dir(dir.path().join("processed")).unwrap();

    let files = scan_existing_files(dir.path());
    assert_eq!(files.len(), 2);
    assert!(files.iter().all(|p| is_jsonl_file(p)));
}

#[test]
fn scan_empty_dir() {
    let dir = tempfile::tempdir().unwrap();
    let files = scan_existing_files(dir.path());
    assert!(files.is_empty());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd platform && cargo test watch_dir`
Expected: 4 pass, 2 FAIL

- [ ] **Step 3: Implement scan_existing_files**

Add to `watch_dir.rs`:

```rust
/// Scan a directory for existing .jsonl files. Returns sorted paths.
/// Skips subdirectories (e.g., processed/).
pub fn scan_existing_files(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => {
            eprintln!("watch-dir: failed to scan {}: {}", dir.display(), e);
            return files;
        }
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file() && is_jsonl_file(&path) {
            files.push(path);
        }
    }
    files.sort();
    files
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd platform && cargo test watch_dir`
Expected: 6 tests pass

- [ ] **Step 5: Write ingest_single_file**

This function opens a file, reads lines, calls `process_line` for each, updates job counters, and returns whether it succeeded. Add to `watch_dir.rs`:

```rust
use std::io::{BufRead, BufReader};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use crate::channels::ChannelRegistry;
use crate::ingest::{self, LineOutcome};

/// Ingest a single .jsonl file through the shard pipeline.
/// Returns Ok(()) on success (even if some lines failed), Err on file open/read failure.
pub fn ingest_single_file(
    file: &Path,
    registry: &ChannelRegistry,
    shard_count: u32,
    cancel: &AtomicBool,
    records_processed: &AtomicU64,
    records_failed: &AtomicU64,
) -> std::io::Result<bool> {
    let f = std::fs::File::open(file)?;
    let reader = BufReader::new(f);
    let mut cancelled = false;

    for line_result in reader.lines() {
        if cancel.load(Ordering::Relaxed) {
            cancelled = true;
            break;
        }
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                eprintln!("watch-dir: read error in {}: {}", file.display(), e);
                records_failed.fetch_add(1, Ordering::Relaxed);
                continue;
            }
        };
        match ingest::process_line(&line, registry, shard_count, cancel) {
            LineOutcome::Processed => {
                records_processed.fetch_add(1, Ordering::Relaxed);
            }
            LineOutcome::Skipped => {}
            LineOutcome::Failed(e) => {
                eprintln!("watch-dir: parse error in {}: {}", file.display(), e);
                records_failed.fetch_add(1, Ordering::Relaxed);
            }
            LineOutcome::Cancelled => {
                cancelled = true;
                break;
            }
        }
    }

    Ok(!cancelled)
}
```

- [ ] **Step 6: Write test for ingest_single_file**

Add to tests:

```rust
use std::sync::atomic::{AtomicBool, AtomicU64};

#[test]
fn ingest_single_file_processes_lines() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("test.jsonl");
    std::fs::write(&file, concat!(
        r#"{"type":"set_prop","node_id":"a","key":"k","value":1}"#, "\n",
        r#"{"type":"set_prop","node_id":"b","key":"k","value":2}"#, "\n",
    )).unwrap();

    let registry = crate::channels::ChannelRegistry::new(4, 64);
    let cancel = AtomicBool::new(false);
    let processed = AtomicU64::new(0);
    let failed = AtomicU64::new(0);

    let ok = ingest_single_file(&file, &registry, 4, &cancel, &processed, &failed).unwrap();
    assert!(ok);
    assert_eq!(processed.load(Ordering::Relaxed), 2);
    assert_eq!(failed.load(Ordering::Relaxed), 0);
}

#[test]
fn ingest_single_file_counts_bad_lines() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("mixed.jsonl");
    std::fs::write(&file, concat!(
        r#"{"type":"set_prop","node_id":"a","key":"k","value":1}"#, "\n",
        "not json\n",
        r#"{"type":"set_prop","node_id":"b","key":"k","value":2}"#, "\n",
    )).unwrap();

    let registry = crate::channels::ChannelRegistry::new(4, 64);
    let cancel = AtomicBool::new(false);
    let processed = AtomicU64::new(0);
    let failed = AtomicU64::new(0);

    let ok = ingest_single_file(&file, &registry, 4, &cancel, &processed, &failed).unwrap();
    assert!(ok);
    assert_eq!(processed.load(Ordering::Relaxed), 2);
    assert_eq!(failed.load(Ordering::Relaxed), 1);
}
```

- [ ] **Step 7: Run tests**

Run: `cd platform && cargo test watch_dir`
Expected: 8 tests pass

- [ ] **Step 8: Commit**

```bash
git add platform/src/watch_dir.rs
git commit -m "feat: scan_existing_files and ingest_single_file"
```

---

### Task 5: `run_watch_dir` — the main loop

**Files:**
- Modify: `platform/src/watch_dir.rs`

- [ ] **Step 1: Implement run_watch_dir**

This is the main entry point. Add to `watch_dir.rs`:

```rust
use std::sync::Arc;
use std::time::Instant;

use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};

use crate::ingest::{IngestJob, IngestStatus};

/// Run the watch-directory ingest loop.
/// Blocks until cancelled. Meant to be called on a dedicated thread.
pub fn run_watch_dir(
    job: Arc<IngestJob>,
    registry: &ChannelRegistry,
    shard_count: u32,
) {
    let watch_path = match &job.source {
        crate::ingest::IngestSource::WatchDir { path } => path.clone(),
        _ => {
            eprintln!("watch-dir: job '{}' is not a WatchDir source", job.name);
            return;
        }
    };

    // Create processed/ subdirectory
    let processed_dir = watch_path.join("processed");
    if let Err(e) = std::fs::create_dir_all(&processed_dir) {
        *job.status.lock().unwrap() =
            IngestStatus::Errored(format!("failed to create processed dir: {}", e));
        *job.completed_at.lock().unwrap() = Some(Instant::now());
        return;
    }

    eprintln!(
        "watch-dir '{}': watching {} (processed → {})",
        job.name,
        watch_path.display(),
        processed_dir.display()
    );

    // 1. Scan and ingest existing .jsonl files
    let existing = scan_existing_files(&watch_path);
    for file in existing {
        if job.cancel.load(Ordering::Relaxed) {
            break;
        }
        process_and_move(&file, &processed_dir, registry, shard_count, &job);
    }

    if job.cancel.load(Ordering::Relaxed) {
        *job.status.lock().unwrap() = IngestStatus::Cancelled;
        *job.completed_at.lock().unwrap() = Some(Instant::now());
        return;
    }

    // 2. Watch for new files via notify
    let (tx, rx) = std::sync::mpsc::channel();
    let mut watcher: RecommendedWatcher = match Watcher::new(
        move |res: Result<Event, notify::Error>| {
            if let Ok(event) = res {
                let _ = tx.send(event);
            }
        },
        Config::default(),
    ) {
        Ok(w) => w,
        Err(e) => {
            *job.status.lock().unwrap() =
                IngestStatus::Errored(format!("failed to start watcher: {}", e));
            *job.completed_at.lock().unwrap() = Some(Instant::now());
            return;
        }
    };

    if let Err(e) = watcher.watch(&watch_path, RecursiveMode::NonRecursive) {
        *job.status.lock().unwrap() =
            IngestStatus::Errored(format!("failed to watch directory: {}", e));
        *job.completed_at.lock().unwrap() = Some(Instant::now());
        return;
    }

    // 3. Event loop
    loop {
        // Use recv_timeout so we can check the cancel flag periodically
        match rx.recv_timeout(std::time::Duration::from_millis(500)) {
            Ok(event) => {
                match event.kind {
                    EventKind::Create(_) | EventKind::Modify(notify::event::ModifyKind::Name(_)) => {
                        for path in &event.paths {
                            if path.is_file() && is_jsonl_file(path) {
                                process_and_move(path, &processed_dir, registry, shard_count, &job);
                            }
                        }
                    }
                    _ => {}
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                eprintln!("watch-dir '{}': watcher disconnected", job.name);
                break;
            }
        }

        if job.cancel.load(Ordering::Relaxed) {
            break;
        }
    }

    *job.status.lock().unwrap() = IngestStatus::Cancelled;
    *job.completed_at.lock().unwrap() = Some(Instant::now());
    eprintln!(
        "watch-dir '{}': stopped ({} processed, {} failed)",
        job.name,
        job.records_processed.load(Ordering::Relaxed),
        job.records_failed.load(Ordering::Relaxed),
    );
}

/// Ingest a file and move it to processed/. Logs errors but does not propagate.
fn process_and_move(
    file: &Path,
    processed_dir: &Path,
    registry: &ChannelRegistry,
    shard_count: u32,
    job: &IngestJob,
) {
    match ingest_single_file(
        file,
        registry,
        shard_count,
        &job.cancel,
        &job.records_processed,
        &job.records_failed,
    ) {
        Ok(true) => {
            // Ingest succeeded — move to processed
            match move_to_processed(file, processed_dir) {
                Ok(dest) => {
                    eprintln!(
                        "watch-dir '{}': ingested {} → {}",
                        job.name,
                        file.display(),
                        dest.display()
                    );
                }
                Err(e) => {
                    eprintln!(
                        "watch-dir '{}': failed to move {}: {}",
                        job.name,
                        file.display(),
                        e
                    );
                }
            }
        }
        Ok(false) => {
            // Cancelled mid-file — don't move
            eprintln!("watch-dir '{}': cancelled during {}", job.name, file.display());
        }
        Err(e) => {
            eprintln!(
                "watch-dir '{}': failed to read {}: {}",
                job.name,
                file.display(),
                e
            );
            job.records_failed.fetch_add(1, Ordering::Relaxed);
        }
    }
}
```

- [ ] **Step 2: Add start_watch_dir_ingest launcher**

Add to `watch_dir.rs`:

```rust
/// Start a watch-directory ingest job on a dedicated thread.
pub fn start_watch_dir_ingest(
    job: Arc<IngestJob>,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) {
    std::thread::Builder::new()
        .name(format!("watch-dir-{}", job.name))
        .spawn(move || run_watch_dir(job, registry, shard_count))
        .expect("failed to spawn watch-dir thread");
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cd platform && cargo check`
Expected: compiles (may have unused import warnings, that's fine)

- [ ] **Step 4: Write integration test for scan-and-move flow**

Add to tests:

```rust
use std::sync::Mutex;

#[test]
fn process_and_move_full_flow() {
    let dir = tempfile::tempdir().unwrap();
    let processed = dir.path().join("processed");
    std::fs::create_dir(&processed).unwrap();

    let file = dir.path().join("events.jsonl");
    std::fs::write(&file, concat!(
        r#"{"type":"set_prop","node_id":"a","key":"k","value":1}"#, "\n",
    )).unwrap();

    let registry = crate::channels::ChannelRegistry::new(4, 64);
    let job = Arc::new(IngestJob {
        name: "test-watch".into(),
        source: crate::ingest::IngestSource::WatchDir { path: dir.path().to_path_buf() },
        status: Mutex::new(IngestStatus::Running),
        records_processed: AtomicU64::new(0),
        records_failed: AtomicU64::new(0),
        cancel: Arc::new(AtomicBool::new(false)),
        started_at: Instant::now(),
        completed_at: Mutex::new(None),
    });

    process_and_move(&file, &processed, &registry, 4, &job);

    assert_eq!(job.records_processed.load(Ordering::Relaxed), 1);
    assert!(!file.exists());
    assert!(processed.join("events.jsonl").exists());
}
```

- [ ] **Step 5: Run tests**

Run: `cd platform && cargo test watch_dir`
Expected: 9 tests pass

- [ ] **Step 6: Commit**

```bash
git add platform/src/watch_dir.rs
git commit -m "feat: run_watch_dir loop with notify watcher"
```

---

### Task 6: CLI wiring in main.rs

**Files:**
- Modify: `platform/src/main.rs`

- [ ] **Step 1: Add watch-dir CLI flag parser**

In `main.rs`, add a new helper function alongside `has_stdin_ingest_flag`:

```rust
/// Check if `--ingest watch-dir <path>` was passed on the command line.
/// Returns the path if found.
fn watch_dir_ingest_path() -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.windows(3)
        .find(|w| w[0] == "--ingest" && w[1] == "watch-dir")
        .map(|w| w[2].clone())
}
```

- [ ] **Step 2: Wire up watch-dir ingest startup**

In `main.rs`, after the existing stdin ingest block (`if has_stdin_ingest_flag() { ... }`), add:

```rust
// If --ingest watch-dir <path> was passed, auto-start a watch-dir ingest job.
if let Some(watch_path) = watch_dir_ingest_path() {
    let path = std::path::PathBuf::from(&watch_path);
    if !path.is_dir() {
        eprintln!("error: --ingest watch-dir path '{}' is not a directory", watch_path);
        std::process::exit(1);
    }
    let job = Arc::new(ingest::IngestJob {
        name: "watch-dir".into(),
        source: ingest::IngestSource::WatchDir { path: path.clone() },
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
```

- [ ] **Step 3: Verify it compiles**

Run: `cd platform && cargo check`
Expected: compiles

- [ ] **Step 4: Run full test suite**

Run: `cd platform && cargo test`
Expected: all tests pass (no regressions)

- [ ] **Step 5: Commit**

```bash
git add platform/src/main.rs
git commit -m "feat: --ingest watch-dir CLI flag"
```

---

### Task 7: Cancel flag test

**Files:**
- Modify: `platform/src/watch_dir.rs`

- [ ] **Step 1: Write test for cancel stopping the scan loop**

Add to tests:

```rust
#[test]
fn cancel_stops_scan() {
    let dir = tempfile::tempdir().unwrap();
    let processed = dir.path().join("processed");
    std::fs::create_dir(&processed).unwrap();

    // Create several files
    for i in 0..5 {
        let file = dir.path().join(format!("file{}.jsonl", i));
        std::fs::write(&file, format!(
            r#"{{"type":"set_prop","node_id":"n{}","key":"k","value":{}}}"#, i, i
        )).unwrap();
    }

    let registry = crate::channels::ChannelRegistry::new(4, 64);
    let cancel = AtomicBool::new(false);
    let processed_count = AtomicU64::new(0);
    let failed_count = AtomicU64::new(0);

    // Ingest first file, then set cancel
    let files = scan_existing_files(dir.path());
    assert_eq!(files.len(), 5);

    // Process first file normally
    let ok = ingest_single_file(&files[0], &registry, 4, &cancel, &processed_count, &failed_count).unwrap();
    assert!(ok);

    // Set cancel, process next file
    cancel.store(true, Ordering::Relaxed);
    let ok2 = ingest_single_file(&files[1], &registry, 4, &cancel, &processed_count, &failed_count).unwrap();
    assert!(!ok2); // Should report cancelled
}
```

- [ ] **Step 2: Run test**

Run: `cd platform && cargo test watch_dir::tests::cancel_stops_scan`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add platform/src/watch_dir.rs
git commit -m "test: cancel flag stops watch-dir ingest"
```

---

### Task 8: Final full test run and cleanup

**Files:**
- All modified files

- [ ] **Step 1: Run all Rust tests**

Run: `cd platform && cargo test`
Expected: all tests pass

- [ ] **Step 2: Run all Roc tests (sanity check — no Roc changes)**

Run: `roc test packages/graph/shard/ShardState.roc`
Expected: 61 tests pass (unchanged)

- [ ] **Step 3: Check for warnings**

Run: `cd platform && cargo check 2>&1 | grep "warning:"`
Expected: only pre-existing warnings (effects.rs, api/mod.rs, roc_glue.rs)

- [ ] **Step 4: Final commit if any cleanup needed**

If any fixes were needed, commit them:

```bash
git add -u
git commit -m "chore: watch-dir cleanup"
```

- [ ] **Step 5: Push**

```bash
bd dolt push
git push
```
