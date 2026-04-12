# Feature Request 004: Roc Distributed Systems Primitives

**Status:** Open (future ecosystem contributions)
**Filed:** 2026-04-11 (during Phase 2 brainstorming)
**Owner:** TBD
**Target:** Multiple separate Roc packages / platform contributions

## Context

The long-term goal of the Quine-to-Roc port is **native distribution** across
multiple nodes, including low-resource nodes like Raspberry Pis. Making this
real requires several distributed systems primitives that Roc's ecosystem
does not currently provide.

This feature request catalogs those primitives as individual subprojects.
Each is independently valuable beyond Quine — any Roc project building a
distributed system will hit these same gaps.

## The Primitives Needed

### 4a. Cluster Membership

**What:** A gossip-based or list-based protocol for tracking which nodes are
alive, dead, suspect, joining, or leaving a cluster. Enables new nodes to
join the cluster, detects failures, and propagates membership changes.

**Reference implementations in other ecosystems**:
- Hashicorp's `memberlist` (Go) — implements the SWIM gossip protocol
- `serf` (Go) — higher-level layer on top of memberlist with user events
- `rapid-rs` (Rust) — Rapid consensus for membership
- Erlang's built-in `net_kernel` and distribution primitives

**Roc path**: Most likely FFI to `memberlist` (via Go CGo wrapper) or to a
Rust implementation of SWIM. Pure Roc is possible but substantial work —
SWIM involves UDP transport, failure detection, and anti-entropy.

### 4b. Consistent Hashing

**What:** Map keys (`QuineId` in our case) to a position in a hash ring,
where cluster members each own a subset of the ring. New nodes joining or
leaving only rebalance a small fraction of keys.

**Reference implementations**:
- Ketama / Jump Consistent Hash (Google)
- Rendezvous Hashing (HRW) — simpler and often preferable to ring-based
- Maglev Hashing (Google) — higher quality load balance with more complex setup

**Roc path**: This is purely algorithmic. Rendezvous Hashing in particular
is ~50 lines of code in any language. **Best tackled as a pure-Roc
standalone package.** Could be the first "distributed primitive" to land.

### 4c. Network Transport / RPC

**What:** A protocol for sending typed messages between cluster members with
reasonable latency, framing, back-pressure, and error handling.

**Options in other ecosystems**:
- gRPC (HTTP/2 + protobuf)
- Cap'n Proto RPC (efficient serialization + RPC)
- QUIC-based custom protocols (raw UDP-derived)
- Apache Pekko Remoting (TCP with a custom framing format)

**Roc path**: Depends on the platform. The custom Roc platform that holds
host-side state (see ADR-013) is the right place to add a transport layer.
Likely start with TCP + length-prefixed frames + a simple RPC protocol
before reaching for QUIC. Alternatively, FFI to a Rust transport (tokio,
tonic for gRPC, or quinn for QUIC).

### 4d. Consensus (for metadata, not per-node data)

**What:** A protocol for agreeing on cluster-wide state (membership changes,
partition assignments, standing query registrations). Not needed for
per-node data, which can be eventually consistent.

**Reference implementations**:
- Raft (etcd, Consul use it) — well-understood, many implementations
- Paxos (original but much harder to implement correctly)
- Zab (ZooKeeper) — similar to Raft in practice

**Roc path**: FFI to an existing implementation is the pragmatic choice.
`raft-rs` (Rust) is a solid embedded Raft library. A pure Roc implementation
is a major subproject and not needed for initial distribution work.

### 4e. Distributed Tracing / Observability

**What:** Request tracing across nodes, metric aggregation, structured
logging with correlation IDs. Essential for debugging a distributed system
but typically underestimated.

**Options**:
- OpenTelemetry (OTLP protocol + SDK in host language)
- Simple structured logging + log aggregation (minimal but effective)

**Roc path**: The custom platform exposes effects for "emit span", "emit
metric", "log with correlation ID", and the host forwards these to an OTLP
collector or similar.

## Priority Order

For the Quine-to-Roc port specifically, the order in which these become
blockers:

1. **Consistent Hashing (4b)** — blocks any partition-based approach to
   distributing node data. Pure Roc, small scope. **Do first.**
2. **Network Transport / RPC (4c)** — blocks actually sending data between
   nodes. Must exist before distribution is real.
3. **Cluster Membership (4a)** — needed once we have >1 node. Could be
   a simple static list for the initial MVP.
4. **Distributed Tracing (4e)** — needed for debugging but not blocking
   functionality.
5. **Consensus (4d)** — only needed for metadata that must be globally
   consistent. Quine's graph data is per-node, so consensus is only
   needed for membership changes and partition assignment.

## Scope Boundary

Each of these is **a separate project, not part of the Quine port**. They
live in their own repos (e.g., `github.com/aRustyDev/roc-consistent-hash`),
are published as Roc packages, and Quine consumes them as dependencies
when distribution work begins (likely post-Phase-7).

## Relationship to Other FRs

- **FR 001 (Roc abilities exploration)** — abilities may offer cleaner
  interfaces for some of these primitives once mature
- **FR 002 (Roc UUID library)** — similar "fills a basic ecosystem gap"
  shape
- **FR 003 (Roc type info export)** — unrelated, but both are upstream
  contribution opportunities

## Why This Matters

- Every Roc project that wants to be distributed will hit these same gaps
- Each primitive is a high-leverage contribution — benefits the entire
  ecosystem
- Building them teaches deeply about distributed systems fundamentals
- Aligns with the project philosophy of contributing to young ecosystems

## Notes

- This FR is descriptive, not prescriptive. We're not committing to build
  all of these. We're documenting the gap so future decisions are informed.
- The Quine port's Phase 3+ work can proceed single-node. Distribution is
  a post-Phase-7 concern.
- If another community member starts building any of these before we do,
  we should use theirs and potentially contribute back.
