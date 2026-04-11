# ADR-009: Record-of-functions interface for PersistenceAgent

**Status:** Accepted

**Date:** 2026-04-11

## Context

Scala Quine's `PersistenceAgent` is a trait with ~24 methods. Roc doesn't
have traits in the same form. Three approaches were evaluated:

- **A. Record of functions** — `PersistenceAgent` is a Roc record type where each field is an operation. Concrete implementations construct a record value. Same pattern as `QuineIdProvider` from Phase 1.
- **B. Module-based interface** — Each persistor module exposes top-level functions (`InMemoryPersistor.persist_snapshot : State, QuineId, NodeSnapshot -> Result State Err`). Callers import the specific module. No unified type.
- **C. Ability-based** — Define a Roc ability `PersistenceAgent implements persist_snapshot : a, ...`. Concrete implementations implement the ability.

## Decision

Use **Option A: record of functions**.

`PersistenceAgent` is a Roc record type:

```roc
PersistenceAgent : {
    persist_snapshot : QuineId, NodeSnapshot -> Result {} [...],
    get_latest_snapshot : QuineId -> Result NodeSnapshot [NotFound, ...],
    persist_events : QuineId, List TimestampedEvent -> Result {} [...],
    get_events : QuineId, EventTime, EventTime -> Result (List TimestampedEvent) [...],
    delete_node : QuineId -> Result {} [...],
    set_metadata : Str, List U8 -> Result {} [...],
    get_metadata : Str -> Result (List U8) [NotFound, ...],
    ...
}
```

Concrete implementations like `InMemoryPersistor.new : Config -> PersistenceAgent`
construct and return a record. Callers hold and pass `PersistenceAgent` values.

## Consequences

- **First-class persistor values**: can be stored in a list, passed to a function, swapped at runtime via config.
- **Decorator chains are trivial**: `BloomFilter.new : PersistenceAgent -> PersistenceAgent`. Scala's `ExceptionWrappingPersistenceAgent` / `BloomFilteredPersistor` / `PartitionedPersistor` patterns all translate cleanly.
- **Runtime swap works**: `if config.useRocksDB then RocksDb.new(cfg) else InMemory.new(cfg)` — both sides return the same record type.
- **Mocking for tests is trivial**: construct an ad-hoc record with stub functions.
- **Boilerplate cost**: every concrete persistor needs a `new` function that explicitly wires up every method. No inheritance or default impls.
- **Each implementation holds its own state in a closure or explicit state parameter**: functions in the record must close over the persistor's internal state, since records don't have associated methods with implicit self.

## Rejected: Module-based (B)

Module-based appears simpler but collapses into A as soon as runtime
polymorphism is needed. Every real persistence system needs "in-memory for
tests, real backend for prod" — that choice can't be made at compile time.
A wrapper layer that dispatches between modules duplicates the API, which
is exactly Option A in disguise.

## Rejected: Ability-based (C)

Abilities are type constraints, not first-class values. Decorator chains,
storing persistors in a list, holding a persistor in a config struct —
all are awkward or impossible. Additionally, Roc's ability system is
pre-1.0 and custom abilities beyond stdlib (Eq, Hash) are less battle-tested.

A separate investigation (FR 001) will explore whether abilities could
work for this interface after the maturity improves, as a potential
upstream contribution opportunity.

## Watch For

- If record construction becomes unwieldy (e.g., 40+ fields), consider splitting into smaller sub-interfaces grouped by concern (NodePersistor, MetadataPersistor, StandingQueryPersistor).
- If a Roc ability system feature lands that supports first-class ability-instances, revisit the decision.
- Related: FR 001 (Roc abilities exploration) is the post-Phase-2 experiment.
