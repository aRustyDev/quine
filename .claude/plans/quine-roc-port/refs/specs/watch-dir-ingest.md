# Watch-Directory Ingest

**Issue**: qr-qc0  
**Date**: 2026-04-23  
**Status**: Approved

## Summary

A `--ingest watch-dir /path/to/dir` CLI flag starts a background thread that
watches a directory for new `.jsonl` files, ingests each through the existing
`process_line` pipeline, then moves the file to a `processed/` subdirectory.

Targets edge deployments (RPi CM5 cluster) where files land via rsync/scp.

## Design

### New Types

`IngestSource::WatchDir { path: PathBuf }` — extends the existing enum in
`ingest.rs`.

### Watch Loop (`run_watch_dir`)

Located in `ingest.rs` (or a new `watch_dir.rs` if ingest.rs gets too large).

1. Create `<watch_dir>/processed/` if it doesn't exist. Fail fast on error.
2. Scan for existing `.jsonl` files (catches files that landed before startup).
   Ingest each, then move to `processed/`.
3. Start a `notify` watcher on the directory for create/rename events.
4. On event: filter for `.jsonl` extension only. Ignore `.tmp`, `.partial`,
   and everything else.
5. Open file, read lines via `BufReader`, call `process_line()` for each.
6. Update `IngestJob` counters (`records_processed`, `records_failed`).
7. Move file to `processed/foo.jsonl`. If that path already exists, append a
   timestamp suffix (`processed/foo.1745398800.jsonl`).
8. Loop until `cancel` AtomicBool is set (shutdown integration).

### Partial File Contract

Producers must write files atomically: write to a `.tmp` or `.partial` name,
then rename to `.jsonl` when complete. The watcher only picks up `.jsonl`
files, so half-written files are never ingested.

### CLI Integration

In `main.rs`, parse `--ingest watch-dir /path/to/dir`:

```
--ingest watch-dir /data/incoming
```

Creates an `IngestJob` with `source: WatchDir { path }`, registers it in
`ingest_jobs`, and spawns the watcher thread. Same pattern as `--ingest stdin`.

### Error Handling

| Scenario | Behavior |
|----------|----------|
| Malformed JSONL line | `process_line` logs + increments `records_failed` |
| File open/read error | Log, increment `records_failed`, skip file (don't move) |
| `processed/` mkdir fails | Fatal at startup |
| notify watcher error | Log and continue |
| Duplicate in `processed/` | Append unix timestamp suffix |

### Dependencies

`notify = "7"` — cross-platform filesystem event library. Works on
Linux (inotify), macOS (FSEvents), Windows (ReadDirectoryChanges).

### No Roc Changes

Entirely Rust-side. Reuses the existing `process_line` function and
`IngestJob` lifecycle.

## Tests

1. Scan existing `.jsonl` files from a tempdir, verify they get ingested
2. Ignore non-`.jsonl` files (`.tmp`, `.csv`)
3. Move file to `processed/` after successful ingest
4. Handle duplicate filename in `processed/` with timestamp suffix
5. Cancel flag stops the watcher loop
