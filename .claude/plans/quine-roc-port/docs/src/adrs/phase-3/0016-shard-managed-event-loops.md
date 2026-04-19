# ADR-016: Shard-Managed Event Loops vs Per-Node Tasks

**Status:** Accepted
**Date:** 2026-04-19
**Context:** Phase 3 must choose how nodes are modeled as concurrent entities.
Four options were evaluated during brainstorming; two survived platform selection.

## Options Evaluated

### Option A: Shard-Managed Event Loops (chosen)

Each shard is a host thread running a Roc event loop. The shard owns ALL node
state as a single `Dict QuineId NodeEntry`. Messages arrive on the shard's
channel; the shard dispatches each one by calling a pure Roc function
`(NodeState, Message) -> (NodeState, List Effect)` and updating the Dict.

### Option B: Per-Node Tasks with Channels

Each awake node is a host-managed lightweight task (tokio task) with its own
channel. The shard is a coordinator that routes messages to node channels.

## Comparison

| Aspect                     | A: Shard Event Loop        | B: Per-Node Tasks          |
|----------------------------|---------------------------|---------------------------|
| Concurrency granularity    | Per-shard (4-8 threads)   | **Per-node (50k+ tasks)** |
| Head-of-line blocking      | Yes (slow node blocks shard) | **No**                 |
| Refcount-1 optimization    | **Preserved** (shard owns Dict) | Fragmented           |
| Testing                    | **Deterministic** (pure functions) | Non-deterministic   |
| Roc ABI compatibility      | **Proven** (N entry points) | Unproven (50k+ calls) |
| Host complexity            | **Simple** (recv-dispatch loop) | Complex (task lifecycle) |
| Sleep/wake model           | **Natural** (Dict insert/remove) | Task spawn/cancel     |

## Decision

Option A — shard-managed event loops.

## Rationale

1. Roc's calling convention has no proven support for 50k+ concurrent entry
   points. No existing platform manages more than one concurrent Roc call.
2. Refcount-1 in-place mutation — Roc's key performance optimization — is
   preserved when the shard owns the Dict exclusively.
3. Dispatch is a pure function, enabling deterministic property-based testing.
4. Head-of-line blocking is mitigable: persistence I/O is offloaded to the
   host, and computation-heavy queries (Cypher) don't arrive until Phase 5.

## Conditions for Revisiting

- Phase 5 profiling shows head-of-line blocking from Cypher queries degrades
  ingest throughput unacceptably
- Roc gains proven support for N concurrent platform calls (N > 10k)
- The custom platform evolves to support coroutine-style node suspension
