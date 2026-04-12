# Phase 3 Brainstorming Inputs — Graph Structure & Concurrency

**Status:** Notes for future brainstorming
**Filed:** 2026-04-11 (during Phase 2 brainstorming)
**Purpose:** Capture design concerns and options surfaced during earlier phases that must be addressed when Phase 3 brainstorming begins.

## Context

Phase 3 (Graph Structure & Concurrency) is the most architecturally critical
phase of the port. Decisions here ripple through standing queries (Phase 4),
query languages (Phase 5), ingest (Phase 6), and everything that follows.
The user's long-term goal is **native distribution** across low-resource
nodes (Raspberry Pis), which further constrains the design space.

This file collects concerns, options, and context that have surfaced during
earlier phases (0, 1, 2) that the Phase 3 brainstorming should explicitly
address. It is not a spec or a decision — it's a checklist of things the
brainstorming must not miss.

## Decisions That Must Be Made

### D1. Concurrency Model

Four candidates identified so far. See `docs/src/complexities/README.md`
Section 1 for the full analysis.

- **Option A: Shard-managed event loops** — Each shard is a Roc Task that
  owns a Dict of node states and a per-node message queue. Round-robin
  processing.
- **Option B: Per-node Tasks with channels** — Each awake node is its own
  Task with an input channel. Closest to the Pekko actor model semantically.
  **Recommended in the complexities doc** but depends on whether Roc's Task
  system supports tens of thousands of lightweight tasks efficiently.
- **Option C: Shared thread pool with per-node locks** — Node "messages"
  become function calls protected by per-node mutexes. Loses the
  asynchronous message-passing model.
- **Option D: Differential dataflow** — Model the entire computation as a
  dataflow graph where operators process diffs. Naturally distributed.
  Steep conceptual cost. Best fit for standing-query-dominated workloads.
  (Added during Phase 2 brainstorming from the distributed streaming graph
  architecture discussion.)

**Phase 3 brainstorming must evaluate A/B/C/D explicitly and make a call.**
No option is obviously right for all goals. The decision weighs:
- Fidelity to Quine's actor-per-node model
- Performance for the dominant workload (high-throughput ingest + incremental SQ evaluation)
- Ease of extending to distribution later
- Conceptual complexity for the user (who is learning Roc / FP)

### D2. Node Lifecycle (Sleep/Wake)

Phase 1 types already include `WakefulState` references in the analysis.
Phase 3 must implement:

- **Cache eviction policy** — LRU? LFU? Hand-rolled size-based?
- **Wake-on-message semantics** — How does a message for a sleeping node
  trigger its reconstruction transparently?
- **Cooperative sleep protocol** — If a node is mid-computation, how does
  the shard tell it to sleep without interrupting in-flight work?
- **Snapshot-vs-journal restore** — Phase 2 provides the persistence
  interface; Phase 3 orchestrates when to snapshot on sleep.

### D3. Routing / QuineId → Node Location

- **Single-node case**: QuineId → hash → shard index → local Dict. Trivial.
- **Multi-node case (future)**: QuineId → consistent hash → cluster member
  → RPC. Needs FR 004 primitives.

Phase 3's routing layer should be structured so that the multi-node case
drops in without changing the single-node code path. Specifically:
- The routing function takes a QuineId and returns an opaque "node handle"
- Today, that handle is always "local, managed by this shard"
- Future: the handle may be "remote, managed by cluster member N"
- Operations on the handle are abstracted enough that the local vs remote
  distinction is invisible to callers (actor-model location transparency)

## Cross-Cutting Concerns Phase 3 Must Address

### Supernode Handling

A graph node with millions of edges breaks every naive actor-per-node or
partition-based design. Phase 3 must explicitly design for this case, not
leave it for Phase 4 or later.

Mitigations to consider:
- **Edge splitting**: Split a supernode's edge set into fragments stored
  separately, each managed independently.
- **Lazy edge iteration**: Standing queries walk edge fragments lazily
  rather than materializing the whole adjacency list.
- **Per-edge-type locality**: Co-locate edges of the same type for a
  supernode so pattern matches don't force cross-fragment lookups.
- **Bounded fan-out**: When a supernode's neighborhood is too large,
  propagate match state lazily rather than eagerly triggering every edge.
- **Differential dataflow natively handles high fan-out** — supernodes
  become less painful in Option D than in A/B/C.

Added during Phase 2 brainstorming from cross-checking with another
architectural analysis. See `docs/src/complexities/README.md` Section 1.

### Memory Management

Phase 3 introduces stateful, long-running processes for the first time
in the Roc port. Memory management concerns:

- **Bounded caches everywhere** — node state cache, hot-path lookup caches,
  serialization buffers. No unbounded data structures.
- **Refcount-driven in-place mutation** — Roc's key performance optimization
  (as of research in Phase 2). Phase 3 code must preserve refcount-1 paths
  for `Dict` operations on the node state cache.
- **Leak detection** — structured logging with counters for cache sizes,
  pending message queues, and active Task counts.

### Effect Model and Purity Inference

Phase 2 research established that pure Roc state threading works today, and
the distribution migration path involves moving to effectful (`=>`) operations
via a custom host. Phase 3 must decide:

- Is Phase 3's code purely state-threaded (`->` everywhere), or does it
  already use effects (`=>`) with basic-cli as the platform?
- If the latter, how much of the Task / effect infrastructure must exist
  in the custom host vs. basic-cli?

### Distribution-Friendly API Shapes (preserved from Phase 2)

Even though Phase 3 will be single-node, the API shapes should mirror
ADR-013's distribution-friendly principles:

- Opaque handles for stateful things (`Graph`, `Shard`, `Node`)
- Every node-related operation takes `QuineId` as explicit shard key
- Error sets include `Unavailable`, `Timeout`, `NotLeader` variants from
  day one (never produced in Phase 3 but documented for callers)
- No operations that return raw `Dict` or mutable views into internal state

## Questions for Phase 3 Brainstorming

These are the questions the brainstorming must answer before writing a spec:

1. Which concurrency model (A/B/C/D) — and why?
2. What is the smallest thing Phase 3 needs to deliver to unblock Phase 4?
3. Does Phase 3 build a custom Roc platform, or stay on basic-cli?
4. How are nodes awakened transparently when a message arrives for a
   sleeping node?
5. How do we exercise the routing layer in tests without actual
   distribution?
6. How do we catch supernode-related bugs in testing? (What's a
   supernode-simulating test case?)
7. What's the eviction trigger? Memory pressure? Time-based? LRU
   count-based?
8. How do we measure whether Phase 3's concurrency choice scales to the
   target "many small nodes like Raspberry Pis" goal?

## Preliminary Recommendations (for the brainstorming to start from)

Based on what we know today:

- **Concurrency model**: Start with **Option B (per-node Tasks with
  channels)** as the primary candidate. Prototype first to verify Roc's
  Task system handles 50k+ lightweight tasks. Fall back to A if it
  doesn't. Keep D as a future research direction but don't build it yet.
- **Platform**: Stay on basic-cli for Phase 3. Custom platform work
  begins when distribution becomes a concrete need.
- **Effects**: Use pure state-threading (`->`) internally. The public
  API for Graph operations can be shaped for effects but implemented
  purely for now.
- **Supernode strategy**: Reserve space in the node state representation
  for "edges are managed externally via a fragment pointer" — plan but
  don't implement. Treat supernode handling as a Phase 4 concern
  ("can standing queries efficiently traverse a supernode's edges?")
  rather than a Phase 3 one.

These are **seed recommendations**, not decisions. The brainstorming must
evaluate them critically.

## Related

- `docs/src/complexities/README.md` — Section 1 has the concurrency
  option analysis
- `logs/feat/004-roc-distributed-systems-primitives.md` — primitives
  needed for future distribution (not blocking Phase 3)
- ADR-013 — distribution-friendly API shape for the persistor (same
  principles apply to Phase 3)
