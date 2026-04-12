# ADR-009: Record-of-functions interface for PersistenceAgent

**Status:** Superseded by ADR-013

**Date:** 2026-04-11

**Superseded on:** 2026-04-11 (same day, during ongoing Phase 2 brainstorming)

## Why superseded

Research into Roc's state-management primitives revealed that the
record-of-functions approach — while idiomatic for stateless abstractions
like `QuineIdProvider` — does not fit the persistence layer's needs.
The core issue: **Roc has no mutable state primitive**. The
record-of-functions pattern implicitly assumes you can close over mutable
state, which cannot be done in pure Roc without inventing a custom host.

See ADR-013 for the full analysis and the replacement decision
(module-based interface with opaque `Persistor` handle).

The original context, alternatives, and reasoning of this ADR are
preserved below for historical continuity.

---

## Original Context (preserved)

Scala Quine's `PersistenceAgent` is a trait with ~24 methods. Roc doesn't
have traits in the same form. Three approaches were evaluated:

- **A. Record of functions** — `PersistenceAgent` is a Roc record type where each field is an operation. Concrete implementations construct a record value. Same pattern as `QuineIdProvider` from Phase 1.
- **B. Module-based interface** — Each persistor module exposes top-level functions (`InMemoryPersistor.persist_snapshot : State, QuineId, NodeSnapshot -> Result State Err`). Callers import the specific module. No unified type.
- **C. Ability-based** — Define a Roc ability `PersistenceAgent implements persist_snapshot : a, ...`. Concrete implementations implement the ability.

## Original Decision (superseded)

Use **Option A: record of functions**.

`PersistenceAgent` was a Roc record type. Concrete implementations like
`InMemoryPersistor.new : Config -> PersistenceAgent` would construct and
return a record. Callers would hold and pass `PersistenceAgent` values.

## Why the original decision didn't work

1. **Roc has no mutable state.** A record of functions requires each function
   to close over the persistor's internal state. Since the state is
   mutable at the semantic level (each call produces a new version of
   the dicts), the closure would have to hold an immutable snapshot. That
   means every operation would have to return a new `PersistenceAgent`
   record with new closures pointing at the new state — which defeats
   the purpose of using a record as a "handle" and adds complexity with
   no benefit.

2. **Refcount-driven in-place mutation doesn't help.** Roc's optimization
   that turns `Dict.insert` into in-place mutation at refcount 1 works
   for state-threaded values, not for values captured in long-lived
   closures.

3. **The "distribution story" under Option A is unclear.** To make
   operations effectful (`=>`) for future distribution, the record
   would need some way for each function to run as an effect. There's
   no clean path from "record of pure functions" to "record of Task
   operations" in current Roc.

## Replaced By

- **ADR-013** — Module-based interface with opaque `Persistor` handle and state-threading operations. First-class values are preserved via the opaque handle; polymorphism is deferred until a second backend lands.

## Related

- ADR-013 (replacement decision)
- FR 001 (Roc abilities exploration) — may offer a third path after Roc's ability system matures
