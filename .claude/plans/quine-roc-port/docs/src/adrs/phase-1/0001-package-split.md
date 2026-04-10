# ADR-001: Two-package split (id, model)

**Status:** Accepted

**Date:** 2026-04-10

## Context

Phase 1 of the Quine-to-Roc port introduces foundational types from the Scala
quine-core module. We had three options for organizing them:

- **A:** Single package containing all types
- **B:** Two packages: id (identity) and model (data + events)
- **C:** Fine-grained per-type packages

## Decision

Use option B: two packages, `packages/core/id/` and `packages/core/model/`.

The `id` package contains pure identity types: QuineId, EventTime, QuineIdProvider.
The `model` package contains data types (QuineValue, PropertyValue), edge types
(HalfEdge, EdgeDirection), and event/state types (NodeEvent, NodeSnapshot, NodeState).

`model` declares `id` as a dependency in its package header.

## Consequences

- Mirrors the Scala reality where QuineId was an external library
- Forces a clean dependency direction (model depends on id, never the reverse)
- Adds some boilerplate (two main.roc headers, two READMEs)
- Splitting later (per-type packages) is easier than merging
- Future packages (persistence, standing queries) can depend on `id` without
  pulling in all of `model`

## Watch For

If `id` and `model` always evolve together and the boundary feels artificial,
consider merging into one package. Phase 2/3 work will reveal whether the split
pulls its weight.
