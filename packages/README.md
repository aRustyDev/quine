# Quine-Roc Packages

Roc packages for the Quine-to-Roc port. Each subdirectory of `core/` is an independent Roc package.

## Layout

- `core/id/` — Identity types: `QuineId`, `EventTime`, `QuineIdProvider`
- `core/model/` — Data types: `QuineValue`, `PropertyValue`, `HalfEdge`, `NodeEvent`, `NodeSnapshot`, `NodeState`. Depends on `core/id`.

## Status

Phase 1 of the [Quine-to-Roc port](../.claude/plans/quine-roc-port/README.md). See [Phase 1 spec](../.claude/plans/quine-roc-port/refs/specs/phase-1-graph-node-model.md).
