# ADR-002: model depends on id directly (not parametric)

**Status:** Accepted

**Date:** 2026-04-10

## Context

`QuineValue` includes an `Id QuineId` variant — values can reference node
identities. This creates a real type-level dependency: `model` needs to know
what a `QuineId` is.

Two options:
- **A:** `model` directly imports `id`, `QuineValue.Id` holds a concrete `QuineId`
- **B:** `QuineValue` becomes generic over the ID type: `QuineValue idType`

## Decision

Use option A. `QuineValue` directly references `QuineId` from the `id` package.

## Consequences

- Simpler types throughout the codebase (no type parameter to thread)
- `id` and `model` are always coupled at the type level
- Cannot have multiple ID schemes coexisting in the same graph

## Watch For

If we ever need multiple ID providers active simultaneously (e.g., a graph with
both UUID-keyed and integer-keyed nodes), refactor `QuineValue.Id` to be
parametric. Until then, the simplicity wins.
