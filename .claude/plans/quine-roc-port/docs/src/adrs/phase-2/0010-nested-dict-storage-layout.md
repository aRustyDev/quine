# ADR-010: Nested Dict storage layout for in-memory persistor

**Status:** Accepted

**Date:** 2026-04-11

## Context

Scala Quine's backends key journals and snapshots by `(QuineId, EventTime)`
composite keys. Roc's `Dict` requires `Eq` and `Hash` implementations on
keys, so we can't use arbitrary records as-is (though auto-derived `Hash`
would solve that).

Three layouts were evaluated for the in-memory persistor:

- **A. Nested Dicts** — `Dict QuineId (Dict U64 Value)`. Outer key is QuineId; inner key is EventTime-as-U64.
- **B. Opaque composite key** — Define `NodeTimeKey := { qid : QuineId, time : U64 }` with custom `Eq` and `Hash`. Single `Dict NodeTimeKey Value`.
- **C. Serialized composite key** — Pack QuineId bytes + EventTime into a `List U8`. `Dict (List U8) Value`.

## Decision

Use **Option A: Nested Dicts**.

The in-memory persistor holds events and snapshots in nested dicts:

```roc
State : {
    events : Dict QuineId (Dict U64 (List TimestampedEvent)),
    snapshots : Dict QuineId (Dict U64 NodeSnapshot),
    metadata : Dict Str (List U8),
}
```

where the inner `U64` is `EventTime` reinterpreted as its underlying U64.

## Consequences

- **Dominant access pattern is O(1) outer + inner scan**: "get all events/snapshots for node X" is the hottest operation (runs on every node wake-up). Nested layout makes it efficient — one outer lookup, then iterate the inner dict.
- **"Delete all for node X" is O(1)**: just `Dict.remove state.events qid`. Common during tests, node eviction, historical cleanup.
- **Range queries within a node are linear in that node's events**, not in the entire store. Scales with per-node history, not total history.
- **Slight complexity cost on inserts**: updating the nested structure requires get-update-put rather than a single `Dict.insert`. This is hidden behind helper functions.
- **Storage overhead**: each outer entry has a Dict's internal overhead (buckets, headers). For a graph with many nodes each holding few events, this is less compact than a flat composite-key dict. Acceptable for Phase 2 (in-memory, small scale).

## Rejected: Opaque composite key (B)

B would be faster for exact `(qid, time)` lookups, but the dominant access
pattern is "all events for node X" which requires O(total_events) scan
with a flat dict versus O(1) outer lookup with nested dicts. For a million
events across 10k nodes, waking one node would scan the entire store to
find its ~100 events — a 10,000x overhead on the hottest operation.

## Rejected: Serialized composite key (C)

C has the same scan problem as B, plus pays encoding/decoding overhead on
every operation, plus loses type safety. Worst of all worlds for our
access patterns.

## Watch For

- When real backends land (RocksDB FFI), the layout question re-opens — RocksDB's bytewise key ordering naturally supports composite keys, and `seekForPrev` on a flat keyspace is how Scala Quine implements `getLatestSnapshot` efficiently. Phase 2's nested-dict choice does NOT imply Phase 2.5+ backends must use nested storage.
- If an access pattern emerges that needs fast exact `(qid, time)` lookup (e.g., historical queries at specific timestamps), add a secondary flat index or revisit.
