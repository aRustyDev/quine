# persistor/common

Shared types used across persistor backends.

## Modules

- `PersistorError` — Forward-looking error variants including network-ish
  errors (`Unavailable`, `Timeout`) that appear in public signatures but
  are never produced by in-memory backends.

## Dependencies

- `core/id` — for `QuineId` and `EventTime` references in error variants
- `core/model` — for any model types referenced in errors

## Scala Counterpart

Scala Quine's persistor error types are scattered across
`quine-core/src/main/scala/com/thatdot/quine/persistor/`. This package
consolidates the subset relevant to Phase 2.

## Analysis

See [`docs/src/core/persistence/README.md`](../../../.claude/plans/quine-roc-port/docs/src/core/persistence/README.md).
