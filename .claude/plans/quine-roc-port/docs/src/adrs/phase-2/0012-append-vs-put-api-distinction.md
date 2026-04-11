# ADR-012: Append vs Put naming and error-type distinction in PersistenceAgent

**Status:** Accepted

**Date:** 2026-04-11

## Context

The `PersistenceAgent` interface from ADR-009 has three categories of
writable data: event journals (append-only by design), snapshots
(replaceable-at-key), and metadata (replaceable-at-key). The first
proposal used uniform `persist_*` naming for all writes, relying on
documentation to communicate append-only semantics for journals.

This is fragile — event immutability is a load-bearing invariant for
event sourcing. If it silently breaks, historical queries return wrong
results, standing query re-fires are incorrect, and snapshot replay
produces corrupted state. "Don't do that" enforcement is not enough.

Three options for enforcing the distinction:

- **A. No structural distinction** — Uniform `persist_*` naming. Documentation only.
- **B. Naming + error type at API level** — `append_events` returns `[DuplicateEventTime EventTime, ...]` in its error set; `put_snapshot` documents overwrite semantics through the name alone.
- **C. Opaque store types** — Define `Journal`, `Snapshots`, `Metadata` as distinct opaque types with only the operations each permits. The type system makes overwrites of append-only data unrepresentable.

## Decision

Use **Option B** for Phase 2:

- `append_events` — rejects duplicates, returns `Err (DuplicateEventTime t)` on conflict
- `put_snapshot` — overwrites at key (replace-at-key semantics)
- `put_metadata` — overwrites at key
- `get_*` — reads
- `delete_*` — removes

### Naming convention

| Prefix | Semantics | Applies to |
|---|---|---|
| `append_*` | Rejects duplicates at the same key. Event-sourced data only. | Journal events |
| `put_*` | Last-write-wins replacement at the key. | Snapshots, metadata |
| `get_*` | Read operation, returns `Err NotFound` if missing. | All data categories |
| `delete_*` | Remove operation, no-op if missing. | All data categories |

### Updated PersistenceAgent record (supersedes ADR-009's example)

```roc
PersistenceAgent : {
    # APPEND operations — rejects duplicates
    append_events : QuineId, List TimestampedEvent -> Result {} [DuplicateEventTime EventTime, SerializeError Str],

    # PUT operations — overwrite at key
    put_snapshot : QuineId, NodeSnapshot -> Result {} [SerializeError Str],
    put_metadata : Str, List U8 -> Result {} [],

    # GET operations
    get_events : QuineId, { start : EventTime, end : EventTime } -> Result (List TimestampedEvent) [DeserializeError Str],
    get_latest_snapshot : QuineId, EventTime -> Result NodeSnapshot [NotFound, DeserializeError Str],
    get_metadata : Str -> Result (List U8) [NotFound],
    get_all_metadata : {} -> Result (Dict Str (List U8)) [],

    # DELETE operations
    delete_events_for_node : QuineId -> Result {} [],
    delete_snapshots_for_node : QuineId -> Result {} [],
    delete_metadata : Str -> Result {} [],

    # LIFECYCLE
    empty_of_quine_data : {} -> Result Bool [],
    shutdown : {} -> Result {} [],
}
```

## Consequences

- **Callers must handle `DuplicateEventTime` for `append_events`** — the type system forces it. This catches caller bugs where event-time generation is faulty or a race condition produces duplicates.
- **Clear intent at call site**: `append_events` and `put_snapshot` communicate semantics through naming alone, no need to check documentation.
- **Minimal refactor cost**: moving from option A was a rename + one error tag addition.
- **Implementation-level bugs are still possible**: a broken `append_events` implementation could silently overwrite without returning the error. The contract is documented and type-checked at the boundary but not structurally enforced within the implementation.

## Deferred: Option C (opaque store types)

Option C would introduce `Journal`, `Snapshots`, and `Metadata` as distinct
opaque types, where the `Journal` type structurally cannot be overwritten
because no `overwrite` function exists on it. This is the maximally safe
option.

**Deferred to a future refactor** when any of these signals appear (see
memory `project_watch_for_opaque_stores.md`):

1. Implementation bug where `append_events` silently overwrites
2. Event sourcing invariants break in production
3. Second/third persistor implementation landing, increasing risk surface
4. Contributions from new developers accidentally overwriting events

The refactor path from B to C is additive: the public `PersistenceAgent`
record stays the same, the implementation internally replaces raw
`Dict`s with opaque `Journal`/`Snapshots`/`Metadata` stores. Callers
don't need to change.

## Rejected: Option A (no distinction)

Option A was the initial proposal but leaves the immutability invariant
in the "don't do that" zone — enforced only by documentation and
reviewer attention. That's exactly how load-bearing invariants get
broken over time, especially once multiple contributors are involved.
For an event-sourced system where the invariant is load-bearing for
correctness, this is not acceptable.

## Related

- ADR-009 (record-of-functions interface) — this ADR supersedes the example code in ADR-009 with the new naming convention
- ADR-011 (error types, hybrid open unions) — this ADR is a concrete application of the hybrid approach: public `append_events` has an explicit `DuplicateEventTime` error tag
- Memory: `project_watch_for_opaque_stores.md` — tracks signals for upgrading to Option C
