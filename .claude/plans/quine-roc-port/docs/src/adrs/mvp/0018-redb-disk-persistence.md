# ADR-018: redb for Disk Persistence

**Status:** Accepted
**Date:** 2026-04-22
**Context:** The prototype stores node snapshots in an in-memory HashMap.
MVP requires data to survive restarts. Need an embedded key-value store
that runs on Raspberry Pi CM5 (arm64) and cross-compiles without a C++
toolchain.

**Related:** MVP spec `refs/specs/mvp-single-host.md` (M1), research
issue qr-u60 (shard DB isolation topology).

## Decision

**redb** (v2, pure Rust embedded KV store) over sled and RocksDB.

## Options Evaluated

### A) RocksDB (via rust-rocksdb)

Battle-tested, used by Quine Scala as one backend. Excellent read/write
performance at scale. However:

- Requires C++ compilation (librocksdb). Cross-compiling to arm64 needs a
  full C++ cross-toolchain, adding build complexity for the RPi target.
- ~5MB binary size addition.
- Heavy dependency tree.

### B) redb (chosen)

Pure Rust embedded KV store. MVCC concurrency (multiple readers, single
writer). ACID transactions with WAL-based crash recovery.

- Zero native dependencies. `cargo build --target aarch64-unknown-linux-gnu`
  just works.
- ~200KB binary size addition.
- Actively maintained (author cberner, regular releases, stable v2 API).
- Power-loss safe (fsync on commit) — critical for RPi edge nodes.

### C) sled

Pure Rust, lock-free B+ tree with epoch-based reclamation. Slightly faster
random point reads (~10-20% over redb in benchmarks).

- **Effectively unmaintained.** Author (spacejam) stepped back ~2023. No 1.0
  release. Still 0.34.x with known data loss bugs in earlier versions.
- Lock-free write path causes write amplification under sustained load (the
  primary workload for high-throughput ingest).
- Richer API (watch_prefix, merge operators, built-in zstd compression) but
  the maintenance risk and durability concerns are disqualifying.

## Rationale

The deciding factors, in order:

1. **Maintenance and durability.** The persistence layer is foundational.
   Building on an unmaintained library with known corruption history (sled)
   is unacceptable. redb has ACID guarantees and an active maintainer.

2. **Cross-compilation.** The RPi CM5 deployment target rules out C++
   dependencies unless absolutely necessary. redb compiles everywhere Rust
   does. RocksDB requires a cross-toolchain.

3. **Write performance.** High-throughput ingest means sustained writes.
   redb's WAL-based write path has predictable latency. sled's lock-free
   merge process causes latency spikes under sustained write load.

## Consequences

- Single writer per database. If multiple shards need concurrent writes,
  either use separate redb files per shard or serialize writes through the
  existing persistence pool thread. Research issue qr-u60 evaluates this.
- No built-in compression. If snapshot sizes become a concern, pre-compress
  values before storage. Research issue qr-d7w evaluates this.
- No watch/subscribe mechanism. Cross-shard signaling continues to use
  crossbeam channels. Research issue qr-6eu evaluates whether a separate
  watch mechanism is needed.
