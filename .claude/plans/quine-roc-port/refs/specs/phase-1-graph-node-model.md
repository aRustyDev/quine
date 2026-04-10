# Phase 1: Graph Node Model — Design Specification

## Purpose

Port the foundational types of Quine's graph node model from Scala to Roc. These types form the atom of the entire system — every later phase (persistence, standing queries, query languages, ingest, API) depends on them. Phase 1 delivers a tested, idiomatic Roc type foundation plus the core `apply_event` function that validates the type design works.

## Goals

- Define all core node model types as idiomatic Roc tagged unions and records
- Cover every type with inline `expect` tests
- Implement `apply_event` as the one behavioral function that proves the types compose correctly
- Establish the project structure that subsequent phases will build on
- Document architectural decisions in ADRs for later reference

## Non-Goals

- No persistence, serialization formats, or storage backends (Phase 2)
- No concurrency, actor model, or sleep/wake lifecycle (Phase 3)
- No standing queries or `DomainIndexEvent` (Phase 4)
- No query languages, parsers, or query execution (Phase 5)
- No ingest pipelines or external sources (Phase 6)
- No HTTP API or application shell (Phase 7)
- No temporal types in `QuineValue` (deferred until Cypher temporal functions are needed)
- No performance benchmarking or optimization
- No standing query subscription state in `NodeState` or `NodeSnapshot`

## Source Reference

- Analysis document: `docs/src/core/graph/node/README.md`
- Scala source: `quine-core/src/main/scala/com/thatdot/quine/model/` and `quine-core/src/main/scala/com/thatdot/quine/graph/`

## Project Structure

```
quine-roc/
├── packages/
│   ├── README.md                   # All packages overview, dependency diagram
│   └── core/
│       ├── README.md               # Core packages overview, links to docs/src/core/
│       ├── id/
│       │   ├── README.md
│       │   ├── main.roc
│       │   ├── QuineId.roc
│       │   ├── QuineIdProvider.roc
│       │   └── EventTime.roc
│       └── model/
│           ├── README.md
│           ├── main.roc
│           ├── QuineValue.roc
│           ├── PropertyValue.roc
│           ├── HalfEdge.roc
│           ├── EdgeDirection.roc
│           ├── NodeEvent.roc
│           ├── NodeSnapshot.roc
│           └── NodeState.roc
├── app/
│   └── main.roc                    # Integration smoke test app
├── docs/                           # Existing mdbook
└── ...
```

The `core/` directory is organizational. `packages/core/id/` and `packages/core/model/` are two independent Roc packages, with `model` declaring `id` as a dependency in its package header. The `app/main.roc` file is a thin app that imports both packages and serves as an integration smoke test entry point.

## Type Definitions

### Identity Layer (`packages/core/id/`)

#### `QuineId.roc`

```roc
QuineId := List U8 implements [Eq, Hash, Inspect]
```

Opaque wrapper around a byte list. Public functions:
- `from_bytes : List U8 -> QuineId`
- `to_bytes : QuineId -> List U8`
- `from_hex_str : Str -> Result QuineId [InvalidHex]`
- `to_hex_str : QuineId -> Str`
- `empty : QuineId`

#### `EventTime.roc`

```roc
EventTime := U64 implements [Eq, Ord, Inspect]
```

Bit-packed timestamp: top 42 bits = milliseconds since epoch, middle 14 bits = message sequence, bottom 8 bits = event sequence. Public functions:
- `from_parts : { millis : U64, message_seq : U16, event_seq : U8 } -> EventTime`
- `millis : EventTime -> U64`
- `message_seq : EventTime -> U16`
- `event_seq : EventTime -> U8`
- `min_value : EventTime`
- `max_value : EventTime`
- `advance_event : EventTime -> EventTime`

#### `QuineIdProvider.roc`

```roc
QuineIdProvider : {
    new_id : {} -> QuineId,
    from_bytes : List U8 -> Result QuineId [InvalidId Str],
    to_bytes : QuineId -> List U8,
    from_str : Str -> Result QuineId [InvalidId Str],
    to_str : QuineId -> Str,
    hashed_id : List U8 -> QuineId,
}
```

Record-of-functions (manual vtable). Phase 1 ships one concrete provider: `uuid_provider` that generates UUID-based IDs.

### Data Layer (`packages/core/model/`)

#### `EdgeDirection.roc`

```roc
EdgeDirection : [Outgoing, Incoming, Undirected]
```

With `reverse : EdgeDirection -> EdgeDirection` (Outgoing↔Incoming, Undirected→Undirected).

#### `HalfEdge.roc`

```roc
HalfEdge : { edge_type : Str, direction : EdgeDirection, other : QuineId }
```

With `reflect : HalfEdge, QuineId -> HalfEdge` that produces the reciprocal half-edge for the other endpoint (used to maintain the half-edge invariant: an edge exists iff both endpoints hold reciprocal half-edges).

#### `QuineValue.roc`

```roc
QuineValue : [
    Str Str,
    Integer I64,
    Floating F64,
    True,
    False,
    Null,
    Bytes (List U8),
    List (List QuineValue),
    Map (Dict Str QuineValue),
    Id QuineId,
]

QuineType : [
    StrType,
    IntegerType,
    FloatingType,
    TrueType,
    FalseType,
    NullType,
    BytesType,
    ListType,
    MapType,
    IdType,
]
```

10 variants covering essential data. Temporal types deferred (see ADR-004). With `quine_type : QuineValue -> QuineType` for type tag access without unwrapping.

#### `PropertyValue.roc`

```roc
PropertyValue : [
    Deserialized QuineValue,
    Serialized (List U8),
    Both { bytes : List U8, value : QuineValue },
]
```

Models lazy serialization as a tagged union with three states. Pure transition functions:
- `from_value : QuineValue -> PropertyValue` (creates `Deserialized`)
- `from_bytes : List U8 -> Result PropertyValue [InvalidBytes]` (creates `Serialized`)
- `get_value : PropertyValue -> Result QuineValue [DeserializeError]` (returns the value, deserializing if needed)
- `get_bytes : PropertyValue -> List U8` (returns the bytes, serializing if needed)

Phase 1 does not implement real serialization formats. The serialization/deserialization functions are placeholder implementations: `get_bytes` on a `Deserialized` variant returns an empty list and updates state to `Both` with that empty bytes; `get_value` on a `Serialized` variant returns `Err DeserializeError`. This validates the state transitions and API shape without committing to a wire format. Real serialization (MessagePack or similar) lands in Phase 2.

#### `NodeEvent.roc`

```roc
NodeChangeEvent : [
    PropertySet { key : Str, value : PropertyValue },
    PropertyRemoved { key : Str, previous_value : PropertyValue },
    EdgeAdded HalfEdge,
    EdgeRemoved HalfEdge,
]

TimestampedEvent : { event : NodeChangeEvent, at_time : EventTime }
```

`DomainIndexEvent` is deferred to Phase 4 (see ADR-005).

#### `NodeSnapshot.roc`

```roc
NodeSnapshot : {
    properties : Dict Str PropertyValue,
    edges : Set HalfEdge,
    time : EventTime,
}
```

Standing query subscription state fields are deferred to Phase 4 (see ADR-005).

#### `NodeState.roc`

```roc
NodeState : {
    properties : Dict Str PropertyValue,
    edges : Set HalfEdge,
}

apply_event : NodeState, NodeChangeEvent -> NodeState
from_snapshot : NodeSnapshot -> NodeState
to_snapshot : NodeState, EventTime -> NodeSnapshot
```

`apply_event` pattern-matches on the event type and returns the updated state. Pure function. This is the core behavior of what a node *does*.

## Testing Strategy

- **Inline tests:** Every module file has `expect` blocks at the bottom covering its public API.
- **Coverage targets per type:**
  - Identity types: construction, round-trip serialization, ordering, edge cases (empty, max values)
  - Value types: each variant constructible, type tag correct, equality
  - Edge types: reflect produces valid reciprocal, direction reverse is involutive
  - Event/state: each event applies correctly, idempotent operations are idempotent (e.g., adding the same edge twice), removing-then-adding works, snapshot round-trip preserves state
- **Integration smoke test:** `app/main.roc` exercises the full type stack — creates a node state, applies several events, takes a snapshot, restores from snapshot, verifies equality. Run with `roc test app/main.roc`.

## Documentation

### Per-package READMEs
Each `README.md` (at `packages/`, `packages/core/`, `packages/core/id/`, `packages/core/model/`) explains:
- **Purpose** — what this package contains and why
- **Public API** — the types and their main functions
- **Dependencies** — what it depends on, what depends on it
- **Scala counterpart** — links to the Scala source files this corresponds to
- **Analysis link** — links to `docs/src/core/graph/node/`

### ADRs
Stored in `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/`. Six ADRs for Phase 1:

1. **ADR-001:** Two-package split (id, model) instead of one
2. **ADR-002:** model depends on id directly (not parametric over ID type)
3. **ADR-003:** PropertyValue lazy serialization preserved as tagged union (not optimized in Phase 1)
4. **ADR-004:** Temporal types deferred from QuineValue
5. **ADR-005:** DomainIndexEvent and standing query state deferred to Phase 4
6. **ADR-006:** apply_event included in Phase 1 as the type-validation function

ADRs use the standard format: Status, Context, Decision, Consequences.

## Build Order

1. Project scaffolding (package directories, README skeletons, ADR directory)
2. `id/QuineId.roc` + tests
3. `id/EventTime.roc` + tests
4. `id/QuineIdProvider.roc` + tests (with one UUID-based provider)
5. `id/main.roc` package header
6. `model/EdgeDirection.roc` + tests
7. `model/HalfEdge.roc` + tests
8. `model/QuineValue.roc` + tests
9. `model/PropertyValue.roc` + tests
10. `model/NodeEvent.roc` + tests
11. `model/NodeSnapshot.roc` + tests
12. `model/NodeState.roc` + tests (apply_event)
13. `model/main.roc` package header
14. `app/main.roc` integration smoke test
15. READMEs and ADRs finalized

## Acceptance Criteria

Phase 1 is complete when:
- [ ] All 9 type modules compile cleanly (`roc check` passes for each package)
- [ ] All inline `expect` tests pass (`roc test` on each package)
- [ ] The integration smoke test in `app/main.roc` passes
- [ ] Each package and module has a README explaining purpose and API
- [ ] All 6 ADRs are written and committed
- [ ] `apply_event` correctly handles every `NodeChangeEvent` variant
- [ ] `NodeSnapshot` round-trip preserves state (snapshot → state → snapshot is identity)
- [ ] `HalfEdge.reflect` produces a valid reciprocal that satisfies the half-edge invariant

## Watch-For Items (Future Refactor Triggers)

These are noted now so future phases can recognize when refactoring is justified:

- **Type parameterization for QuineValue/QuineId:** If multiple ID providers ship simultaneously and need to coexist, consider refactoring `QuineValue.Id` to be parametric over the ID type. (See ADR-002.)
- **PropertyValue performance:** Benchmark in Phase 2 to determine if lazy serialization is worth the complexity in Roc, or if eager values are simpler and fast enough. (See ADR-003.)
- **Temporal types:** Add back to QuineValue when Cypher temporal functions are needed in Phase 5. (See ADR-004.)
