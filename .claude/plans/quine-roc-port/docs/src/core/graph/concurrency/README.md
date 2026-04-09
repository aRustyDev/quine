# Graph Concurrency Model

## What Happens Here

Quine's concurrency model is built on the Pekko actor system. Every node in the graph is an independent Pekko actor, and every shard is also a Pekko actor. The actor model provides the fundamental guarantee that Quine depends on: **each node processes exactly one message at a time, in the order messages arrive in its mailbox**. This section traces how that concurrency model works end-to-end: message delivery, node-level processing guarantees, the sleep/wake lifecycle, and the inter-actor communication patterns.

### The Actor Hierarchy

```
ActorSystem ("graph-service")
  |
  +-- GraphShardActor "shard-0"  (dispatcher: graph-shard-dispatcher)
  |     +-- NodeActor "<qid-0>"  (dispatcher: node-dispatcher, mailbox: node-mailbox)
  |     +-- NodeActor "<qid-1>"
  |     +-- ...
  |
  +-- GraphShardActor "shard-1"
  |     +-- NodeActor "<qid-2>"
  |     +-- ...
  |
  +-- ... (shardCount shards)
  |
  +-- ExactlyOnceAskNodeActor (transient, per relayAsk call)
  +-- ExactlyOnceAskActor (transient, per non-node relayAsk)
  +-- SkipOptimizingActor (cached per Cypher query+namespace+atTime)
  +-- QuinePatternRegistry (singleton)
  +-- QuinePatternLoader (singleton)
```

Node actors are children of their shard actors. Transient ask actors and Cypher optimization actors are top-level.

### Three Dispatchers

Quine uses three Pekko dispatchers (thread pools), defined in `QuineDispatchers`:

1. **`graph-shard-dispatcher`**: Runs shard actors. Handles node lifecycle management (wake, sleep, LRU), namespace operations, and message routing through shards. These operations should be fast and non-blocking.

2. **`node-dispatcher`**: Runs node actors, transient ask actors, and Cypher actors. This is the workhorse dispatcher where property/edge mutations, query execution, and standing query processing happen.

3. **`persistor-blocking-dispatcher`**: Runs blocking persistence I/O. Separated so that persistence operations (which may block on network or disk) don't starve the node or shard dispatchers.

### Concurrency Guarantee: Single-Threaded Node Access

The fundamental concurrency guarantee Quine relies on is:

**A node actor processes exactly one message at a time. All state mutations (properties, edges, standing query subscriptions) happen within the actor's `receive` method, which is never called concurrently.**

This means:
- No locks are needed within a node for property/edge mutations.
- A node can safely maintain mutable state (`var properties`, mutable edge collections, mutable standing query indexes) because only one thread accesses them at a time.
- Standing query notifications (fired by `runPostActions` after a mutation) execute in the same sequential flow as the mutation, so they see a consistent state.

The one exception is `wakefulState: AtomicReference[WakefulState]`, which is shared between the node actor and its shard actor. Both can atomically update this reference concurrently. This is the coordination mechanism for the sleep/wake protocol.

### Message Delivery Patterns

#### Tell (Fire-and-Forget)

`relayTell(quineRef, message)` delivers a message without expecting a response:

1. **Fast path** (node is awake and local): `shard.withLiveActorRef(qid, actorRef => actorRef.tell(message, sender))`. This acquires a `StampedLock.tryReadLock()` on the node's `actorRefLock`, sends directly, and releases. No shard involvement.

2. **Slow path** (node is asleep, waking, or going to sleep): The message is enqueued into the node's external `NodeMessageQueue` (a priority queue owned by the `NodeActorMailboxExtension`), and a `WakeUp` message is sent to the shard actor. When the node actor is created, its Pekko mailbox is initialized from this pre-existing queue, so the message will be delivered.

#### Ask (Request-Response)

`relayAsk(quineRef, message)` sends a message and returns a `Future[Resp]`:

1. A transient `ExactlyOnceAskNodeActor` is created. It holds:
   - The `Promise[Resp]` that backs the returned `Future`.
   - A timeout timer (if the response doesn't arrive in time, the promise fails with `ExactlyOnceTimeoutException`).
   - For remote destinations: a retry loop that re-sends via `DeliveryRelay` every 2 seconds until acknowledged.

2. The message is constructed with the ask actor's `WrappedActorRef` as the `replyTo`. The node processes the message and sends the response back to this ref.

3. The ask actor receives the response, fulfills the promise, and stops itself.

**Delivery guarantees**:
- For local nodes: at-most-once delivery (the message is sent once; if the node dies before processing it, the ask times out).
- For remote nodes: exactly-once delivery via `DeliveryRelay` with dedup IDs. The shard maintains a 10,000-entry LRU of recent dedup IDs.

#### Node-to-Node Communication

Nodes communicate with other nodes through `relayTell` and `relayAsk` on the `graph` object, which they hold a reference to. Common patterns:

- **Edge reciprocal updates**: When `LiteralOpsGraph.addEdge(from, to, label)` is called, it sends `AddHalfEdgeCommand` to both endpoints in parallel.
- **Standing query propagation**: A node change triggers `runPostActions`, which may send `DomainNodeSubscriptionCommand`s or `MultipleValuesStandingQueryCommand`s to other nodes via `relayTell`.
- **Cypher query traversal**: `CypherBehavior` on one node may issue `relayAsk` to adjacent nodes to continue a query traversal.

### The Sleep/Wake Lifecycle

The sleep/wake lifecycle is the mechanism that allows Quine to manage more nodes than fit in memory. It is a cooperative protocol between the shard actor and the node actor.

#### State Machine

```
          [0] WakeUp
              |
              v
          +--------+
  [2] +-->| Awake  |<--+ [2]
      |   +--------+   |
      |       |         |
      |     [1] sleepActor
      |       |         |
      |       v         |
      |  +--------------+
      +--| Considering  |
         |    Sleep     |
         +--------------+
              |
            [4] GoToSleep accepted
              |
              v
         +-----------+
         | Going To  |
         |   Sleep   |
         +-----------+
              |
            [5] SleepOutcome
              |
              v
         +---------+
         | Asleep  |
         | (not in |
         |   map)  |
         +---------+
```

Transitions:
- **[0] Shard -> WakeUp**: Shard receives a `WakeUp` message, loads state from persistence, creates node actor. State becomes `Awake`.
- **[1] Shard -> sleepActor**: Shard's LRU evicts a node. Atomically updates `wakefulState` from `Awake` to `ConsideringSleep(deadline)`, sends `GoToSleep` to node.
- **[2] Node refuses sleep**: Node receives `GoToSleep`, checks the deadline and recent activity. If the deadline expired or there was recent I/O, atomically updates back to `Awake`, sends `StillAwake` to shard.
- **[2] Shard re-awakens node**: A new message arrives for the node while `ConsideringSleep`. The shard atomically updates back to `Awake` and delivers the message.
- **[4] Node accepts sleep**: Deadline has not expired and no recent activity. Node atomically transitions to `GoingToSleep(shardPromise)`. Persists snapshot (if configured). Acquires permanent write lock on `actorRefLock`. Calls `context.stop(self)`.
- **[5] Shard receives SleepOutcome**: `SleepSuccess` -- shard removes node from maps. `SleepFailed` -- shard re-wakes the node.

#### Why Sleep/Wake Exists

Quine graphs can have billions of nodes. Only a fraction can be in memory at once. The sleep/wake mechanism provides:

1. **Bounded memory**: The soft/hard limits on in-memory nodes guarantee that the JVM won't run out of memory regardless of graph size.
2. **Transparent restoration**: Sending a message to a sleeping node automatically wakes it. Callers don't need to know whether a node is in memory.
3. **Persistence integration**: Sleeping forces a snapshot write, ensuring durability. Waking reads the snapshot+journal, ensuring correctness.
4. **Cost-based eviction**: `costToSleep` scales with edge count (roughly `log2(edges) - 2`). Heavily-connected nodes are more expensive to evict because they take longer to restore.

#### Sleep Refusal Criteria

A node in `ConsideringSleep` will refuse sleep (transition back to `Awake`) if:
- The `SleepDeadlineDelay` (3 seconds) has elapsed since the shard initiated the sleep request.
- A write occurred within `declineSleepWhenWriteWithinMillis` (default 100ms).
- An access occurred within `declineSleepWhenAccessWithinMillis` (default 0ms, meaning disabled).

#### The actorRefLock Protocol

The `StampedLock` on each `LiveNode` is a critical concurrency mechanism:

1. **Message delivery (fast path)**: `LocalShardRef.withLiveActorRef` acquires a **read lock** (non-blocking `tryReadLock()`). If the lock is acquired, the node's `ActorRef` is guaranteed to be valid. The message is sent, and the lock is released.

2. **Node going to sleep**: `GoToSleepBehavior` acquires a **write lock** (blocking `writeLock()`) and **never releases it**. This permanently prevents any future read locks from succeeding, which means no more messages can be sent via the fast path. The node then calls `context.stop(self)`.

3. **Why permanent write lock?** Because after the actor stops, the `ActorRef` becomes a dead letter ref. Any message sent to it would be silently lost. The permanent write lock ensures that the fast path (`withLiveActorRef`) returns `false`, forcing the caller to use the slow path (enqueue + WakeUp).

### External Message Queue (NodeActorMailbox)

Quine uses a custom mailbox system (`NodeActorMailbox` and `NodeActorMailboxExtension`) to handle messages that arrive when a node is asleep:

1. **NodeActorMailboxExtension**: A Pekko extension (singleton per `ActorSystem`) that maintains a `ConcurrentHashMap[SpaceTimeQuineId, NodeMessageQueue]`. Messages can be enqueued before the node actor exists.

2. **NodeActorMailbox**: When a node actor is created, its Pekko mailbox is initialized by looking up the pre-existing `NodeMessageQueue` for that node ID. Messages that were enqueued while the node was asleep are immediately available.

3. **Priority**: The mailbox is a `StablePriorityBlockingQueue` where `GoToSleep` messages have lower priority (processed last). This ensures that if a node is woken up and immediately told to sleep, it processes the actual work messages first.

4. **Cleanup on sleep**: When a node's actor stops, the mailbox's `cleanUp` method removes messages that are meaningless for a sleeping node (`GoToSleep`, `ProcessMessages`, `Ack`, `UpdateStandingQueriesNoWake`, `CancelDomainNodeSubscription`) but retains other messages. If the queue is non-empty after cleanup, the shard sends another `WakeUp`.

### Futures and Async Patterns

Within the graph layer, several async patterns are used:

1. **`Future.traverse(shards)(...)(..., shardDispatcherEC)`**: Fan-out to all shards in parallel, collect results. Used for `askAllShards`, `recentNodes`, `enumerateAllNodeIds`.

2. **`Source.futureSource(...)`**: Pekko Streams pattern for a `Source` that isn't available yet (because the node needs to wake up first).

3. **Promise fulfillment from callbacks**: `SleepOutcome` carries a `Promise[Unit]` that the shard completes when it updates its node map. The `ExactlyOnceAskNodeActor` holds a `Promise[Resp]` that is fulfilled when the response arrives.

4. **Scheduled retries**: `WakeUp` messages use `context.system.scheduler.scheduleOnce` with a sliding delay for retries when wake-up fails (actor name still reserved, persistor error, hard limit reached).

5. **Persistence futures in GoToSleepBehavior**: `persistor.persistSnapshot(...)` returns a `Future` that is `.onComplete`-ed to send `SleepSuccess` or `SleepFailed` to the shard.

### Node Message Processing Flow

When a message arrives at a `NodeActor`, the processing flow is:

1. `receive` is called (the Pekko dispatch mechanism ensures single-threaded access).
2. `actorClockBehavior` wraps the handler to update the node's internal clock.
3. The message is pattern-matched against the message type hierarchy:
   - `NodeControlMessage` -> `goToSleepBehavior` (sleep lifecycle)
   - `CypherQueryInstruction` -> `cypherBehavior` (query execution)
   - `LiteralCommand` -> `literalCommandBehavior` (property/edge CRUD)
   - `AlgorithmCommand` -> `algorithmBehavior` (random walks)
   - `DomainNodeSubscriptionCommand` -> `domainNodeIndexBehavior` (SQ v1)
   - `MultipleValuesStandingQueryCommand` -> `multipleValuesStandingQueryBehavior` (SQ v2)
   - `UpdateStandingQueriesCommand` -> `updateStandingQueriesBehavior` (SQ registration)
   - `QuinePatternCommand` -> `quinePatternQueryBehavior` (pattern matching)
4. Within the handler, state mutations (property changes, edge changes) go through `guardEvents` -> `persistAndApplyEventsEffectsInMemory` -> `runPostActions`.
5. `runPostActions` notifies interested standing query subscribers about the state change.
6. The response (if ask) is sent back to the `replyTo` ref.

### EventEffectOrder: Memory-First vs Persistor-First

This is a configurable consistency/performance tradeoff:

**MemoryFirst** (default):
1. Apply the event to in-memory state immediately.
2. Persist the event asynchronously.
3. If persistence fails, retry infinitely (the event is already visible in memory).
4. Pros: Lower latency. Cons: If the JVM crashes between memory apply and persistence, the event is lost.

**PersistorFirst**:
1. Persist the event first.
2. Pause message processing (stash incoming messages) until persistence completes.
3. Apply the event to in-memory state.
4. Pros: Durability before visibility. Cons: Higher latency, throughput limited by persistence speed.

The stashing in PersistorFirst is implemented via a `StashedMessage` wrapper that goes through the mailbox priority queue with the same priority as the original message.

## Key Types and Structures

### Concurrency Primitives
| Type | Location | Role |
|------|----------|------|
| `ActorSystem` | Pekko | Top-level concurrency container |
| `ActorRef` | Pekko | Opaque handle for sending messages to an actor |
| `Props` | Pekko | Recipe for creating an actor (class + args + config) |
| `Receive` / `Actor.receive` | Pekko | Partial function defining message handling |
| `StampedLock` | JVM | Read/write lock for actor ref liveness protocol |
| `AtomicReference[WakefulState]` | JVM | Lock-free state machine for sleep/wake |
| `AtomicLong` (CostToSleep) | JVM | Lock-free counter for eviction cost |
| `ConcurrentHashMap` | JVM | Thread-safe map backing shard node registries |
| `Promise[T]` / `Future[T]` | Scala | Async result containers |

### Message Types (organized by destination)
| Destination | Message Type | Source |
|-------------|-------------|--------|
| Node | `LiteralCommand` (8+ variants) | `LiteralOpsGraph` via `relayAsk` |
| Node | `CypherQueryInstruction` | `CypherOpsGraph` via `relayAsk` |
| Node | `AlgorithmCommand` | `AlgorithmGraph` via `relayAsk` |
| Node | `DomainNodeSubscriptionCommand` | Other nodes via `relayTell` |
| Node | `MultipleValuesStandingQueryCommand` | Other nodes via `relayTell` |
| Node | `UpdateStandingQueriesCommand` | `StandingQueryOpsGraph.propagateStandingQueries` |
| Node | `QuinePatternCommand` | `QuinePatternOpsGraph` |
| Node | `GoToSleep` | Shard actor |
| Node | `ProcessMessages` | Shard actor |
| Shard | `WakeUp` | Self, `LocalShardRef`, `NodeActorMailboxExtension` |
| Shard | `SleepOutcome` (Success/Failed) | Node actor |
| Shard | `StillAwake` | Node actor |
| Shard | `SampleAwakeNodes` | `BaseGraph.recentNodes` |
| Shard | `InitiateShardShutdown` | `StaticShardGraph.shutdown` |
| Shard | `CreateNamespace` / `DeleteNamespace` | `GraphService` |
| Shard | `PurgeNode` | `LiteralOpsGraph.purgeNode` |
| Shard | `DeliveryRelay` | Remote shards (cross-host) |
| Shard | `LocalMessageDelivery` | Shard self for enqueued messages |
| Ask Actor | `BaseMessage.Response` | Node actor (response to ask) |
| Ask Actor | `BaseMessage.Ack` | Shard actor (dedup acknowledgment) |
| Ask Actor | `GiveUpWaiting` | Self (timeout) |

### Mailbox Infrastructure
| Type | Location | Role |
|------|----------|------|
| `NodeActorMailbox` | `messaging/NodeActorMailbox.scala` | Custom mailbox type for node actors |
| `NodeMessageQueue` | `messaging/NodeActorMailbox.scala` | Priority blocking queue |
| `NodeActorMailboxExtension` | `messaging/NodeActorMailbox.scala` | Pekko extension managing external message queues |

## Dependencies

### Internal (other stages/modules)

- **Node Model** (`graph/NodeActor.scala`, `graph/AbstractNodeActor.scala`): Nodes are the concurrency units. Their `receive` method defines the message processing loop.
- **Persistence** (`persistor/`): Sleep triggers snapshot persistence. Wake triggers snapshot+journal loading. `EventEffectOrder` determines whether persistence blocks message processing.
- **Standing Queries** (`graph/behavior/`): Standing query notifications are sent as messages between nodes. The `ingestValve` backpressure mechanism coordinates standing query buffer pressure with ingest flow.
- **Graph Structure** (`graph/BaseGraph.scala`, `graph/StaticShardGraph.scala`): Message routing and shard management are the structural framework within which concurrency operates.

### External (JVM libraries)

- **Apache Pekko Actors** (`org.apache.pekko.actor`): `Actor`, `ActorRef`, `Props`, `ActorSystem`, `Timers`, `Scheduler`. Provides the actor model: sequential mailbox processing, actor lifecycle, supervision.
- **Apache Pekko Streams** (`org.apache.pekko.stream`): `Source`, `Sink`, `Flow`, `BroadcastHub`, `BoundedSourceQueue`. Provides streaming with backpressure for query results and standing query output.
- **Apache Pekko Dispatch** (`org.apache.pekko.dispatch`): `MessageDispatcher`, `Envelope`, `MailboxType`, `MessageQueue`. The thread pool and mailbox infrastructure.
- **JVM Concurrency** (`java.util.concurrent`): `StampedLock`, `AtomicReference`, `AtomicLong`, `AtomicInteger`, `ConcurrentHashMap`, `Promise`. Low-level thread-safe primitives.
- **Dropwizard Metrics** (`com.codahale.metrics`): `Timer.Context` for measuring sleep/wake durations, message delivery times.

### Scala-Specific Idioms

- **Actor `receive` as partial function**: `def receive: Receive` where `Receive = PartialFunction[Any, Unit]`. Messages are dispatched via pattern matching. Unhandled messages go to Pekko's dead letter office.
- **`AtomicReference.updateAndGet` with pattern matching**: Used to atomically transition `WakefulState`. The lambda passed to `updateAndGet` pattern-matches on the current state to compute the next state.
- **`context.stop(self)`**: Actor self-termination during sleep. The actor's `postStop` hook runs, and the shard is notified via the pre-arranged `SleepOutcome` message.
- **`sender()`**: Pekko's implicit reference to the actor that sent the current message. Used in `GoToSleepBehavior` to know which shard actor to send `SleepOutcome`/`StillAwake` to.
- **`Timers` mixin**: Pekko trait for scheduled self-messages (`CheckForInactiveNodes` every 10s, `ShuttingDownShard` every 200ms).
- **`context.system.scheduler.scheduleOnce`**: One-shot delayed message for retry backoff.
- **`Future.traverse(...)(implicitly, ec)`**: Parallel async fan-out with explicit execution context.

## Essential vs. Incidental Complexity

### Essential (must port)

1. **Single-threaded node access**: The guarantee that each node processes one message at a time, with no concurrent state mutation, is the foundation of Quine's correctness. Every node mutation, standing query notification, and query execution depends on this.

2. **Cooperative sleep/wake protocol**: The state machine (Awake -> ConsideringSleep -> GoingToSleep -> Asleep) with its refusal criteria (deadline, recent activity) must be preserved. Without this, Quine cannot manage memory-bounded graph sizes.

3. **Message ordering within a node**: Messages sent to the same node are processed in order (FIFO within priority class). Standing query correctness depends on seeing mutations in the order they occurred.

4. **Request-response pattern**: Many graph operations (Cypher queries, literal ops, algorithm execution) require sending a message and receiving a typed response. This is the `relayAsk` pattern.

5. **Transparent wake-on-message**: A message to a sleeping node must automatically wake it. The caller should not need to know whether a node is awake or asleep.

6. **Persistence-integrated sleep**: When a node goes to sleep, its state must be durably persisted. When it wakes, its state must be fully restored. This is the contract that makes sleep/wake invisible to callers.

7. **EventEffectOrder choice**: The ability to choose between memory-first (lower latency, risk of data loss on crash) and persistor-first (higher latency, guaranteed durability) is a meaningful configuration option.

8. **Backpressure from standing query buffers to ingest**: When standing query output buffers fill, ingest must slow down. This prevents unbounded memory growth from result accumulation.

9. **Cross-node messaging for standing queries and edge reciprocals**: Nodes must be able to send messages to other nodes by QuineId. This is how edges are kept consistent (both endpoints update) and how standing queries propagate across the graph.

10. **Cost-based eviction**: Nodes with more edges are more expensive to restore from persistence, so they should be evicted less eagerly. The `costToSleep` mechanism captures this.

### Incidental (rethink for Roc)

1. **Pekko actor system**: The entire `Actor`/`ActorRef`/`Props`/`Receive`/`context` machinery. The essential need is "things that process messages sequentially." Pekko is one (heavyweight) way to get that.

2. **Three-dispatcher architecture**: Pekko's dispatcher-based thread pool partitioning (shard, node, blocking). The essential need is "I/O doesn't block compute." Roc's platform handles threading.

3. **StampedLock for actor ref liveness**: This entire mechanism exists because Pekko actors can be stopped while someone holds a reference. If the concurrency model guarantees that references are always valid (or that sending to a stopped entity is safe), this complexity disappears.

4. **ExactlyOnceAskNodeActor**: Temporary actors for request-response. This exists because Pekko actors don't have native request-response. In Roc, `Task` natively supports this.

5. **Custom mailbox (NodeActorMailbox)**: Priority queue with external pre-population. This exists because Pekko mailboxes are normally created with the actor and can't be pre-filled. Quine works around this with the `NodeActorMailboxExtension`.

6. **DeliveryRelay with dedup IDs**: Cross-host exactly-once delivery with a 10,000-entry LRU dedup cache. This is only needed for clustered deployment. A single-host Roc port can start without it.

7. **`sender()` implicit**: Pekko's mechanism for knowing who sent the current message. In Roc, the sender identity would be explicit in the message or callback.

8. **`Timers` mixin for periodic signals**: The shard uses Pekko `Timers` for `CheckForInactiveNodes` (every 10s) and `ShuttingDownShard` (every 200ms). In Roc, this becomes a simple periodic task.

9. **`Promise[Unit]` for sleep coordination**: The `shardPromise` in `GoingToSleep` tracks whether the shard has updated its bookkeeping. In Roc, this coordination could be a direct callback or a channel.

10. **AtomicReference.updateAndGet with lambdas**: The lock-free state machine pattern for `WakefulState`. In Roc, if nodes are managed by their shard (which processes shard messages sequentially), the state machine transitions don't need to be atomic -- they're protected by the shard's sequential processing.

## Roc Translation Notes

### Maps Naturally

- **WakefulState as a tagged union**:
  ```
  WakefulState : [
      Awake,
      ConsideringSleep { deadline : U64 },
      GoingToSleep,
  ]
  ```

- **SleepOutcome as a tagged union**:
  ```
  SleepOutcome : [
      SleepSuccess { id : SpaceTimeQuineId },
      SleepFailed { id : SpaceTimeQuineId, snapshot : List U8, error : Str },
  ]
  ```

- **Message type hierarchy as a tagged union**: All the message types (`LiteralCommand`, `CypherQueryInstruction`, etc.) become variants of a single `NodeMessage` union.

- **EventEffectOrder as a tag**: `[MemoryFirst, PersistorFirst]`.

- **Cost-to-sleep as a plain integer**: `costToSleep : I64`, computed from edge count.

- **Sleep refusal criteria**: Pure function: `shouldDeclineSleep : { recentWriteMillis : U64, recentAccessMillis : U64, deadlineMillis : U64, config : SleepConfig } -> Bool`.

### Needs Different Approach

- **The fundamental node concurrency model**: This is the single biggest design decision. Three viable approaches:

  **Option A: Shard-managed event loops.** Each shard is a Roc `Task` that owns a `Dict SpaceTimeQuineId NodeState` and a per-node message queue (`Dict SpaceTimeQuineId (Deque NodeMessage)`). The shard round-robins through nodes with pending messages, processing one message per node before moving on. Pros: simple, no per-node overhead. Cons: a long-running message on one node blocks all other nodes in the shard.

  **Option B: Per-node tasks with channels.** Each awake node is a Roc `Task` with an input `Channel NodeMessage`. The shard creates the task on wake-up and closes the channel on sleep. Pros: true per-node concurrency. Cons: overhead of one task per awake node (could be 50,000+).

  **Option C: Shared thread pool with per-node locks.** Node "messages" become function calls. Each node has a mutex. The caller acquires the mutex, applies the operation, releases. Pros: no task/actor overhead. Cons: callers block waiting for the lock; loses the asynchronous message-passing model.

  **Recommendation: Option B** (per-node tasks), because it preserves the essential semantics (sequential per-node processing, async message passing, transparent wake-on-message) most faithfully. The Roc platform should be evaluated for lightweight task support.

- **Sleep/wake as cache eviction**: Instead of actor creation/destruction, model sleep/wake as entries in a bounded cache:
  ```
  NodeCache : {
      awakeNodes : Dict SpaceTimeQuineId NodeHandle,
      messageQueues : Dict SpaceTimeQuineId (Deque NodeMessage),
      lru : LruIndex SpaceTimeQuineId,
      softLimit : U32,
      hardLimit : U32,
  }
  ```
  When a node is evicted from `awakeNodes`, its state is persisted and its `NodeHandle` is dropped. When a message arrives for a missing node, its state is restored from persistence and a new `NodeHandle` is created.

- **Request-response**: Replace `ExactlyOnceAskNodeActor` with Roc's `Task` with timeout:
  ```
  relayAsk : Graph, QuineRef, (ResponseChannel -> NodeMessage) -> Task Resp
  ```
  The graph creates a response channel, constructs the message with the channel embedded, delivers the message, and awaits the channel with a timeout.

- **Backpressure**: Replace `SharedValve` + `BroadcastHub` with bounded channels. Standing query results flow into a bounded channel. When the channel is full, the producer (node's `runPostActions`) blocks or returns a backpressure signal that propagates to the ingest source.

- **Periodic tasks**: Replace Pekko `Timers` with a Roc `Task` that loops with a sleep:
  ```
  checkInactiveNodes : ShardState -> Task [Step ShardState]
  checkInactiveNodes = \state ->
      Task.sleep 10_000 # 10 seconds
      |> Task.await
      |> \_ -> doEviction state
  ```

- **Cross-node messaging**: `relayTell` becomes enqueuing a message into the target node's channel (if awake) or its external queue (if asleep), and signaling the shard to wake it. This can be a pure function on the shard's state.

### Open Questions

1. **Does Roc's platform support lightweight tasks efficiently enough for 50,000+ concurrent node tasks?** If not, Option A (shard-managed event loops) may be necessary, which has different performance characteristics.

2. **How does Roc handle task cancellation?** The sleep protocol requires stopping a running node task. If Roc tasks can't be cancelled, the node task must check a flag periodically or the shard must close its input channel.

3. **What is Roc's mechanism for bounded channels with backpressure?** The standing query buffer -> ingest backpressure path requires a channel that signals "full" to producers. This might be a platform primitive or need to be built.

4. **Should the port preserve the two-phase sleep protocol (ConsideringSleep -> GoingToSleep)?** The ConsideringSleep state exists so that the node can refuse sleep if it has recent activity. A simpler model might be: the shard checks recent activity before evicting, eliminating the need for the node's cooperation.

5. **How to handle the memory-first EventEffectOrder without crash risk?** In memory-first mode, the event is visible before it's persisted. If the process crashes, the event is lost but standing query subscribers may have already reacted to it. Is this acceptable for the Roc port, or should persistor-first be the only option?

6. **Can the fast-path direct delivery be preserved?** The Pekko implementation uses a read lock to ensure the actor is alive. If node tasks in Roc have stable channel handles that are safe to write to even after the task exits (messages are just dropped), the fast path simplifies to "is the node in the cache? if so, write to its channel."

7. **What replaces the priority mailbox?** The `GoToSleep` message has lower priority. If Roc uses channels, there's no built-in priority mechanism. Options: two channels (high/low priority), or the node checks for pending work before processing sleep requests.

8. **Should cross-host clustering be designed now or deferred?** The `DeliveryRelay` + dedup mechanism is only for clustered deployment. The Roc port could start single-host and design clustering later, but early architectural decisions (message format, shard routing) should leave room for it.

9. **What is the Roc equivalent of AtomicReference for the WakefulState?** If the shard manages node lifecycle and processes shard messages sequentially, the `WakefulState` doesn't need to be atomic -- it's just a field in the shard's node state record. But if the fast path allows concurrent access to node state, some synchronization is needed.

10. **How to model the GraphService's trait composition in Roc?** The API surface could be: (a) one large `Graph` module, (b) a `GraphHandle` record with function fields, or (c) separate modules that each accept a `GraphHandle` parameter. Option (c) is most modular but requires defining what `GraphHandle` exposes.
