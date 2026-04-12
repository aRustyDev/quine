# persistor/memory

In-memory `Persistor` backend for the Quine-Roc port.

## Purpose

- Test backend for Phase 3+ code (standing queries, query languages, etc.)
- Reference implementation for the `Persistor` interface shape
- Development backend for small graphs or short-lived processes
- NOT production storage — data is lost when the process exits

## Modules

- `Persistor` — Opaque `Persistor` type with 12 operations: append_events,
  get_events, put_snapshot, get_latest_snapshot, put_metadata, get_metadata,
  get_all_metadata, delete_events_for_node, delete_snapshots_for_node,
  delete_metadata, empty_of_quine_data, shutdown.

## Dependencies

- `common` — for error types
- `core/id` — for `QuineId`, `EventTime`
- `core/model` — for `NodeSnapshot`, `TimestampedEvent`, `PropertyValue`

## Scala Counterpart

- `quine-core/src/main/scala/com/thatdot/quine/persistor/InMemoryPersistor.scala`

## Analysis

See [`docs/src/core/persistence/README.md`](../../../.claude/plans/quine-roc-port/docs/src/core/persistence/README.md).
