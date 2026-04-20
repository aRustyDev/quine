# Threading × Distribution × Process Topology Analysis

**Date:** 2026-04-19
**Context:** Phase 3a threading model selection. Analyzed how `std::thread` vs
`tokio` interacts with the ADR-016 concurrency model (A vs B) and the future
distribution model (simulated vs true).

**Referenced by:** ADR-016, ADR-017

---

## The Three Dimensions

1. **Concurrency model**: A (shard event loops, ADR-016) vs B (per-node tasks)
2. **Distribution**: Simulated (multi-thread, one host) vs True (multi-host)
3. **Process topology**: threads-per-process, processes-per-host

## The Four Quadrants

| | Simulated Distribution | True Distribution |
|---|---|---|
| **A: Shard Event Loops** | Current design. N threads on one host, each owns a Dict of nodes. | Each machine runs 1+ shards. Cross-machine messages via network RPC. |
| **B: Per-Node Tasks** | Future option (if ADR-016 revisited). Tokio tasks per awake node. | Nodes can migrate between machines. Per-node network routing. |

---

## Full Analysis by Aspect

### Shard Worker Overhead

| | A + Simulated | A + True Dist | B + Simulated | B + True Dist |
|---|---|---|---|---|
| Worker model | N std::threads, ~8KB stack each | 1+ std::threads per machine + RPC I/O | N coordinators + up to 50K tokio tasks | Fewer tasks per machine, tasks can migrate |
| Baseline (4 shards) | **~32KB** | ~8KB + ~2MB tokio for RPC | ~2MB tokio + ~2-4KB per task | Same, spread across machines |
| Hot path | `recv → Roc → effects` (zero async) | Same locally; RPC adds serde | `spawn_blocking` per Roc call (~1-2μs) | Same + network latency |
| Best threading | **std::thread** | **Hybrid** (std + tokio for RPC) | **tokio** | **tokio** |

### Timer Implementation

| | A + Simulated | A + True Dist | B + Simulated | B + True Dist |
|---|---|---|---|---|
| Timer count | N (1 CheckLru per shard) + M AskTimeouts | Same + RPC timeouts | N shard + M per-node (thousands) | Same + network timeouts |
| Best approach | Either (std or tokio fine for ~8 timers) | **tokio::time** (RPC deadlines) | **tokio::time** (thousands of timers) | **tokio::time** |

### Persistence I/O

| | A + Simulated | A + True Dist | B + Simulated | B + True Dist |
|---|---|---|---|---|
| I/O model | Offloaded thread pool | Network persistence (remote DB) | Same as A+Sim | Network + consensus |
| Best approach | Either (thread pool or tokio) | **tokio** (async network essential) | **tokio** (already have it) | **tokio** |

### Complexity

| | A + Simulated | A + True Dist | B + Simulated | B + True Dist |
|---|---|---|---|---|
| Concurrency | **Trivial** — sequential recv loop | Moderate — add RPC layer | High — task lifecycle, per-node backpressure | **Very high** — migration, split brain |
| Roc ABI surface | N shard calls (proven) | Same | 50K+ concurrent calls (**unproven**) | Same |
| Estimated Rust LoC | **~500-800** | ~1500-2000 | ~1200-1500 | ~2500+ |

### Dependencies

| | A + Simulated | A + True Dist | B + Simulated | B + True Dist |
|---|---|---|---|---|
| Required | **crossbeam-channel** | crossbeam + tokio + RPC (tonic) | **tokio** | tokio + RPC |
| Weight | **Light** | Heavy | Medium | Heavy |

### Memory per Host (RPi CM5, 8GB)

| | A + Simulated | A + True Dist | B + Simulated | B + True Dist |
|---|---|---|---|---|
| Runtime | **~32KB** | ~2MB (tokio for RPC) | ~2MB (tokio) | ~2MB |
| Per-node | ~200-500B (Dict entry) | Same | ~2-4KB (tokio task + channel) | Same |
| At 10K nodes | **~5MB** | ~7MB | ~25-45MB | ~15-25MB (spread) |
| At 50K nodes | **~25MB** | ~27MB | **~125-225MB** | ~30-50MB/machine |

### CPU (RPi CM5, 4 cores)

| | A + Simulated | A + True Dist | B + Simulated | B + True Dist |
|---|---|---|---|---|
| Executor overhead | **None** | Minimal (tokio for network only) | spawn_blocking per call | Same + serde |
| Core utilization | 4 shards ↔ 4 cores | 1+ shards/machine, cores for I/O | Fine-grained (no HoL) | Same |
| Low load winner | **Best** | Good | Overhead without benefit | Overhead without benefit |
| High contention winner | Weakest (HoL blocking) | Good (see below) | **Best** | **Best** |

---

## Head-of-Line Blocking: The Distribution Mitigation

The primary weakness of Option A is head-of-line blocking: a slow node
operation blocks all other nodes in the same shard. The blast radius depends
on **nodes per shard**, which depends on **total shard count**.

### Blast radius by topology

| Topology | Total shards | Nodes/shard (200K nodes) | Blast radius |
|----------|-------------|--------------------------|--------------|
| A+Sim, 1 host × 4 threads | 4 | 50,000 | **25%** |
| A+TrueDist, 20 hosts × 1 thread | 20 | 10,000 | 5% |
| A+TrueDist, 20 hosts × 4 threads | 80 | 2,500 | **1.25%** |
| A+TrueDist, 20 hosts × 4 procs × 1 thread | 80 | 2,500 | 1.25% + crash isolation |
| A+TrueDist, 20 hosts × 4 procs × 4 threads | 320 | 625 | **0.3%** |

**Key insight:** True distribution naturally reduces head-of-line blocking
for Option A. At 80 shards (20 RPis × 4 threads), a slow Cypher query
blocks ~2,500 nodes — 1.25% of the graph. The blocking weakness that
motivates Option B largely **evaporates with distribution**.

Option B solves a problem that distribution already solves, at much higher
memory cost (25-45MB vs 5MB at 10K nodes) and unproven Roc ABI requirements.

### When Option B is still justified

- **Single-host deployment at scale** (50K+ nodes, no distribution) where
  25% blast radius is unacceptable
- Roc gains proven 50K+ concurrent call support, removing the ABI risk
- Workload is dominated by long-running queries (seconds, not milliseconds)
  that make even 1.25% blast radius painful for tail latency

---

## Multi-Thread vs Multi-Process per Host

| Aspect | Multi-thread (1 process, N shards) | Multi-process (N processes, 1 shard each) |
|--------|-----------------------------------|------------------------------------------|
| Memory | **Shared heap** — 1 Roc runtime copy | N Roc runtime copies (~2-5MB each) |
| Crash isolation | Thread panic kills all shards on host | **Process crash kills 1 shard only** |
| IPC overhead | **Zero** — crossbeam in shared memory | OS IPC (~10-50μs per message) |
| Deployment | 1 binary, 1 config | Process supervisor, N configs |
| RPi fit (4 shards) | **~25MB** | ~40-60MB (runtime copies) |
| Monitoring | 1 process | N processes, needs orchestration |

**Recommendation:** Multi-thread for now. Multi-process can be added later
by running each instance with `--shard-count=1` behind a process supervisor.
No code changes required — the process boundary is external.

---

## Conclusion

**Current (Phase 3a):** std::thread for shard workers, small tokio runtime
for timers + persistence I/O. Optimal for A+Simulated.

**Distribution migration (post-Phase 7):** Add tokio-based RPC alongside
shard threads. Worker loop unchanged. Head-of-line blocking drops to ~1%
blast radius at 80 shards.

**Option B trigger:** Only if measured head-of-line blocking exceeds
acceptable latency targets at the distributed shard count AND Roc supports
50K+ concurrent calls.

---

## Shard Replication: Crash Isolation via Deterministic Replay

The current architecture is naturally replication-ready due to three
properties of the Roc dispatch path:

1. **Deterministic dispatch.** `handle_message(state, msg, now)` is a pure
   function — no `current_time!`, `log!`, or other host effects are called
   during dispatch. Two processes that feed identical messages in identical
   order produce identical `ShardState`. Verified: `grep` for effectful
   calls in `packages/graph/` returns zero matches.

2. **Effects are data, not actions.** Dispatch returns `(ShardState, List
   Effect)`. The host executes effects after the Roc call returns. A
   follower process can run the same dispatch and simply discard the effect
   list, maintaining state without producing side effects.

3. **Timing is a parameter.** `now` is passed into `handle_message` and
   `on_timer`, not fetched during dispatch. Leader and follower receive the
   same `now` value via the replicated message stream.

### Replication levels

| Level | Model | Recovery time | Data loss | Complexity |
|-------|-------|--------------|-----------|------------|
| **0: Cold standby** | Wake from persistence (snapshot + journal). | Seconds | Last unflushed journal entries | **Already built** (sleep/wake) |
| **1: Warm follower** | Replica receives same message stream, runs dispatch, discards effects. Promote on leader crash. | **Milliseconds** (redirect channel) | **Zero** (follower is current) | Moderate (message fan-out + leader election) |
| **2: Multi-writer** | Multiple processes accept writes for same shard. Requires consensus or CRDTs. | Near-zero | Zero (but consistency is complex) | Very high |

### Level 1 architecture

```
                   ┌──────────────────┐
  messages ──────► │  Leader (shard 0) │──► executes effects
                   │  handle_message   │    (channel sends, persist, log)
                   └──────────────────┘
                          │
                  same messages (fan-out)
                          │
                   ┌──────────────────┐
                   │ Follower (shard 0)│──► discards effects
                   │  handle_message   │    (state-only, no I/O)
                   └──────────────────┘
```

On leader crash: redirect message channel to follower. Follower starts
executing effects immediately. Zero state reconstruction needed.

### Seams already in place (no code changes required)

- **Channel-based message delivery** → fan-out is one line of channel wiring
- **`List Effect` return** → effect suppression is "don't drain the list"
- **`now` as parameter** → deterministic replay between leader and follower
- **No effectful calls in dispatch** → leader and follower compute identical state

### What Level 1 would require (future work)

- Message fan-out tap on shard channels
- Leader election (heartbeat + channel redirect, or Raft)
- Effect suppression flag on follower shard workers
- Follower discovery and registration

### Level 2 (multi-writer) — deferred

Multi-writer replication requires conflict resolution (CRDTs, consensus, or
last-writer-wins). This is a fundamentally harder problem and is deferred
until the single-writer replication model proves insufficient. Tracked for
future exploration.
