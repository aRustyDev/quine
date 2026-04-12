# ADR-013: Opaque `Persistor` handle with module-based state-threading interface

**Status:** Accepted (supersedes ADR-009)

**Date:** 2026-04-11

## Context

ADR-009 chose a record-of-functions interface for `PersistenceAgent`,
modeled after Phase 1's `QuineIdProvider`. Subsequent research into Roc's
state management primitives (see `research/results/roc-state-management.md`)
revealed that approach is incompatible with current Roc:

- **Roc has no mutable state primitive.** No `Ref`, `IORef`, `MVar`, or
  mutable fields. `Task` is deprecated; purity is inferred from `!` in
  function names and `=>` in type signatures.
- **Long-lived in-process state is handled via tail-recursive state
  threading.** Roc's refcount-driven in-place mutation turns `Dict.insert`
  into real mutation at refcount 1, giving mutable-dict performance with
  a pure-functional API.
- **Host-held state is the path to richer semantics (including future
  distribution).** The canonical example is `ostcar/kingfisher`, whose
  custom Go host owns the mutable state and uses `sync.RWMutex`. Roc code
  stays pure; mutation lives in the host. basic-cli and basic-webserver
  do NOT expose anything like this today.

The record-of-functions pattern implicitly assumes closures over mutable
state, which Roc does not support. That's what ADR-009 missed.

Three approaches were re-evaluated with this knowledge:

- **A.** Keep record-of-functions (ADR-009 as written)
- **B.** Module-based interface with opaque `Persistor` handle
- **C.** Record parameterized over state type (`PersistenceAgent state`)

## Decision

Use **Option B**: module-based interface with an opaque `Persistor` handle.

### The shape

`InMemoryPersistor.roc` exposes an opaque type and top-level functions:

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

new : Config -> Persistor

append_events :
    Persistor, QuineId, List TimestampedEvent
    -> Result Persistor [DuplicateEventTime EventTime, SerializeError Str, Unavailable, Timeout]

get_latest_snapshot :
    Persistor, QuineId, EventTime
    -> Result NodeSnapshot [NotFound, DeserializeError Str, Unavailable, Timeout]

# ... etc for the other 10 operations
```

### Key design properties

1. **Opaque type** — callers never see the internal `{ events, snapshots, metadata }` record shape. The `Persistor` type hides all state representation.
2. **State threading** — every mutating operation returns a new `Persistor`. Callers thread it through their logic. Roc's refcount-1 optimization makes this fast.
3. **QuineId as explicit shard key** — every operation takes `QuineId` as the first data argument. This makes the API distribution-ready: a future implementation can route operations to different backing stores based on `QuineId` hash without changing the signature.
4. **Forward-looking error variants** — error sets include `Unavailable`, `Timeout`, and (for some operations) `NotLeader`. Phase 2 never produces these, but they're documented so callers handle them from day one. When distribution lands, no signature change is required.
5. **Effectful operations kept pure for now** — the operations use `->` not `=>`. A future host-held-state implementation would need to change to `=>`, which is a breaking change. This is accepted: pure operations work today with basic-cli, and the migration to effectful signatures will be mechanical once we have a custom host.

## Consequences

- **No runtime polymorphism for Phase 2.** Callers hard-code `InMemoryPersistor` by import. When a second backend lands (Phase 2.5 or later), we'll add a polymorphic wrapper layer or revisit with whatever Roc ability improvements are available at that time.
- **Decorators still work at the module level.** A `BloomFilter` module can hold an inner `Persistor` and re-expose the same operations, delegating to the inner one. No language feature required.
- **State is first-class and traceable.** `Persistor` values can be stored in records, passed to functions, returned from `new` — everything that the record-of-functions approach promised is preserved via the opaque handle.
- **Testing is straightforward.** Construct a `Persistor` with `new`, apply operations, assert on the result — no mocking layer needed.
- **The Phase 1 `QuineIdProvider` record-of-functions pattern is NOT retroactively wrong.** It works for *stateless* abstractions (a provider is a bundle of pure functions with no per-instance state). Records of functions are the right tool for that case; the persistor is a different case.

## Migration path to distribution

When the user's long-term goal of "distributed across Raspberry Pis" becomes
concrete, the migration is:

1. **Build a custom Roc platform** (likely Zig or Rust host) that exposes
   a mutable state handle, modeled after `ostcar/kingfisher`.
2. **Replace the `Persistor` module body** — keep the same opaque type and
   same function signatures, but change the implementation to call into
   the custom platform's host-held state.
3. **Change operation signatures from `->` to `=>`** — this is the only
   breaking change. Every call site needs to add `!` (purity inference).
4. **Callers don't see the shape change** — they still pass a `Persistor`
   around, still call `append_events(p, qid, events)`. The opaque type
   absorbs the implementation change.
5. **Network-ish error variants are already there** — `Unavailable`,
   `Timeout` start actually firing, and callers were forced to handle
   them from day one so nothing breaks.

## Rejected: Keep ADR-009 (record-of-functions)

Incompatible with Roc's state model. See the ADR-009 update for details.

## Rejected: Record parameterized over state type

```roc
PersistenceAgent state : {
    append_events : state, QuineId, List TimestampedEvent -> Result state _,
    ...
}
```

Workable but awkward. Every caller has to handle the type parameter.
Decorators become parameterized over `state`, which cascades through
the codebase. The opaque-handle approach (B) gives equivalent safety
with less type-level machinery.

## Watch For

- If a second persistor backend lands and we need runtime polymorphism,
  revisit: either add a polymorphic wrapper layer or look at Roc's
  evolving ability system.
- If callers start wanting to store many `Persistor` values (e.g., per
  namespace) and operate on them uniformly, that's the signal for the
  wrapper layer.
- If `Persistor` accumulates fields beyond a handful and becomes
  monolithic, consider splitting into multiple opaque handles
  (`NodePersistor`, `MetadataPersistor`) exposed from the same module.

## Related

- ADR-009 (superseded predecessor)
- ADR-010 (nested Dict storage layout — still valid, this ADR adopts it)
- ADR-011 (error types — still valid, this ADR uses hybrid public/private approach)
- ADR-012 (append-vs-put naming — still valid, this ADR adopts the convention)
- FR 001 (Roc abilities exploration) — may offer future polymorphism path
- `research/results/roc-state-management.md` — the research that prompted this revision
