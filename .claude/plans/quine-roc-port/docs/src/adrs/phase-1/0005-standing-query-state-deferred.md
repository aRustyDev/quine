# ADR-005: DomainIndexEvent and standing query state deferred

**Status:** Accepted

**Date:** 2026-04-10

## Context

The Scala `NodeEvent` hierarchy includes `DomainIndexEvent` — events that track
standing query subscription bookkeeping (subscribe, unsubscribe, propagate
results). Similarly, `NodeSnapshot` in Scala includes `subscribersToThisNode`
and `domainNodeIndex` fields that track standing query state.

Phase 1 focuses purely on the data model (properties, edges, mutation events).
Standing queries are Phase 4.

## Decision

Phase 1's `NodeChangeEvent` only includes data mutation variants:
`PropertySet`, `PropertyRemoved`, `EdgeAdded`, `EdgeRemoved`. Phase 1's
`NodeSnapshot` and `NodeState` only include `properties` and `edges` (plus
`time` on the snapshot).

## Consequences

- The Phase 1 types are simpler and faster to implement
- Phase 4 will need to extend `NodeChangeEvent` (or introduce a separate
  `NodeEvent` super-type) and add fields to `NodeSnapshot` and `NodeState`
- The extension must be backward-compatible with persistence formats from
  Phase 2 — careful design needed there

## Watch For

When Phase 4 begins, decide whether to expand the existing `NodeChangeEvent`
union or introduce a parent `NodeEvent` type that contains both
`NodeChangeEvent` and `DomainIndexEvent`. The Scala original used the latter.
