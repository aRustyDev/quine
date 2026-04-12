# Phase 2: Persistence Interfaces — Design Specification

## Purpose

Port the minimal persistence layer from Quine to Roc: an opaque `Persistor`
type with twelve operations covering journals, snapshots, and metadata. Ship
one backend (in-memory) that round-trips data through JSON serialization.

Phase 2 is about **the persistence interface shape and a working reference
implementation**, not performance or production-grade storage. Real backends
(RocksDB FFI, Cassandra) land in Phase 2.5 or later.

## Goals

- Define an opaque `Persistor` handle with 12 operations covering three data
  categories (journals, snapshots, metadata)
- Enforce event immutability through API design (append vs put distinction)
- Ship an in-memory backend (`packages/persistor/memory/`) that passes unit,
  component, and integration tests
- Validate the JSON serialization codec (via `roc-json` or a documented
  fallback) against all Phase 1 types
- Document all design decisions in ADRs during brainstorming, not after
  implementation
- Keep the API distribution-friendly for future multi-node deployment

## Non-Goals

- No RocksDB, Cassandra, or any file/disk-based backend (future phases)
- No actor-per-node concurrency (Phase 3)
- No standing query persistence state (Phase 4)
- No domain graph node persistence (deferred indefinitely unless needed)
- No binary serialization formats (Phase 2.5 or later — JSON is the Phase 2
  format by design)
- No network I/O or distribution (future phases)
- No benchmarking or performance optimization

## Source References

- Analysis: `docs/src/core/persistence/README.md`
- Phase 1 types: `packages/core/id/`, `packages/core/model/`
- Scala source: `quine-core/src/main/scala/com/thatdot/quine/persistor/`,
  `quine-rocksdb-persistor/`, `quine-mapdb-persistor/`, `quine-cassandra-persistor/`

## Dependencies

- **Phase 1 complete** — all Phase 1 types (`QuineId`, `EventTime`,
  `NodeChangeEvent`, `NodeSnapshot`, etc.) must be landed
- **Roc nightly with working Dict/tagged union JSON encoding** — verified
  via the smoke test (see Build Order Task 1b)
- **JSON library** — `lukewilliamboswell/roc-json` preferred; fallback
  cascade documented in ADR-015

## Project Structure

```
quine-roc/
├── packages/
│   ├── core/           # Phase 1 (unchanged)
│   │   ├── id/
│   │   └── model/
│   └── persistor/      # NEW in Phase 2
│       ├── README.md
│       ├── common/
│       │   ├── README.md
│       │   ├── main.roc            # package [PersistorError] { id, model }
│       │   └── PersistorError.roc  # Shared error variants
│       └── memory/
│           ├── README.md
│           ├── main.roc            # package [Persistor] { common, id, model }
│           └── Persistor.roc       # Opaque Persistor + 12 operations
├── app/
│   ├── main.roc                    # Phase 1 smoke test (unchanged)
│   ├── json-smoke.roc              # NEW: roc-json compatibility test
│   └── phase-2-smoke.roc           # NEW: Phase 2 integration smoke test
├── docs/                           # Existing mdbook
└── ...
```

Sub-packages under `packages/persistor/` mirror Phase 1's `packages/core/`
pattern. Future backends land as siblings under `packages/persistor/`
(e.g., `rocksdb/`, `cassandra/`).

## The Persistor Interface

`packages/persistor/memory/Persistor.roc` exposes the opaque type and
twelve operations. The public API surface:

```roc
module [
    Persistor,
    new,
    append_events,
    get_events,
    put_snapshot,
    get_latest_snapshot,
    put_metadata,
    get_metadata,
    get_all_metadata,
    delete_events_for_node,
    delete_snapshots_for_node,
    delete_metadata,
    empty_of_quine_data,
    shutdown,
]

Persistor := {
    events : Dict QuineId (Dict U64 (List TimestampedEvent)),
    snapshots : Dict QuineId (Dict U64 NodeSnapshot),
    metadata : Dict Str (List U8),
}

Config : {}  # No configuration options for Phase 2 in-memory

new : Config -> Persistor

# APPEND — rejects duplicates
append_events :
    Persistor, QuineId, List TimestampedEvent
    -> Result Persistor [DuplicateEventTime EventTime, SerializeError Str, Unavailable, Timeout]

# PUT — overwrite at key
put_snapshot :
    Persistor, QuineId, NodeSnapshot
    -> Result Persistor [SerializeError Str, Unavailable, Timeout]

put_metadata :
    Persistor, Str, List U8
    -> Result Persistor [Unavailable, Timeout]

# GET
get_events :
    Persistor, QuineId, { start : EventTime, end : EventTime }
    -> Result (List TimestampedEvent) [DeserializeError Str, Unavailable, Timeout]

get_latest_snapshot :
    Persistor, QuineId, EventTime
    -> Result NodeSnapshot [NotFound, DeserializeError Str, Unavailable, Timeout]

get_metadata :
    Persistor, Str
    -> Result (List U8) [NotFound, Unavailable, Timeout]

get_all_metadata :
    Persistor
    -> Result (Dict Str (List U8)) [Unavailable, Timeout]

# DELETE
delete_events_for_node :
    Persistor, QuineId
    -> Result Persistor [Unavailable, Timeout]

delete_snapshots_for_node :
    Persistor, QuineId
    -> Result Persistor [Unavailable, Timeout]

delete_metadata :
    Persistor, Str
    -> Result Persistor [Unavailable, Timeout]

# LIFECYCLE
empty_of_quine_data :
    Persistor
    -> Result Bool [Unavailable, Timeout]

shutdown :
    Persistor
    -> Result {} [Unavailable, Timeout]
```

**Notes:**
- The `Persistor` type is opaque — callers never see the internal dict structure
- Operations returning `Persistor` thread state (caller receives the new version)
- `Unavailable` and `Timeout` appear in every error set even though the
  in-memory backend never produces them, so callers are prepared when a future
  backend does
- `Config` is empty for Phase 2; it's a placeholder that future backends
  (RocksDB, Cassandra) will populate with backend-specific options

## Storage Layout

Internal state is three nested/flat dicts (never exposed):

```roc
{
    events : Dict QuineId (Dict EventTime (List TimestampedEvent)),
    snapshots : Dict QuineId (Dict EventTime NodeSnapshot),
    metadata : Dict Str (List U8),
}
```

- Events and snapshots use nested dicts (QuineId outer, EventTime inner) for
  O(1) "all data for node X" access
- Metadata uses a flat string-keyed dict — simpler, no per-key versioning

### Phase 1 prerequisite: add Hash ability

Phase 1's `QuineId` and `EventTime` opaque types currently only implement
`Eq`. Roc's `Dict` requires both `Eq` and `Hash` on its key type. Phase 2
implementation begins with a small modification to Phase 1:

```roc
# packages/core/id/QuineId.roc
QuineId := List U8 implements [Eq { is_eq: is_eq }, Hash]

# packages/core/id/EventTime.roc
EventTime := U64 implements [Eq { is_eq: is_eq }, Hash]
```

The `Hash` ability can be auto-derived because the underlying types
(`List U8` and `U64`) both implement `Hash` in Roc's stdlib. This is
Task 0 in the Phase 2 build order (before scaffolding).

If auto-derivation fails for any reason (e.g., Roc's opaque type
derivation doesn't transparently pass through), the fallback is to
implement `Hash` manually using an explicit `hash : hasher, QuineId ->
hasher` function, same pattern as the existing `is_eq`.

## Serialization

All persisted values (events, snapshots, metadata values) round-trip through
JSON bytes using `lukewilliamboswell/roc-json`. ADR-015 documents the
cascading fallback strategy if roc-json is broken against our Roc nightly:

1. Smoke test roc-json against all Phase 1 types (Task 1b)
2. If it works, use it directly
3. If roc-json itself is broken, fork and patch
4. If the Roc compiler is broken, patch our local Roc fork at `~/code/oss/roc`
5. Last resort: roll our own JSON encoder (~200-300 lines)

For Phase 2, the in-memory backend **does still serialize** values through
bytes (and deserialize on read) even though it could skip ser/de entirely.
This validates the codec and catches bugs in the serialization pipeline
before they become persistence bugs in Phase 2.5+ backends.

## Error Types

- **Public signatures use explicit error tag unions** (per ADR-011):
  callers see stable, documented error sets
- **Internal helper functions use wildcard `_`** (per ADR-011): implementation
  details benefit from Roc's type inference without polluting the public API
- **`DuplicateEventTime`** is returned from `append_events` when an event
  at the same `(QuineId, EventTime)` already exists (per ADR-012):
  structurally enforces event immutability
- **Forward-looking network variants** (`Unavailable`, `Timeout`) appear in
  every public signature even though Phase 2 never produces them: callers are
  forced to handle them so future distributed backends can slot in without
  changing the API

## Testing Strategy

### Unit tests

At the bottom of `Persistor.roc` using inline `expect` blocks. One test per
operation covering:
- Basic success path (call the operation, verify state changed as expected)
- Edge cases (empty input, operation on non-existent key, etc.)
- Error conditions that are intrinsic to the in-memory backend

### Component tests

In a dedicated `packages/persistor/memory/PersistorTest.roc` module (not
exported from the package header, not consumed by other packages). Tests
exercise the Persistor API through multi-step scenarios:

- "Insert 100 events for a node, retrieve a time range, verify correct subset"
- "Append an event with an already-existing EventTime, verify error"
- "Put snapshot at time T1, put another at T2, get_latest at time between → verify T1"
- "Put snapshot at T1, then at T1 again → verify overwrite (not append)"
- "Put three metadata keys, delete one, verify the other two still exist"
- "Add events and snapshots for node A, delete node A's events, verify
  snapshots unaffected"
- "empty_of_quine_data returns true on fresh persistor, false after any
  insert, true again after deleting everything"

### Integration smoke test

`app/phase-2-smoke.roc` uses both Phase 1 types and Phase 2 persistor in a
realistic flow:

```
1. Create an empty persistor
2. Create a node and apply several events (build up NodeState)
3. Persist each event to the journal via append_events
4. Take a NodeSnapshot and put it via put_snapshot
5. "Crash" — discard the in-memory NodeState
6. Retrieve the latest snapshot via get_latest_snapshot
7. Retrieve journal events after the snapshot time via get_events
8. Replay events on top of snapshot to reconstruct NodeState
9. Verify reconstructed state matches pre-crash state
10. Print "Phase 2 smoke test PASSED"
```

This is the end-to-end validation that Phase 2 correctly implements the
event-sourcing model.

## Documentation

### Per-package READMEs
- `packages/persistor/README.md` — overview of the persistor concept and
  where backends live
- `packages/persistor/common/README.md` — shared types, future backends
  will depend on this
- `packages/persistor/memory/README.md` — in-memory backend, intended use
  cases (testing, small graphs, development)

### ADRs (nine new)
Stored in `.claude/plans/quine-roc-port/docs/src/adrs/phase-2/`:

- **ADR-007** — Minimal scope (journals + snapshots + metadata)
- **ADR-008** — JSON serialization (deferring binary optimization)
- **ADR-009** — Record-of-functions interface *(superseded by ADR-013)*
- **ADR-010** — Nested Dict storage layout
- **ADR-011** — Hybrid error typing (explicit public, inferred private)
- **ADR-012** — Append-vs-put API distinction
- **ADR-013** — Opaque Persistor handle + module-based interface
- **ADR-014** — Persistor package layout (sub-packages from day one)
- **ADR-015** — JSON package dependency strategy (roc-json with fallback cascade)

## Build Order

0. **Add Hash ability to Phase 1 opaque types** — modify
   `packages/core/id/QuineId.roc` and `packages/core/id/EventTime.roc` to
   add `Hash` via auto-derivation (`implements [Eq { is_eq: is_eq }, Hash]`).
   Verify Phase 1 tests still pass. Needed because Roc's `Dict` requires
   `Hash` on key types. If auto-derivation fails, implement `Hash`
   manually with the same pattern as the existing `is_eq`.
1. **Project scaffolding** — create directories, skeleton READMEs for both
   sub-packages, `packages/persistor/README.md`
2. **roc-json smoke test** (`app/json-smoke.roc`) — verify roc-json works
   against current Roc nightly with all Phase 1 types; escalate per ADR-015
   if it doesn't
3. **`common/PersistorError.roc`** — define shared error variants (if any
   beyond what's inline in each operation's error set)
4. **`common/main.roc`** — package header
5. **`memory/Persistor.roc` — opaque type and `new`** — establish the
   module shape with the empty-persistor case, then build each operation
   incrementally with its unit tests
6. **Operation-by-operation** (12 steps):
   - `put_metadata`, `get_metadata`, `delete_metadata`, `get_all_metadata`
     (simplest — flat dict)
   - `append_events`, `get_events`, `delete_events_for_node` (nested dict)
   - `put_snapshot`, `get_latest_snapshot`, `delete_snapshots_for_node`
   - `empty_of_quine_data`, `shutdown`
7. **`memory/main.roc`** — package header
8. **`PersistorTest.roc`** — component tests (multi-step scenarios)
9. **`app/phase-2-smoke.roc`** — integration smoke test
10. **READMEs** — written as we go, finalized at end
11. **Commit/finalize** — verify all ADRs present, update ROADMAP

## Acceptance Criteria

Phase 2 is complete when:

- [ ] `packages/persistor/common/` and `packages/persistor/memory/` exist
  with all listed files
- [ ] `roc check` passes on both sub-packages
- [ ] `roc test` passes on both sub-packages (all unit and component tests green)
- [ ] `app/phase-2-smoke.roc` compiles and runs, prints "Phase 2 smoke test PASSED"
- [ ] `app/json-smoke.roc` compiles and runs (proving roc-json works for our types)
- [ ] `append_events` rejects duplicate `(QuineId, EventTime)` pairs with
  `DuplicateEventTime`
- [ ] Snapshot round-trip via serialize → bytes → deserialize produces an
  equal `NodeSnapshot`
- [ ] The integration smoke test's reconstructed `NodeState` matches the
  pre-"crash" state exactly
- [ ] All 9 Phase 2 ADRs exist and are committed
- [ ] Each package has a README explaining purpose, public API, and
  dependencies
- [ ] ROADMAP updated to mark Phase 2 complete
- [ ] Phase 1 test suite still passes (no regressions from Phase 2 changes)

## Watch-For Items (Future Refactor Triggers)

- **Move to Option C (opaque store types)** per the memory file
  `project_watch_for_opaque_stores.md` — signals include any bug where
  `append_events` silently overwrites, multiple concurrent backend
  implementations, or append-overwrite discipline failures.
- **Swap JSON for binary format (MessagePack or custom)** — when disk size
  or performance becomes a concern. Phase 2.5+ backends are the natural
  trigger.
- **Extend the PersistenceAgent interface** when Phase 4 introduces
  standing queries. Add operations for standing query state persistence
  (four new operations per the Scala analysis).
- **Add runtime polymorphism layer** when a second backend lands — either
  a wrapper module that dispatches or (if Roc abilities have matured) an
  ability-based interface per FR 001.
- **Performance audit of JSON serialization** — if Phase 2 tests reveal the
  serialize-on-write path is a hot spot, benchmark against the
  skip-serialization-on-in-memory alternative and decide whether codec
  validation is still worth the cost.
