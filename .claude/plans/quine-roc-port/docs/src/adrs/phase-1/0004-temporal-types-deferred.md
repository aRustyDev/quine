# ADR-004: Temporal types deferred from QuineValue

**Status:** Accepted

**Date:** 2026-04-10

## Context

The Scala `QuineValue` includes 6 temporal variants: `DateTime`, `Duration`,
`Date`, `LocalTime`, `Time`, `LocalDateTime`. Roc's standard library does not
have a comprehensive datetime library, and Phase 1 needs to focus on the core
node model rather than building out a temporal type system.

## Decision

Defer all temporal types from Phase 1's `QuineValue`. The Phase 1 type has 10
variants instead of the Scala original's 16: `Str`, `Integer`, `Floating`,
`True`, `False`, `Null`, `Bytes`, `List`, `Map`, `Id`.

## Consequences

- Phase 1 cannot represent Cypher datetime literals
- Phase 5 (Cypher query language) is the natural place to add them, since
  that's where temporal functions like `datetime()` and `duration()` get used
- A migration step is required when temporal types are added: existing
  serialized data must remain readable

## Watch For

When Phase 5 begins, evaluate whether to write temporal types from scratch in
Roc, depend on a community time library, or use FFI to a C/Rust time library.
