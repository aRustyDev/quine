# Quine-Roc Persistor

Persistence backends for the Quine-Roc port. Each subdirectory is an
independent Roc package implementing (or contributing to) the persistor
interface.

## Layout

- `common/` — Shared types used by all backends (error variants)
- `memory/` — In-memory backend. No durability; used for tests,
  development, and small graphs. Depends on `common` and `core/{id,model}`.

Future backends will land as siblings (e.g., `rocksdb/`, `cassandra/`).

## Interface

The public API of each backend module is an opaque `Persistor` type and
twelve operations covering append-only journals, snapshots, and metadata.
See ADR-013 for the interface design and ADR-012 for the operation naming
convention (append vs put vs get vs delete).

## Status

Phase 2 of the [Quine-to-Roc port](../../.claude/plans/quine-roc-port/README.md).
See the [Phase 2 spec](../../.claude/plans/quine-roc-port/refs/specs/phase-2-persistence.md).
