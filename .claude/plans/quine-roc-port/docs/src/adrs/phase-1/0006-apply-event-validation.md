# ADR-006: apply_event included in Phase 1 as the type-validation function

**Status:** Accepted

**Date:** 2026-04-10

## Context

Phase 1 is primarily a type-definition phase — no concurrency, no IO, no
persistence. But pure type definitions in isolation are easy to get wrong: the
real test is whether they compose into actual behavior.

The Scala `AbstractNodeActor.processNodeEvent` method is the central point
where `NodeChangeEvent`s mutate node state. This logic is pure (no actor
mechanics, no IO) and can be ported as a standalone function.

## Decision

Include one behavioral function in Phase 1: `apply_event : NodeState,
NodeChangeEvent -> NodeState`. This pure function pattern-matches on the event
type and returns the updated state. Plus snapshot round-trip helpers
(`to_snapshot`, `from_snapshot`).

## Consequences

- Phase 1 ships with a working "apply event to node" capability — small but real
- The type design gets validated by actually being used
- Idempotency invariants (e.g., re-adding the same edge is a no-op) get tested
- Phase 3 (graph structure) can build on this without redesigning the mutation API

## Watch For

If `apply_event` grows beyond a simple pattern-match (e.g., needs to dispatch
to subsystems, emit derived events, or interact with standing queries), revisit
the boundary. Phase 4 will likely need a richer version.
