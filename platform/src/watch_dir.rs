// platform/src/watch_dir.rs
//
// Pure helper functions for watch-directory ingest.
// Filesystem watching logic (notify integration) lives here; the hot loop
// that ties watching to the ingest pipeline will be added in a later task.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use crate::channels::ChannelRegistry;
use crate::ingest::{self, LineOutcome};

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
}
