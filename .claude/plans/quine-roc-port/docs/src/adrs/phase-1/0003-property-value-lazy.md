# ADR-003: PropertyValue lazy serialization preserved as tagged union

**Status:** Accepted

**Date:** 2026-04-10

## Context

The Scala `PropertyValue` uses a lazy serialization optimization: it can hold
either a deserialized `QuineValue` or serialized bytes (or both), and defers
the conversion until needed. This optimization matters in Scala because nodes
often hold many properties that are never read during a query.

In Roc, immutable values are cheap to pass around, and the cost-benefit may
differ. We had two options:

- **A:** Preserve the three-state tagged union model
- **B:** Make `PropertyValue` always-eager — just hold a `QuineValue`, serialize on demand

## Decision

Preserve the lazy model in Phase 1, but with stub serialization functions. The
type is `[Deserialized QuineValue, Serialized (List U8), Both { bytes, value }]`.
Real serialization is deferred to Phase 2.

## Consequences

- API shape mirrors the Scala original
- Phase 2 can plug in real serialization (likely MessagePack) without changing
  callers
- Some unnecessary complexity in Phase 1 — every consumer must pattern-match
  on three states

## Watch For

In Phase 2, benchmark the lazy model against the always-eager alternative. If
eager is fast enough and simpler, simplify the type. Roc's value semantics may
make the optimization unnecessary.
