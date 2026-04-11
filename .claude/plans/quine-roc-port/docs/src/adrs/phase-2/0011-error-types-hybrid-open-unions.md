# ADR-011: Error types — open tag unions with explicit public boundary

**Status:** Accepted

**Date:** 2026-04-11

## Context

Roc's open tag unions (`[Foo, Bar]_`) support compile-time inference of
precise error sets per operation. Three approaches to error typing were
evaluated:

- **A. One shared error type** — `PersistenceError : [NotFound, SerializeError, BackendError, ...]`. Every operation returns `Result x PersistenceError`. One type defined once.
- **B. Per-operation precise types** — Each operation declares its exact error set as an explicit closed union.
- **C. Open tag unions with `_`** — Every operation returns `Result x _` and the compiler infers the concrete set from usage.

## Decision

Use a **hybrid approach**:

- **Private / internal functions:** Wildcard `_` (Option C). Implementation details use inferred open unions so adding an error variant doesn't require touching type signatures throughout the module.
- **Public API boundary** (`PersistenceAgent` record fields): **Explicit** closed tag unions. Every field in the `PersistenceAgent` record has a concrete, documented error set.

Example:

```roc
# PUBLIC: explicit in the PersistenceAgent record
PersistenceAgent : {
    get_latest_snapshot : QuineId -> Result NodeSnapshot [NotFound, DeserializeError Str],
    persist_snapshot : QuineId, NodeSnapshot -> Result {} [SerializeError Str, BackendFull],
    ...
}

# PRIVATE: open inference inside the implementation
encode_snapshot : NodeSnapshot -> Result (List U8) _
encode_snapshot = |snap|
    # compiler infers whatever errors arise internally
    ...
```

## Consequences

- **Callers see stable contracts**: Quine's users (Phase 3+) know exactly which errors each public persistence operation can produce. Documentation matches reality because the type is the documentation.
- **Internal flexibility**: adding a new error case inside the persistor doesn't require updating type signatures throughout the module — the compiler tracks it via inference.
- **Refactoring safety**: changing a private helper's error set propagates automatically. Only the public boundary's signatures need to be intentionally maintained.
- **Documentation generation gap**: extracting a centralized "all possible persistence errors" document requires either manually maintaining it or building a simple script that parses the `PersistenceAgent` record definition and extracts the error tags from each field signature. This is feasible because the public signatures are explicit.
- **Trade-off accepted**: the compiler won't enforce a cross-operation invariant like "all operations may return BackendDown" — if we want that, we manually include it in each public signature.

## Related

- FR 003 (Roc type info export) investigates whether upstream Roc could emit machine-readable type info to automate the error-doc generation. Non-blocking for Phase 2 — a small ast-grep script can extract errors from the public signatures as a fallback.

## Why Not Option A (shared union)

A works but fights Roc's design. Every operation would either carry error
variants it cannot produce (forcing callers to handle cases that never
happen) or force coupling callers to the complete error taxonomy even when
they only care about one operation.

## Why Not Pure Option C (wildcard everywhere)

Pure wildcards on the public API mean callers have no stable contract —
an implementation change could silently broaden the error set and break
existing call sites (in the sense of surfacing new unhandled cases). For
a library boundary, explicit is more maintainable.

## Watch For

- If the public signatures grow more than a handful of distinct errors per operation, consider introducing named type aliases (`SnapshotReadError : [NotFound, DeserializeError Str]`) for readability.
- When Phase 3 and Phase 4 consumers start using the persistence API, measure whether the explicit-public constraint causes friction (e.g., forces lots of exhaustive pattern matches that could be simpler with wildcards). If so, consider loosening.
