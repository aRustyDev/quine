# ADR-007: Minimal scope (journals + snapshots + metadata) for Phase 2

**Status:** Accepted

**Date:** 2026-04-11

## Context

Scala Quine's `NamespacedPersistenceAgent` exposes seven data categories:
node change journals, domain index events, snapshots, standing query
definitions, standing query states, metadata, and domain graph nodes.
Phase 1 of the Roc port only built `NodeChangeEvent` and `NodeSnapshot`
and their transitive types — standing queries, domain graph nodes, and
the types behind `DomainIndexEvent` don't exist yet in the Roc codebase.

Three options for Phase 2 scope:

- **A. Minimal** — Only journals (NodeChangeEvent) and snapshots (NodeSnapshot). Two of the seven Scala categories.
- **B. Minimal + metadata** — Add an opaque-bytes metadata store (`Dict Str (List U8)`). Metadata doesn't require any new types.
- **C. Full interface surface with stubs** — Define all seven categories in the interface but have the five non-implementable ones return `Err NotImplemented`.

## Decision

Use **Option B: minimal + metadata**.

Phase 2's `PersistenceAgent` exposes three data categories:

1. **Node change event journals** — persist batches of events, retrieve by `(QuineId, time range)`, delete by `QuineId`
2. **Node snapshots** — persist snapshot, retrieve latest up to time, delete by `QuineId`
3. **Metadata** — opaque `Dict Str (List U8)` for small key-value data (version tracking, persistence format info)

The other four Scala categories (domain index events, standing query definitions, standing query states, domain graph nodes) are **deferred** to the phase that introduces their source types: Phase 4 for standing queries, and whenever domain graph nodes land.

## Consequences

- **Faster Phase 2**: fewer data categories = less surface area to test and validate.
- **Metadata is free**: it needs no Phase 1 types, just bytes. Gives the persistence layer a real use case beyond nodes (version tracking) from day one.
- **No placeholder stubs**: the interface never exposes "not yet implemented" operations — every method actually does something real.
- **Phase 4 will extend the interface**: standing queries will add ~4 new operations (persist definition, get definitions, persist state, get state). This is additive and doesn't invalidate Phase 2 work.

## Watch For

If Phase 4 extends the `PersistenceAgent` record significantly, consider
whether to split it into multiple smaller interfaces (`NodePersistor`,
`StandingQueryPersistor`, `MetadataPersistor`) rather than one growing
record. The decision can wait until we see how Phase 4 actually shapes up.
