// platform/src/watch_dir.rs
//
// Watch-directory ingest: filesystem watching with notify, file ingestion,
// and coordination with the ingest pipeline.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};

use crate::channels::ChannelRegistry;
use crate::ingest::{self, IngestSource, IngestStatus, LineOutcome};

// ============================================================
// File classification
// ============================================================

/// Return true if `path` names a regular `.jsonl` file that should be
/// ingested. Rejects partial files, hidden files whose name starts with a
/// dot, and files with no stem.
///
/// Rules:
///   - Must have extension exactly `jsonl`
///   - Must have a non-empty file stem
///   - Stem must not be empty (rejects `.jsonl`)
pub fn is_jsonl_file(path: &Path) -> bool {
    let file_name = match path.file_name().and_then(|n| n.to_str()) {
        Some(n) => n,
        None => return false,
    };

    // Reject names that start with a dot (hidden / partial files)
    if file_name.starts_with('.') {
        return false;
    }

    match path.extension().and_then(|e| e.to_str()) {
        Some("jsonl") => {}
        _ => return false,
    }

    // Must have a non-empty stem (guards against ".jsonl" which has no stem)
    match path.file_stem().and_then(|s| s.to_str()) {
        Some(s) if !s.is_empty() => {}
        _ => return false,
    }

    true
}

// ============================================================
// File movement
// ============================================================

/// Move `file` into `processed_dir`, renaming it to avoid collisions.
///
/// If `processed_dir/<file_name>` does not exist, rename straight across.
/// If it does exist, append the current Unix timestamp before the extension:
/// `{stem}.{unix_secs}.jsonl`.
pub fn move_to_processed(file: &Path, processed_dir: &Path) -> std::io::Result<PathBuf> {
    let file_name = file
        .file_name()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "no file name"))?;

    let dest = processed_dir.join(file_name);

    let dest = if dest.exists() {
        // Build a collision-free name: {stem}.{unix_timestamp}.jsonl
        let stem = file
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("file");
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        processed_dir.join(format!("{}.{}.jsonl", stem, ts))
    } else {
        dest
    };

    std::fs::rename(file, &dest)?;
    Ok(dest)
}

// ============================================================
// Directory scanning
// ============================================================

/// Return all `.jsonl` files in `dir` (non-recursive), sorted by name.
/// Subdirectories and non-JSONL files are skipped.
pub fn scan_existing_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = match std::fs::read_dir(dir) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .map(|e| e.path())
            .filter(|p| is_jsonl_file(p))
            .collect(),
        Err(_) => Vec::new(),
    };

    files.sort();
    files
}

// ============================================================
// Single-file ingest
// ============================================================

/// Ingest a single `.jsonl` file line-by-line, routing each record to the
/// appropriate shard channel via `process_line`.
///
/// Returns:
///   - `Ok(true)`  — all lines processed (or file was empty)
///   - `Ok(false)` — cancelled via `cancel` flag before EOF
///   - `Err(_)`    — could not open the file
///
/// `records_processed` counts lines that produced a valid shard message.
/// `records_failed` counts lines that failed to parse.
pub fn ingest_single_file(
    file: &Path,
    registry: &ChannelRegistry,
    shard_count: u32,
    cancel: &AtomicBool,
    records_processed: &AtomicU64,
    records_failed: &AtomicU64,
) -> std::io::Result<bool> {
    use std::io::BufRead;

    let f = std::fs::File::open(file)?;
    let reader = std::io::BufReader::new(f);

    for line_result in reader.lines() {
        if cancel.load(Ordering::Relaxed) {
            return Ok(false);
        }

        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                eprintln!("watch_dir: read error in {}: {}", file.display(), e);
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
                eprintln!("watch_dir: parse error in {}: {}", file.display(), e);
                records_failed.fetch_add(1, Ordering::Relaxed);
            }
            LineOutcome::Cancelled => {
                return Ok(false);
            }
        }
    }

    Ok(true)
}

// ============================================================
// Watch-directory ingest loop
// ============================================================

/// Ingest a single file and move it to `processed_dir` on success.
///
/// Returns true if the file was fully processed, false if cancelled,
/// or logs and skips the file on error.
fn process_and_move(
    file: &Path,
    job: &Arc<crate::ingest::IngestJob>,
    registry: &ChannelRegistry,
    shard_count: u32,
    processed_dir: &Path,
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
            // Fully processed — move to processed/
            if let Err(e) = move_to_processed(file, processed_dir) {
                eprintln!(
                    "watch_dir {}: failed to move {} to processed: {}",
                    job.name,
                    file.display(),
                    e
                );
            }
        }
        Ok(false) => {
            // Cancelled mid-file — leave file in place, do not move
        }
        Err(e) => {
            eprintln!(
                "watch_dir {}: failed to open {}: {}",
                job.name,
                file.display(),
                e
            );
            job.records_failed.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// Main watch-directory loop.
///
/// - Reads the watch path from `job.source` (must be `IngestSource::WatchDir`).
/// - Creates a `processed/` subdirectory; returns an error status if it cannot.
/// - Ingests any pre-existing `.jsonl` files, then starts watching for new ones.
/// - Exits on cancel or watcher disconnect, setting status to `Cancelled`.
pub fn run_watch_dir(
    job: Arc<crate::ingest::IngestJob>,
    registry: &ChannelRegistry,
    shard_count: u32,
) {
    // Extract watch path from job source
    let watch_path = match &job.source {
        IngestSource::WatchDir { path } => path.clone(),
        _ => {
            *job.status.lock().unwrap() =
                IngestStatus::Errored("run_watch_dir called with wrong IngestSource".into());
            *job.completed_at.lock().unwrap() = Some(std::time::Instant::now());
            return;
        }
    };

    // Create processed/ subdirectory
    let processed_dir = watch_path.join("processed");
    if let Err(e) = std::fs::create_dir_all(&processed_dir) {
        *job.status.lock().unwrap() =
            IngestStatus::Errored(format!("failed to create processed dir: {}", e));
        *job.completed_at.lock().unwrap() = Some(std::time::Instant::now());
        return;
    }

    // Ingest any existing .jsonl files
    for file in scan_existing_files(&watch_path) {
        if job.cancel.load(Ordering::Relaxed) {
            break;
        }
        process_and_move(&file, &job, registry, shard_count, &processed_dir);
    }

    // Set up notify watcher with an std::sync::mpsc channel
    let (tx, rx) = std::sync::mpsc::channel::<notify::Result<Event>>();
    let mut watcher = match RecommendedWatcher::new(
        move |res| {
            let _ = tx.send(res);
        },
        Config::default(),
    ) {
        Ok(w) => w,
        Err(e) => {
            *job.status.lock().unwrap() =
                IngestStatus::Errored(format!("failed to create watcher: {}", e));
            *job.completed_at.lock().unwrap() = Some(std::time::Instant::now());
            return;
        }
    };

    if let Err(e) = watcher.watch(&watch_path, RecursiveMode::NonRecursive) {
        *job.status.lock().unwrap() =
            IngestStatus::Errored(format!("failed to watch directory: {}", e));
        *job.completed_at.lock().unwrap() = Some(std::time::Instant::now());
        return;
    }

    eprintln!(
        "watch_dir {}: watching {} for new .jsonl files",
        job.name,
        watch_path.display()
    );

    // Event loop
    loop {
        if job.cancel.load(Ordering::Relaxed) {
            break;
        }

        match rx.recv_timeout(std::time::Duration::from_millis(500)) {
            Ok(Ok(event)) => {
                // Filter to Create and Modify(Name) events only
                let interesting = matches!(
                    event.kind,
                    EventKind::Create(_)
                        | EventKind::Modify(notify::event::ModifyKind::Name(_))
                );

                if !interesting {
                    continue;
                }

                for path in event.paths {
                    if job.cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    if path.is_file() && is_jsonl_file(&path) {
                        process_and_move(&path, &job, registry, shard_count, &processed_dir);
                    }
                }
            }
            Ok(Err(e)) => {
                eprintln!("watch_dir {}: watcher error: {}", job.name, e);
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                // Normal — check cancel flag and loop
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                // Watcher dropped or channel closed — exit
                eprintln!("watch_dir {}: watcher disconnected, stopping", job.name);
                break;
            }
        }
    }

    *job.status.lock().unwrap() = IngestStatus::Cancelled;
    *job.completed_at.lock().unwrap() = Some(std::time::Instant::now());
    eprintln!(
        "watch_dir {}: stopped ({} processed, {} failed)",
        job.name,
        job.records_processed.load(Ordering::Relaxed),
        job.records_failed.load(Ordering::Relaxed),
    );
}

/// Spawn a background thread that calls `run_watch_dir`.
///
/// Mirrors `ingest::start_file_ingest`; the thread is named
/// `watch-dir-{job.name}`.
pub fn start_watch_dir_ingest(
    job: Arc<crate::ingest::IngestJob>,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) {
    let name = format!("watch-dir-{}", job.name);
    std::thread::Builder::new()
        .name(name)
        .spawn(move || run_watch_dir(job, registry, shard_count))
        .expect("failed to spawn watch-dir ingest thread");
}

// ============================================================
// Tests
// ============================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicBool, AtomicU64};

    // ---- is_jsonl_file ----

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
        assert!(!is_jsonl_file(Path::new(".jsonl")));
    }

    // ---- move_to_processed ----

    #[test]
    fn move_to_processed_basic() {
        let dir = tempfile::tempdir().unwrap();
        let processed = dir.path().join("processed");
        std::fs::create_dir_all(&processed).unwrap();

        let src = dir.path().join("events.jsonl");
        std::fs::write(&src, b"data").unwrap();

        let dest = move_to_processed(&src, &processed).unwrap();

        assert!(dest.exists(), "destination file should exist");
        assert!(!src.exists(), "source file should be gone");
        assert_eq!(dest, processed.join("events.jsonl"));
    }

    #[test]
    fn move_to_processed_duplicate_gets_timestamp() {
        let dir = tempfile::tempdir().unwrap();
        let processed = dir.path().join("processed");
        std::fs::create_dir_all(&processed).unwrap();

        // Pre-create the same name in processed/
        let pre_existing = processed.join("events.jsonl");
        std::fs::write(&pre_existing, b"old").unwrap();

        let src = dir.path().join("events.jsonl");
        std::fs::write(&src, b"new").unwrap();

        let dest = move_to_processed(&src, &processed).unwrap();

        assert!(dest.exists(), "destination file should exist");
        assert!(!src.exists(), "source file should be gone");
        // The new dest must have a different name (timestamp appended)
        assert_ne!(dest, pre_existing, "should not overwrite existing file");
        // Both files should exist in processed/
        assert!(pre_existing.exists(), "original processed file still there");
        // New file name must end with .jsonl
        assert_eq!(dest.extension().and_then(|e| e.to_str()), Some("jsonl"));
    }

    // ---- scan_existing_files ----

    #[test]
    fn scan_finds_jsonl_only() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.jsonl"), b"").unwrap();
        std::fs::write(dir.path().join("b.jsonl"), b"").unwrap();
        std::fs::write(dir.path().join("c.tmp"), b"").unwrap();
        std::fs::write(dir.path().join("d.csv"), b"").unwrap();
        std::fs::create_dir(dir.path().join("processed")).unwrap();

        let files = scan_existing_files(dir.path());
        assert_eq!(files.len(), 2, "should find exactly 2 jsonl files");
        // Sorted order
        assert!(files[0].file_name().unwrap() == "a.jsonl");
        assert!(files[1].file_name().unwrap() == "b.jsonl");
    }

    #[test]
    fn scan_empty_dir() {
        let dir = tempfile::tempdir().unwrap();
        let files = scan_existing_files(dir.path());
        assert!(files.is_empty());
    }

    // ---- ingest_single_file ----

    fn make_registry() -> ChannelRegistry {
        ChannelRegistry::new(4, 256)
    }

    fn valid_line(node_id: &str) -> String {
        format!(
            r#"{{"type":"set_prop","node_id":"{}","key":"k","value":1}}"#,
            node_id
        )
    }

    #[test]
    fn ingest_single_file_processes_lines() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("data.jsonl");

        let mut f = std::fs::File::create(&file).unwrap();
        writeln!(f, "{}", valid_line("alice")).unwrap();
        writeln!(f, "{}", valid_line("bob")).unwrap();

        let registry = make_registry();
        let cancel = AtomicBool::new(false);
        let processed = AtomicU64::new(0);
        let failed = AtomicU64::new(0);

        let result = ingest_single_file(&file, &registry, 4, &cancel, &processed, &failed);

        assert_eq!(result.unwrap(), true);
        assert_eq!(processed.load(Ordering::Relaxed), 2);
        assert_eq!(failed.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn ingest_single_file_counts_bad_lines() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("data.jsonl");

        let mut f = std::fs::File::create(&file).unwrap();
        writeln!(f, "{}", valid_line("alice")).unwrap();
        writeln!(f, "{}", valid_line("bob")).unwrap();
        writeln!(f, "this is not json").unwrap();

        let registry = make_registry();
        let cancel = AtomicBool::new(false);
        let processed = AtomicU64::new(0);
        let failed = AtomicU64::new(0);

        let result = ingest_single_file(&file, &registry, 4, &cancel, &processed, &failed);

        assert_eq!(result.unwrap(), true);
        assert_eq!(processed.load(Ordering::Relaxed), 2);
        assert_eq!(failed.load(Ordering::Relaxed), 1);
    }

    // ---- process_and_move integration test ----

    #[test]
    fn process_and_move_full_flow() {
        use crate::ingest::{IngestJob, IngestSource, IngestStatus};
        use std::sync::Mutex;
        use std::time::Instant;

        let dir = tempfile::tempdir().unwrap();
        let watch_path = dir.path().to_path_buf();
        let processed_dir = watch_path.join("processed");
        std::fs::create_dir_all(&processed_dir).unwrap();

        // Create a .jsonl file with one valid record
        let file = watch_path.join("events.jsonl");
        let mut f = std::fs::File::create(&file).unwrap();
        writeln!(f, "{}", valid_line("charlie")).unwrap();
        drop(f);

        // Build a minimal IngestJob with WatchDir source
        let job = Arc::new(IngestJob {
            name: "test-watch".into(),
            source: IngestSource::WatchDir {
                path: watch_path.clone(),
            },
            status: Mutex::new(IngestStatus::Running),
            records_processed: AtomicU64::new(0),
            records_failed: AtomicU64::new(0),
            cancel: Arc::new(AtomicBool::new(false)),
            started_at: Instant::now(),
            completed_at: Mutex::new(None),
        });

        let registry = make_registry();

        // Call process_and_move directly
        process_and_move(&file, &job, &registry, 4, &processed_dir);

        // One record processed, none failed
        assert_eq!(job.records_processed.load(Ordering::Relaxed), 1);
        assert_eq!(job.records_failed.load(Ordering::Relaxed), 0);

        // Source file should have moved to processed/
        assert!(!file.exists(), "source file should be gone");
        assert!(
            processed_dir.join("events.jsonl").exists(),
            "processed/ should contain the moved file"
        );
    }
}
