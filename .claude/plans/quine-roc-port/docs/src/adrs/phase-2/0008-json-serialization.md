# ADR-008: JSON serialization for Phase 2 persistence

**Status:** Accepted

**Date:** 2026-04-11

## Context

Phase 1 stubbed `PropertyValue.get_bytes` and `get_value` because no real
serialization was needed at that layer. Phase 2 needs to actually turn
`NodeSnapshot`, `NodeChangeEvent`, and other types into bytes and back for
the persistence layer.

Scala Quine uses **FlatBuffers + custom packing** — a schema-driven binary
format with compression. That's extremely efficient but requires a schema
compiler and non-trivial tooling work to port to Roc.

Four alternatives considered:

- **A. MessagePack** — Binary, compact, tagged format. Roc has no MessagePack library; we'd build one. Closest to "equivalent to FlatBuffers" for our needs.
- **B. JSON** — Dead simple, human-readable, easy to debug. Roc may have community JSON support. Much larger on disk than binary.
- **C. Custom binary format** — Hand-rolled: per-variant tag bytes, length-prefixed variable data. Maximum control, minimum dependencies.
- **D. Defer entirely** — In-memory persistor stores live objects in a `Dict`, no bytes produced/consumed. Honest but doesn't validate the `BinaryFormat` abstraction.

## Decision

Use **Option B: JSON** for Phase 2.

The `PersistenceAgent` round-trips values through JSON bytes for storage,
even though the in-memory persistor could theoretically skip serialization
entirely. We explicitly serialize and deserialize to validate the codec
shape and catch bugs in the type-to-bytes-to-type pipeline.

## Consequences

- **Correctness focus**: JSON's failure modes are well-understood and easy to debug. Test failures produce readable diffs.
- **Deferred optimization**: We are explicitly choosing "correct and slow" over "fast and complex" for Phase 2. Binary formats come later.
- **Validates BinaryFormat abstraction**: every persist/retrieve cycle goes through real bytes, so the interface works for any future format without changes.
- **Disk size is not a concern**: Phase 2 only has an in-memory persistor, so the JSON byte arrays never actually touch disk. Disk-size cost only matters when we add real backends (Phase 2.5 or later).
- **Roc JSON library unknown today**: We'll need to either find a community JSON package or write a minimal encoder/decoder ourselves. Writing it ourselves is likely simpler for the small value types we need.

## Watch For

- Benchmark Phase 2 once it works. If JSON round-tripping is a significant bottleneck even for tests, promote binary format work earlier.
- When real backends land (RocksDB FFI, file-based, etc.), revisit the format choice. MessagePack or a custom binary format is likely the right call for any on-disk store.
- If a Roc MessagePack library exists and is mature enough, consider using it instead — the Quine-wide advantage is that `PropertyValue`'s original Scala serialization used MessagePack, so this would match.
