# Phase 4d: Standing Queries — Platform Wiring

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the pure SQ graph layer (Phase 4c) to the Rust/tokio host platform so that standing query results flow end-to-end: registration via shard messages, result delivery via a new host function, SQ state persistence via NodeSnapshot, backpressure propagation, and a smoke test app proving the full lifecycle.

**Architecture:** Phase 4c left the EmitSqResult effect handler as a log-only stub in `graph-app.roc` and the UpdateStandingQueries command as a no-op. Phase 4d completes the wiring: (1) add a new `emit_sq_result!` host function on both the Roc and Rust sides, (2) implement UpdateStandingQueries broadcast so newly registered SQs propagate to all nodes, (3) add SqPartState serialization so SQ state survives NodeSnapshot persistence, (4) implement backpressure propagation from the SQ result buffer to the host, and (5) build a smoke test app and integration tests proving the full lifecycle. Effects are dispatched eagerly via `roc_fx_*` host calls (Phase 3a pattern), not buffered.

**Tech Stack:** Roc (nightly, commit d73ea109cc2), Rust/tokio, crossbeam channels, roc_std FFI

**Key files to read before starting:**
- `app/graph-app.roc` — effect interpreter (EmitSqResult stub at line 121)
- `platform/Host.roc` — hosted function declarations
- `platform/Effect.roc` — public effect API wrapping Host
- `platform/src/roc_glue.rs` — Rust host function implementations
- `platform/src/shard_worker.rs` — recv-dispatch loop
- `packages/graph/shard/SqDispatch.roc` — SQ dispatch (UpdateStandingQueries no-op at line 188)
- `packages/graph/shard/ShardState.roc` — ShardState with sq_result_buffer, part_index
- `packages/graph/codec/Codec.roc` — SQ message codec (tags 0x10-0x13)
- `packages/graph/standing/state/SqPartState.roc` — SqPartState tagged union
- `packages/core/model/NodeSnapshot.roc` — SqStateSnapshot with state_bytes
- `docs/roc-quirks.md` — 8 Roc quirks (especially #6 sub-package routing, #8 record update syntax)

**Roc quirks to watch for:**
- **#6**: Sub-package imports only resolve one level — consuming packages need direct deps on sub-packages
- **#7**: Record field names collide with imported functions — use renamed bindings
- **#8**: Record update syntax needs plain variables — bind field access to intermediates
- **#2**: Compiler ICE with record destructuring — use field access instead

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `packages/graph/codec/SqStateCodec.roc` | Encode/decode SqPartState to/from bytes for NodeSnapshot persistence |
| `app/phase-4-smoke.roc` | Smoke test app: registers SQ, creates nodes, verifies result delivery |
| `tests/integration/sq_platform_test.roc` | Integration tests for SQ lifecycle through Rust host |

### Modified Files
| File | Changes |
|------|---------|
| `platform/Host.roc` | Add `emit_sq_result!` host function declaration |
| `platform/Effect.roc` | Add `emit_sq_result!` public wrapper |
| `platform/src/roc_glue.rs` | Add `roc_fx_emit_sq_result` Rust implementation + SQ result channel |
| `platform/src/main.rs` | Initialize SQ result channel at startup |
| `platform/src/shard_worker.rs` | (No changes needed — effects dispatched eagerly) |
| `app/graph-app.roc` | Wire EmitSqResult to `Effect.emit_sq_result!` host call |
| `packages/graph/shard/SqDispatch.roc` | Implement UpdateStandingQueries broadcast |
| `packages/graph/shard/ShardState.roc` | Add `drain_sq_results`, `sq_running_queries` accessors; UpdateStandingQueries message generation |
| `packages/graph/codec/Codec.roc` | Re-export SqStateCodec functions for snapshot encoding |
| `packages/graph/codec/main.roc` | Add SqStateCodec to package exports |
| `packages/graph/shard/SleepWake.roc` | Encode SQ state in NodeSnapshot on sleep |

---

## Task 1: Add `emit_sq_result!` Host Function (Roc Side)

**Files:**
- Modify: `platform/Host.roc`
- Modify: `platform/Effect.roc`

This task adds the Roc-side declaration for the new host function. The Rust implementation comes in Task 2.

- [ ] **Step 1: Add host function declaration to Host.roc**

```roc
# platform/Host.roc — add emit_sq_result! to the hosted list and declaration

hosted [send_to_shard!, persist_async!, current_time!, log!, emit_sq_result!]

## Send a message to a shard's input channel.
## Returns 0 on success, 1 if the channel is full.
send_to_shard! : U32, List U8 => U8

## Dispatch an async persistence command.
## Returns a request ID that will arrive later as a PersistenceResult message.
persist_async! : List U8 => U64

## Get the current wall-clock time in milliseconds since epoch.
current_time! : {} => U64

## Emit a log message.
## Levels: 0=error, 1=warn, 2=info, 3=debug
log! : U8, Str => {}

## Emit a standing query result to the host for delivery to consumers.
## Encodes query_id as U128 (16 bytes LE) + is_positive_match (1 byte) + data payload.
## Returns 0 on success, 1 if the result buffer is full (backpressure).
emit_sq_result! : List U8 => U8
```

Note: We pass the SQ result as pre-encoded `List U8` rather than structured types because the Roc-Rust FFI boundary works with byte buffers. The encoding format is: `[query_id_lo:U64LE][query_id_hi:U64LE][is_positive:U8][data_len:U32LE][data_bytes...]`.

- [ ] **Step 2: Add public wrapper to Effect.roc**

```roc
# platform/Effect.roc — add emit_sq_result! to the module exports and implementation

module [send_to_shard!, persist_async!, current_time!, log!, emit_sq_result!]

import Host

# ... existing functions unchanged ...

## Emit a standing query result to the host.
## Returns Err SqBufferFull if the host's result buffer is at capacity.
emit_sq_result! : List U8 => Result {} [SqBufferFull]
emit_sq_result! = |payload|
    result = Host.emit_sq_result!(payload)
    if result == 0 then
        Ok({})
    else
        Err(SqBufferFull)
```

- [ ] **Step 3: Verify Roc compiles**

Run: `roc check platform/Effect.roc`
Expected: No errors (the host function is declared but not yet implemented in Rust)

- [ ] **Step 4: Commit**

```bash
git add platform/Host.roc platform/Effect.roc
git commit -m "phase-4d: add emit_sq_result! host function declaration (Roc side)"
```

---

## Task 2: Implement `roc_fx_emit_sq_result` (Rust Side)

**Files:**
- Modify: `platform/src/roc_glue.rs`
- Modify: `platform/src/main.rs`

- [ ] **Step 1: Add SQ result storage to roc_glue.rs**

Add a global SQ result sender/receiver pair. SQ results are collected per-shard and can be read by consumers (future Phase 6 output sinks).

In `platform/src/roc_glue.rs`, add after the `PERSIST_SENDER` block:

```rust
// ============================================================
// Global SQ result sender — used by roc_fx_emit_sq_result.
// ============================================================

static SQ_RESULT_SENDER: OnceLock<crossbeam_channel::Sender<Vec<u8>>> = OnceLock::new();

/// Set the global SQ result sender. Must be called before any
/// Roc code that uses emit_sq_result!.
pub fn set_sq_result_sender(tx: crossbeam_channel::Sender<Vec<u8>>) {
    if SQ_RESULT_SENDER.set(tx).is_err() {
        panic!("SQ result sender already initialized");
    }
}

/// Get a reference to the SQ result receiver (for consumers/tests).
/// Not needed at runtime yet — consumers are Phase 6.
pub fn sq_result_sender() -> Option<&'static crossbeam_channel::Sender<Vec<u8>>> {
    SQ_RESULT_SENDER.get()
}
```

- [ ] **Step 2: Implement roc_fx_emit_sq_result**

In `platform/src/roc_glue.rs`, add the host function:

```rust
/// Emit a standing query result to the host's result channel.
/// Roc signature: emit_sq_result! : List U8 => U8
/// Returns 0 on success, 1 if the channel is full.
#[no_mangle]
pub extern "C" fn roc_fx_emit_sq_result(payload: &RocList<u8>) -> u8 {
    if let Some(tx) = SQ_RESULT_SENDER.get() {
        let bytes = payload.as_slice().to_vec();
        match tx.try_send(bytes) {
            Ok(()) => 0,
            Err(crossbeam_channel::TrySendError::Full(_)) => {
                eprintln!("emit_sq_result: result channel full (backpressure)");
                1
            }
            Err(crossbeam_channel::TrySendError::Disconnected(_)) => {
                eprintln!("emit_sq_result: result channel disconnected");
                1
            }
        }
    } else {
        // No consumer registered — log and succeed (results are dropped)
        // This is normal during tests or when no output sinks are configured.
        0
    }
}
```

- [ ] **Step 3: Register the function pointer in init()**

In `platform/src/roc_glue.rs`, update the `init()` function to include the new function:

```rust
pub fn init() {
    let funcs: &[*const extern "C" fn()] = &[
        roc_alloc as _,
        roc_realloc as _,
        roc_dealloc as _,
        roc_panic as _,
        roc_dbg as _,
        roc_memset as _,
        roc_fx_current_time as _,
        roc_fx_log as _,
        roc_fx_send_to_shard as _,
        roc_fx_persist_async as _,
        roc_fx_emit_sq_result as _,
    ];
    #[allow(forgetting_references)]
    std::mem::forget(std::hint::black_box(funcs));
}
```

- [ ] **Step 4: Initialize SQ result channel in main.rs**

In `platform/src/main.rs`, add channel initialization after the persist sender setup:

```rust
    // Start SQ result channel for standing query output.
    // Bounded channel with capacity matching the default SQ config buffer size.
    // Consumers (Phase 6 output sinks) will read from the receiver.
    let (sq_result_tx, _sq_result_rx) = crossbeam_channel::bounded::<Vec<u8>>(1024);
    roc_glue::set_sq_result_sender(sq_result_tx);
```

Add this after the `while !roc_glue::persist_sender_ready()` loop and before the shard worker spawn loop.

- [ ] **Step 5: Verify Rust compiles**

Run: `cd platform && cargo build 2>&1`
Expected: Compiles without errors

- [ ] **Step 6: Commit**

```bash
git add platform/src/roc_glue.rs platform/src/main.rs
git commit -m "phase-4d: implement roc_fx_emit_sq_result host function (Rust side)"
```

---

## Task 3: Wire EmitSqResult in graph-app.roc

**Files:**
- Modify: `app/graph-app.roc`

Replace the log-only stub with a real host function call that encodes the SQ result and sends it to the host.

- [ ] **Step 1: Add encode_sq_result helper to graph-app.roc**

Add before `encode_persist_command`:

```roc
## Encode a StandingQueryResult for the host's emit_sq_result! function.
## Format: [query_id_lo:U64LE] [query_id_hi:U64LE] [is_positive:U8] [data_len:U32LE] [data_key_value_pairs...]
## Data encoding: repeated [key_len:U16LE] [key_bytes...] [value_tag:U8] [value_bytes...]
encode_sq_result_payload : StandingQueryId, StandingQueryResult -> List U8
encode_sq_result_payload = |query_id, result|
    # Encode U128 query_id as two U64 LE
    lo = Num.int_cast(Num.bitwise_and(query_id, 0xFFFFFFFFFFFFFFFF)) |> encode_u64_le
    hi = Num.int_cast(Num.shift_right_zf_by(query_id, 64)) |> encode_u64_le
    is_positive_byte = if result.is_positive_match then 1u8 else 0u8
    # For now, encode data as the count of key-value pairs only.
    # Full QuineValue serialization is deferred to Phase 5 (query language needs it).
    # The host just needs the query_id + match polarity for Phase 4.
    pair_count = Dict.len(result.data) |> Num.to_u32
    count_bytes = encode_u32_le(pair_count)
    lo
    |> List.concat(hi)
    |> List.concat([is_positive_byte])
    |> List.concat(count_bytes)

encode_u64_le : U64 -> List U8
encode_u64_le = |n|
    List.range({ start: At(0), end: Before(8) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))

encode_u32_le : U32 -> List U8
encode_u32_le = |n|
    List.range({ start: At(0), end: Before(4) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))
```

- [ ] **Step 2: Update EmitSqResult handler in execute_effect!**

Replace the existing stub (lines 121-124) with:

```roc
        EmitSqResult({ query_id, result }) ->
            payload = encode_sq_result_payload(query_id, result)
            when Effect.emit_sq_result!(payload) is
                Ok({}) ->
                    is_pos = if result.is_positive_match then "+" else "-"
                    Effect.log!(3, "graph-app: SQ result $(is_pos) for query $(Num.to_str(query_id))")
                Err(SqBufferFull) ->
                    Effect.log!(1, "graph-app: SQ result buffer full for query $(Num.to_str(query_id))")
```

- [ ] **Step 3: Add import for StandingQueryResult types**

Update the imports at the top of `graph-app.roc`:

```roc
import types.Effects exposing [Effect]
import standing_result.StandingQueryResult exposing [StandingQueryId, StandingQueryResult]
```

Wait — `graph-app.roc` imports from package shorthands (`types:`, `shard:`, etc.). Check whether the `standing_result` shorthand is available. If not, the app needs a new dependency declaration.

In the `app` header, add the standing result package:

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc",
      id: "../packages/core/id/main.roc",
      shard: "../packages/graph/shard/main.roc",
      codec: "../packages/graph/codec/main.roc",
      routing: "../packages/graph/routing/main.roc",
      types: "../packages/graph/types/main.roc",
      standing_result: "../packages/graph/standing/result/main.roc" }
```

Then import:

```roc
import standing_result.StandingQueryResult exposing [StandingQueryId, StandingQueryResult]
```

Note: Per Roc quirk #6, app files must declare direct dependencies on sub-packages.

- [ ] **Step 4: Verify Roc compiles**

Run: `roc check app/graph-app.roc`
Expected: Compiles (may warn about unused; that's fine since the host function isn't linked yet)

- [ ] **Step 5: Commit**

```bash
git add app/graph-app.roc
git commit -m "phase-4d: wire EmitSqResult to emit_sq_result! host function in graph-app"
```

---

## Task 4: Implement UpdateStandingQueries Broadcast

**Files:**
- Modify: `packages/graph/shard/SqDispatch.roc`
- Modify: `packages/graph/shard/ShardState.roc`

Currently `UpdateStandingQueries` is a no-op (SqDispatch.roc:188). This task makes it sync each node's SQ states with the shard's `running_queries` registry.

- [ ] **Step 1: Add `sq_running_queries` accessor to ShardState**

In `packages/graph/shard/ShardState.roc`, add to the module export list and implementation:

```roc
# Add to module exports: sq_running_queries, all_node_ids

## Return the running queries dict (for SQ sync).
sq_running_queries : ShardState -> Dict StandingQueryId RunningQuery
sq_running_queries = |@ShardState(s)| s.running_queries

## Return all node IDs in this shard (for broadcast).
all_node_ids : ShardState -> List QuineId
all_node_ids = |@ShardState(s)|
    Dict.keys(s.nodes)
```

- [ ] **Step 2: Implement UpdateStandingQueries in SqDispatch**

Replace the no-op at line 188 with sync logic. When a node receives `UpdateStandingQueries`, it should:
1. For each running query in the shard's part_index that this node doesn't have state for: create a `CreateSqSubscription` effect for the top-level query with a `GlobalSubscriber`.
2. For each SQ state the node has that is no longer in running_queries: remove it.

However, `handle_sq_command` operates on `NodeState` and doesn't have access to `ShardState` (running_queries). The broadcast must happen at the shard level.

**Design decision:** UpdateStandingQueries is handled at the **shard dispatch level** in `ShardState.handle_message`, not at the node level. When the shard receives an UpdateStandingQueries command (as a shard-level message, not a per-node message), it generates `CreateSqSubscription` messages for each awake node for each running query's top-level part.

In `packages/graph/shard/SqDispatch.roc`, update `handle_sq_command`:

```roc
        UpdateStandingQueries ->
            # UpdateStandingQueries is a node-level no-op.
            # The actual broadcast is handled at the shard level via
            # ShardState.broadcast_update_standing_queries, which generates
            # SendToNode effects for each awake node.
            { state: node, effects: [] }
```

This stays as a no-op at the node level. The shard-level broadcast is what generates the per-node messages.

- [ ] **Step 3: Add broadcast function to ShardState**

In `packages/graph/shard/ShardState.roc`, add:

```roc
# Add to module exports: broadcast_update_standing_queries

## Generate CreateSqSubscription messages for all awake nodes for all running queries.
##
## Called after a new SQ is registered or an existing one is cancelled.
## Produces SendToNode effects that will be drained by the app layer.
broadcast_update_standing_queries : ShardState -> ShardState
broadcast_update_standing_queries = |@ShardState(s)|
    # For each running query, generate a CreateSqSubscription to each awake node
    effects = Dict.walk(s.running_queries, [], |acc, _sq_id, running_query|
        top_part_id = MvStandingQuery.query_part_id(running_query.query)
        Dict.walk(s.nodes, acc, |inner_acc, node_id, entry|
            when entry is
                Awake(_) ->
                    subscriber : SqMsgSubscriber
                    subscriber = GlobalSubscriber({ global_id: running_query.id })
                    msg = SqCmd(CreateSqSubscription({
                        subscriber,
                        query: running_query.query,
                        global_id: running_query.id,
                    }))
                    effect = SendToNode({ target: node_id, msg })
                    List.append(inner_acc, effect)
                _ ->
                    inner_acc
        )
    )
    @ShardState({ s & pending_effects: List.concat(s.pending_effects, effects) })
```

Add necessary imports to ShardState.roc:

```roc
import standing_messages.SqMessages exposing [SqCommand, SqMsgSubscriber]
```

Wait — ShardState already imports from standing packages. Check if SqMessages is available. Looking at the existing imports in ShardState.roc, it imports `MvStandingQuery` and `StandingQueryResult`/`StandingQueryPartId`/`StandingQueryId` but NOT `SqMessages`. Need to add:

```roc
import standing_messages.SqMessages exposing [SqMsgSubscriber]
```

And the `main.roc` for the shard package must already have `standing_messages` as a dependency (it was added in Phase 4c). Verify this.

- [ ] **Step 4: Write test for broadcast_update_standing_queries**

Add to `packages/graph/shard/ShardState.roc` at the bottom:

```roc
expect
    # broadcast_update_standing_queries generates SendToNode for each awake node x running query
    shard = new(0, 4, default_config)
    qid1 = QuineId.from_bytes([0x01])
    qid2 = QuineId.from_bytes([0x02])
    ns1 = empty_node_state(qid1)
    ns2 = empty_node_state(qid2)
    awake1 : NodeEntry
    awake1 = Awake({ state: ns1, wakeful: Awake, cost_to_sleep: 0, last_write: 100, last_access: 100 })
    awake2 : NodeEntry
    awake2 = Awake({ state: ns2, wakeful: Awake, cost_to_sleep: 0, last_write: 100, last_access: 100 })
    shard2 = with_awake_node(shard, qid1, awake1)
    shard3 = with_awake_node(shard2, qid2, awake2)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    shard4 = register_standing_query(shard3, 1u128, query, Bool.true)
    shard5 = broadcast_update_standing_queries(shard4)
    effects = pending_effects(shard5)
    # Should have 2 SendToNode effects (one per awake node)
    send_count = List.count_if(effects, |e|
        when e is
            SendToNode(_) -> Bool.true
            _ -> Bool.false)
    send_count == 2
```

- [ ] **Step 5: Run test**

Run: `roc test packages/graph/shard/ShardState.roc`
Expected: All tests pass including the new one

- [ ] **Step 6: Commit**

```bash
git add packages/graph/shard/ShardState.roc packages/graph/shard/SqDispatch.roc
git commit -m "phase-4d: implement UpdateStandingQueries broadcast from shard to awake nodes"
```

---

## Task 5: SqPartState Serialization (Codec)

**Files:**
- Create: `packages/graph/codec/SqStateCodec.roc`
- Modify: `packages/graph/codec/main.roc`

SQ state must be serialized into `state_bytes : List U8` for NodeSnapshot persistence. Each SqPartState variant gets a tag byte and its fields encoded.

- [ ] **Step 1: Create SqStateCodec.roc with tag constants and encode function**

```roc
# packages/graph/codec/SqStateCodec.roc

module [encode_sq_part_state, decode_sq_part_state]

import standing_state.SqPartState exposing [SqPartState]
import standing_result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]

# Tag bytes for SqPartState variants
tag_unit_state : U8
tag_unit_state = 0x20

tag_cross_state : U8
tag_cross_state = 0x21

tag_local_property_state : U8
tag_local_property_state = 0x22

tag_labels_state : U8
tag_labels_state = 0x23

tag_local_id_state : U8
tag_local_id_state = 0x24

tag_all_properties_state : U8
tag_all_properties_state = 0x25

tag_subscribe_across_edge_state : U8
tag_subscribe_across_edge_state = 0x26

tag_edge_subscription_reciprocal_state : U8
tag_edge_subscription_reciprocal_state = 0x27

tag_filter_map_state : U8
tag_filter_map_state = 0x28

## Encode an SqPartState to bytes for NodeSnapshot persistence.
##
## Each variant is encoded as [tag:U8] followed by variant-specific fields.
## For Phase 4d, we encode the tag + query_part_id for all variants.
## Complex inner state (result accumulators, edge_results dicts) is encoded
## minimally — on wake, the state is rehydrated by re-running initialization
## against current node state, so we only need the structural identity.
encode_sq_part_state : SqPartState -> List U8
encode_sq_part_state = |state|
    when state is
        UnitState ->
            [tag_unit_state]

        CrossState({ query_part_id }) ->
            [tag_cross_state]
            |> List.concat(encode_u64_le(query_part_id))

        LocalPropertyState({ query_part_id }) ->
            [tag_local_property_state]
            |> List.concat(encode_u64_le(query_part_id))

        LabelsState({ query_part_id }) ->
            [tag_labels_state]
            |> List.concat(encode_u64_le(query_part_id))

        LocalIdState({ query_part_id }) ->
            [tag_local_id_state]
            |> List.concat(encode_u64_le(query_part_id))

        AllPropertiesState({ query_part_id }) ->
            [tag_all_properties_state]
            |> List.concat(encode_u64_le(query_part_id))

        SubscribeAcrossEdgeState({ query_part_id }) ->
            [tag_subscribe_across_edge_state]
            |> List.concat(encode_u64_le(query_part_id))

        EdgeSubscriptionReciprocalState({ query_part_id }) ->
            [tag_edge_subscription_reciprocal_state]
            |> List.concat(encode_u64_le(query_part_id))

        FilterMapState({ query_part_id }) ->
            [tag_filter_map_state]
            |> List.concat(encode_u64_le(query_part_id))

## Decode an SqPartState from bytes.
##
## Returns the decoded state and the next byte offset.
## On wake, the decoded state is a skeleton — the dispatch layer re-initializes
## it against current node state to rebuild internal accumulators.
decode_sq_part_state : List U8, U64 -> Result { state : SqPartState, next : U64 } [OutOfBounds, InvalidTag]
decode_sq_part_state = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            if tag == tag_unit_state then
                Ok({ state: UnitState, next: offset + 1 })
            else if tag == tag_cross_state then
                decode_with_part_id(buf, offset + 1, |pid|
                    CrossState({ query_part_id: pid, results_accumulator: Dict.empty({}) }))
            else if tag == tag_local_property_state then
                decode_with_part_id(buf, offset + 1, |pid|
                    LocalPropertyState({ query_part_id: pid, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }))
            else if tag == tag_labels_state then
                decode_with_part_id(buf, offset + 1, |pid|
                    LabelsState({ query_part_id: pid, last_reported_labels: Err(NeverReported), last_report_was_match: Err(NeverReported) }))
            else if tag == tag_local_id_state then
                decode_with_part_id(buf, offset + 1, |pid|
                    LocalIdState({ query_part_id: pid, result: [] }))
            else if tag == tag_all_properties_state then
                decode_with_part_id(buf, offset + 1, |pid|
                    AllPropertiesState({ query_part_id: pid, last_reported_properties: Err(NeverReported) }))
            else if tag == tag_subscribe_across_edge_state then
                decode_with_part_id(buf, offset + 1, |pid|
                    SubscribeAcrossEdgeState({ query_part_id: pid, edge_results: Dict.empty({}) }))
            else if tag == tag_edge_subscription_reciprocal_state then
                decode_with_part_id(buf, offset + 1, |pid|
                    EdgeSubscriptionReciprocalState({ query_part_id: pid, half_edge: { edge_type: "", direction: Outgoing, other: placeholder_qid }, and_then_id: 0, currently_matching: Bool.false, cached_result: Err(NoCachedResult) }))
            else if tag == tag_filter_map_state then
                decode_with_part_id(buf, offset + 1, |pid|
                    FilterMapState({ query_part_id: pid, kept_results: Err(NoCachedResult) }))
            else
                Err(InvalidTag)

## Helper: decode a U64 part_id and apply a constructor.
decode_with_part_id : List U8, U64, (StandingQueryPartId -> SqPartState) -> Result { state : SqPartState, next : U64 } [OutOfBounds, InvalidTag]
decode_with_part_id = |buf, offset, constructor|
    when decode_u64_le(buf, offset) is
        Ok({ val, next }) -> Ok({ state: constructor(val), next })
        Err(_) -> Err(OutOfBounds)

## Encode a U64 in little-endian byte order.
encode_u64_le : U64 -> List U8
encode_u64_le = |n|
    List.range({ start: At(0), end: Before(8) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))

## Decode a U64 from little-endian bytes.
decode_u64_le : List U8, U64 -> Result { val : U64, next : U64 } [OutOfBounds]
decode_u64_le = |buf, offset|
    if offset + 8 > List.len(buf) then
        Err(OutOfBounds)
    else
        val = List.walk(
            List.range({ start: At(0), end: Before(8) }),
            0u64,
            |acc, i|
                byte_offset = offset + i
                when List.get(buf, byte_offset) is
                    Ok(byte) ->
                        shifted : U64
                        shifted = Num.shift_left_by(Num.int_cast(byte), Num.int_cast(i) * 8)
                        Num.bitwise_or(acc, shifted)
                    Err(_) -> acc
        )
        Ok({ val, next: offset + 8 })

# Placeholder QuineId for decoded EdgeSubscriptionReciprocalState.
# The real half_edge is reconstructed during rehydration.
import id.QuineId exposing [QuineId]

placeholder_qid : QuineId
placeholder_qid = QuineId.from_bytes([0])
```

- [ ] **Step 2: Write roundtrip tests**

Add at the bottom of `SqStateCodec.roc`:

```roc
# ===== Tests =====

# UnitState roundtrip
expect
    encoded = encode_sq_part_state(UnitState)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: UnitState }) -> Bool.true
        _ -> Bool.false

# LocalPropertyState roundtrip preserves part_id
expect
    original = LocalPropertyState({ query_part_id: 42u64, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: LocalPropertyState({ query_part_id: 42u64 }) }) -> Bool.true
        _ -> Bool.false

# CrossState roundtrip preserves part_id
expect
    original = CrossState({ query_part_id: 99u64, results_accumulator: Dict.empty({}) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: CrossState({ query_part_id: 99u64 }) }) -> Bool.true
        _ -> Bool.false

# LabelsState roundtrip
expect
    original = LabelsState({ query_part_id: 7u64, last_reported_labels: Err(NeverReported), last_report_was_match: Err(NeverReported) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: LabelsState({ query_part_id: 7u64 }) }) -> Bool.true
        _ -> Bool.false

# LocalIdState roundtrip
expect
    original = LocalIdState({ query_part_id: 55u64, result: [] })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: LocalIdState({ query_part_id: 55u64 }) }) -> Bool.true
        _ -> Bool.false

# AllPropertiesState roundtrip
expect
    original = AllPropertiesState({ query_part_id: 33u64, last_reported_properties: Err(NeverReported) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: AllPropertiesState({ query_part_id: 33u64 }) }) -> Bool.true
        _ -> Bool.false

# SubscribeAcrossEdgeState roundtrip
expect
    original = SubscribeAcrossEdgeState({ query_part_id: 77u64, edge_results: Dict.empty({}) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: SubscribeAcrossEdgeState({ query_part_id: 77u64 }) }) -> Bool.true
        _ -> Bool.false

# FilterMapState roundtrip
expect
    original = FilterMapState({ query_part_id: 11u64, kept_results: Err(NoCachedResult) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: FilterMapState({ query_part_id: 11u64 }) }) -> Bool.true
        _ -> Bool.false

# Invalid tag returns error
expect
    result = decode_sq_part_state([0xFF], 0)
    when result is
        Err(InvalidTag) -> Bool.true
        _ -> Bool.false

# Empty buffer returns OutOfBounds
expect
    result = decode_sq_part_state([], 0)
    when result is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false
```

- [ ] **Step 3: Update codec/main.roc to export SqStateCodec**

Check the current codec `main.roc` exports and add SqStateCodec:

```roc
# packages/graph/codec/main.roc — add SqStateCodec to package exports
package [
    Codec,
    SqStateCodec,
] {
    # ... existing deps ...
    standing_state: "../standing/state/main.roc",
    standing_result: "../standing/result/main.roc",
}
```

Note: The codec package likely already has standing_state and standing_result as dependencies from Phase 4c. Verify and add only if missing.

- [ ] **Step 4: Run tests**

Run: `roc test packages/graph/codec/SqStateCodec.roc`
Expected: All 9 tests pass

- [ ] **Step 5: Commit**

```bash
git add packages/graph/codec/SqStateCodec.roc packages/graph/codec/main.roc
git commit -m "phase-4d: SqPartState encode/decode for NodeSnapshot persistence"
```

---

## Task 6: Wire SQ State into NodeSnapshot Persistence

**Files:**
- Modify: `packages/graph/shard/SleepWake.roc`
- Modify: `packages/graph/shard/main.roc` (add codec dep if needed)

**Current state of SleepWake.roc:**
- `begin_sleep` (line 37): Emits `PersistSnapshot({ id: qid, snapshot_bytes: [] })` — snapshot_bytes are always empty. Full NodeState→bytes serialization is not yet implemented (deferred from Phase 3). Adding SQ state to the snapshot_bytes is blocked on this broader serialization pipeline.
- `complete_wake` (line 90): Restores NodeState from a `NodeSnapshot` but hardcodes `sq_states: Dict.empty({})` and `watchable_event_index: WatchableEventIndex.empty` — SQ state from the snapshot's `sq_snapshot` field is ignored.

**What we do in Phase 4d:**
1. Wire SQ state restoration in `complete_wake` so that when a snapshot *does* contain SQ state, it's decoded.
2. Add a helper `build_sq_snapshot` that serializes a node's SQ states into `List SqStateSnapshot`, ready for when the full snapshot serialization pipeline is built.
3. Do NOT modify `begin_sleep`'s snapshot_bytes — that's a broader change for Phase 5 (when full NodeSnapshot serialization is implemented).

- [ ] **Step 1: Add SqStateCodec import to SleepWake.roc**

In `packages/graph/shard/SleepWake.roc`, add imports:

```roc
import codec.SqStateCodec
import model.NodeSnapshot exposing [NodeSnapshot, SqStateSnapshot]
import types.NodeEntry exposing [SqStateKey, SqNodeState]
import standing_state.SqPartState exposing [SqSubscription]
```

Note: Some of these may already be imported. Add only what's missing. The shard package's `main.roc` must have `codec` as a dependency — verify and add if needed.

- [ ] **Step 2: Add `build_sq_snapshot` helper**

Add a helper function that converts a node's sq_states dict into a list of SqStateSnapshot entries:

```roc
## Serialize a node's SQ states into snapshot entries.
##
## Called during snapshot creation. Each SqPartState is encoded to bytes
## via SqStateCodec. The subscription is not persisted — it will be
## re-established via UpdateStandingQueries on wake.
build_sq_snapshot : Dict SqStateKey SqNodeState -> List SqStateSnapshot
build_sq_snapshot = |sq_states|
    Dict.walk(sq_states, [], |acc, key, sq_node_state|
        state_bytes = SqStateCodec.encode_sq_part_state(sq_node_state.state)
        entry : SqStateSnapshot
        entry = {
            global_id: key.global_id,
            part_id: key.part_id,
            state_bytes,
        }
        List.append(acc, entry)
    )
```

- [ ] **Step 3: Update `complete_wake` to restore SQ state from snapshot**

Replace the hardcoded `sq_states: Dict.empty({})` in `complete_wake` (line 98-105):

```roc
## complete_wake — in the Some(snap) branch:
            Some(snap) ->
                # Restore SQ states from snapshot
                restored_sq_states = List.walk(snap.sq_snapshot, Dict.empty({}), |acc, entry|
                    when SqStateCodec.decode_sq_part_state(entry.state_bytes, 0) is
                        Ok({ state }) ->
                            key : SqStateKey
                            key = { global_id: entry.global_id, part_id: entry.part_id }
                            # Minimal subscription — subscribers re-established
                            # when UpdateStandingQueries runs after wake
                            subscription : SqSubscription
                            subscription = { for_query: entry.part_id, global_id: entry.global_id, subscribers: [] }
                            sq_node_state : SqNodeState
                            sq_node_state = { subscription, state }
                            Dict.insert(acc, key, sq_node_state)
                        Err(_) ->
                            # Corrupted state bytes — skip, will be re-created
                            acc
                )
                # Rebuild WatchableEventIndex from restored SQ states
                # (index is not persisted, reconstructed from state)
                {
                    id: qid,
                    properties: snap.properties,
                    edges: Dict.empty({}),
                    journal: [],
                    snapshot_base: Some(snap),
                    edge_storage: Inline,
                    sq_states: restored_sq_states,
                    watchable_event_index: WatchableEventIndex.empty,
                }
```

Note: WatchableEventIndex reconstruction from restored SQ states (re-registering event subscriptions) is deferred — the empty index means SQ states won't fire until UpdateStandingQueries re-triggers subscriptions. This matches the Scala behavior where nodes re-sync SQ state on wake.

- [ ] **Step 4: Write test for SQ state roundtrip through snapshot**

```roc
expect
    # complete_wake restores SQ states from snapshot's sq_snapshot field
    import codec.SqStateCodec

    qid = QuineId.from_bytes([0x01])
    # Build a snapshot with one SQ state entry
    state_bytes = SqStateCodec.encode_sq_part_state(
        LocalPropertyState({ query_part_id: 42u64, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }))
    sq_entry : SqStateSnapshot
    sq_entry = { global_id: 5u128, part_id: 42u64, state_bytes }
    snapshot : NodeSnapshot
    snapshot = {
        properties: Dict.empty({}),
        edges: [],
        time: AtTime(1000u64),
        sq_snapshot: [sq_entry],
    }
    result = complete_wake(Dict.empty({}), qid, Some(snapshot), 2000u64)
    when Dict.get(result.nodes, qid) is
        Ok(Awake({ state })) ->
            key : SqStateKey
            key = { global_id: 5u128, part_id: 42u64 }
            Dict.contains(state.sq_states, key)
        _ -> Bool.false

expect
    # complete_wake with None snapshot has empty sq_states (unchanged behavior)
    qid = QuineId.from_bytes([0x02])
    result = complete_wake(Dict.empty({}), qid, None, 1000u64)
    when Dict.get(result.nodes, qid) is
        Ok(Awake({ state })) -> Dict.is_empty(state.sq_states)
        _ -> Bool.false

expect
    # build_sq_snapshot serializes SQ states into SqStateSnapshot entries
    import types.NodeEntry exposing [empty_node_state, SqStateKey, SqNodeState]
    import standing_state.SqPartState exposing [SqSubscription]

    key : SqStateKey
    key = { global_id: 7u128, part_id: 99u64 }
    subscription : SqSubscription
    subscription = { for_query: 99u64, global_id: 7u128, subscribers: [] }
    sq_node_state : SqNodeState
    sq_node_state = {
        subscription,
        state: UnitState,
    }
    sq_states = Dict.insert(Dict.empty({}), key, sq_node_state)
    entries = build_sq_snapshot(sq_states)
    List.len(entries) == 1
```

- [ ] **Step 5: Run tests**

Run: `roc test packages/graph/shard/SleepWake.roc`
Expected: All existing tests pass (7 existing + 3 new = 10)

- [ ] **Step 6: Commit**

```bash
git add packages/graph/shard/SleepWake.roc packages/graph/shard/main.roc
git commit -m "phase-4d: restore SQ state from NodeSnapshot on wake, add build_sq_snapshot helper"
```

---

## Task 7: Backpressure Propagation

**Files:**
- Modify: `app/graph-app.roc`
- Modify: `packages/graph/shard/ShardState.roc`

When `EmitSqResult` gets `SqBufferFull` back from the host, the shard should propagate backpressure. The shard already has `backpressure : BackpressureSignal` and `buffer_sq_result` which emits `EmitBackpressure(SqBufferFull)`. The graph-app.roc already handles `EmitBackpressure` by logging.

The missing piece: when the host function returns backpressure (the `Err(SqBufferFull)` path in Task 3), we need to update the shard's backpressure state. But since effects are executed *after* the Roc call returns, the backpressure signal flows back on the *next* dispatch cycle. This is already the correct design — the host logs the backpressure, and the shard's `buffer_sq_result` function (called during the next EmitSqResult effect translation) handles the buffer-full detection on the Roc side.

- [ ] **Step 1: Add `drain_sq_results` to ShardState**

This function allows the host (via app layer) to drain results from the buffer after delivery:

In `packages/graph/shard/ShardState.roc`, add:

```roc
# Add to module exports: drain_sq_results

## Drain all results from the SQ result buffer and return them.
## Clears the buffer and resets backpressure to Clear if it was SqBufferFull.
drain_sq_results : ShardState -> { state : ShardState, results : List StandingQueryResult }
drain_sq_results = |@ShardState(s)|
    results = s.sq_result_buffer
    new_backpressure =
        when s.backpressure is
            SqBufferFull -> Clear
            other -> other
    new_state = @ShardState({ s & sq_result_buffer: [], backpressure: new_backpressure })
    { state: new_state, results }
```

- [ ] **Step 2: Write test for drain_sq_results**

```roc
expect
    # drain_sq_results returns buffered results and clears the buffer
    shard = new(0, 4, default_config)
    result1 : StandingQueryResult
    result1 = { is_positive_match: Bool.true, data: Dict.empty({}) }
    result2 : StandingQueryResult
    result2 = { is_positive_match: Bool.false, data: Dict.empty({}) }
    out1 = buffer_sq_result(shard, result1)
    out2 = buffer_sq_result(out1.state, result2)
    drained = drain_sq_results(out2.state)
    List.len(drained.results) == 2
    && List.is_empty(
        when drained.state is
            @ShardState(s) -> s.sq_result_buffer
    )
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/graph/shard/ShardState.roc`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add packages/graph/shard/ShardState.roc
git commit -m "phase-4d: add drain_sq_results for backpressure management"
```

---

## Task 8: Integration Test — Full SQ Lifecycle Through Dispatch

**Files:**
- Modify: `packages/graph/shard/SqDispatch.roc` (add integration test at bottom)

This test exercises the full Roc-side lifecycle: register SQ on shard, create subscription on node, set property, verify EmitSqResult effect is produced. This is a pure-Roc test (no Rust host needed).

- [ ] **Step 1: Write integration test**

Add to `packages/graph/shard/SqDispatch.roc`:

```roc
# Integration test: register SQ on shard, dispatch to node, verify result
expect
    # Setup: create shard with one awake node
    qid = QuineId.from_bytes([0x01])
    node0 = empty_node_state(qid)

    # Create a LocalProperty SQ watching "status" with Any constraint
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "status", constraint: Any, aliased_as: Ok("s") })
    pid = compute_part_id(query)
    global_id : StandingQueryId
    global_id = 100u128

    # Build lookup function
    lookup = |p| if p == pid then Ok(query) else Err(NotFound)

    # Step 1: Create subscription on the node (simulating what shard broadcast does)
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    create_cmd : SqCommand
    create_cmd = CreateSqSubscription({ subscriber, query, global_id })
    r1 = handle_sq_command(node0, create_cmd, lookup)
    # Node should now have SQ state
    has_state = Dict.len(r1.state.sq_states) == 1

    # Step 2: Set property "status" = "active"
    pv = PropertyValue.from_value(Str("active"))
    events = [PropertySet({ key: "status", value: pv })]
    r2 = dispatch_sq_events(r1.state, events, lookup)

    # Step 3: Verify EmitSqResult
    has_emit = List.any(r2.effects, |e|
        when e is
            EmitSqResult({ query_id: qid_val, result }) ->
                qid_val == global_id && result.is_positive_match
            _ -> Bool.false)

    # Step 4: Change property to different value
    pv2 = PropertyValue.from_value(Str("inactive"))
    events2 = [PropertySet({ key: "status", value: pv2 })]
    r3 = dispatch_sq_events(r2.state, events2, lookup)

    # Should still produce EmitSqResult (value changed but still matches Any)
    has_emit2 = List.any(r3.effects, |e|
        when e is
            EmitSqResult(_) -> Bool.true
            _ -> Bool.false)

    has_state && has_emit && has_emit2
```

- [ ] **Step 2: Run test**

Run: `roc test packages/graph/shard/SqDispatch.roc`
Expected: All tests pass (16 existing + 1 new = 17)

- [ ] **Step 3: Commit**

```bash
git add packages/graph/shard/SqDispatch.roc
git commit -m "phase-4d: integration test for SQ lifecycle through dispatch"
```

---

## Task 9: Smoke Test App

**Files:**
- Create: `app/phase-4-smoke.roc`

A standalone Roc app that exercises the full SQ lifecycle without the Rust host. Uses the same pure-Roc functions but wired together in a test scenario that prints results.

- [ ] **Step 1: Create the smoke test app**

```roc
app [main!]
    { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br",
      id: "../packages/core/id/main.roc",
      model: "../packages/core/model/main.roc",
      shard: "../packages/graph/shard/main.roc",
      types: "../packages/graph/types/main.roc",
      standing_ast: "../packages/graph/standing/ast/main.roc",
      standing_state: "../packages/graph/standing/state/main.roc",
      standing_result: "../packages/graph/standing/result/main.roc" }

import cli.Stdout
import id.QuineId
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import types.NodeEntry exposing [empty_node_state]
import shard.SqDispatch
import standing_ast.MvStandingQuery exposing [MvStandingQuery]
import standing_result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId]
import standing_state.SqPartState exposing [SqMsgSubscriber]
import shard.ShardState

main! = |_args|
    Stdout.line!("=== Phase 4 Standing Query Smoke Test ===")
    Stdout.line!("")

    # Scenario 1: Single-node property match
    Stdout.line!("--- Scenario 1: Single-node property match ---")
    qid = QuineId.from_bytes([0x01, 0x02, 0x03])
    node0 = empty_node_state(qid)

    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    pid = MvStandingQuery.query_part_id(query)
    global_id : StandingQueryId
    global_id = 1u128

    lookup = |p| if p == pid then Ok(query) else Err(NotFound)

    # Create subscription
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    create_result = SqDispatch.handle_sq_command(
        node0,
        CreateSqSubscription({ subscriber, query, global_id }),
        lookup)
    sq_count = Dict.len(create_result.state.sq_states)
    Stdout.line!("  Created subscription: $(Num.to_str(sq_count)) SQ state(s)")
    effects1_count = List.len(create_result.effects)
    Stdout.line!("  Initial effects: $(Num.to_str(effects1_count))")

    # Set property
    pv = PropertyValue.from_value(Str("Alice"))
    events = [PropertySet({ key: "name", value: pv })]
    dispatch_result = SqDispatch.dispatch_sq_events(create_result.state, events, lookup)
    emit_count = List.count_if(dispatch_result.effects, |e|
        when e is
            EmitSqResult(_) -> Bool.true
            _ -> Bool.false)
    Stdout.line!("  After SetProp: $(Num.to_str(emit_count)) EmitSqResult effect(s)")

    if emit_count > 0 then
        Stdout.line!("  PASS: SQ result emitted for property match")
    else
        Stdout.line!("  FAIL: No SQ result emitted")

    Stdout.line!("")
    Stdout.line!("=== Smoke test complete ===")
    Ok({})
```

Note: The exact package URLs and import paths need verification at implementation time. The basic-cli platform URL should match what's used elsewhere in the project. If no basic-cli apps exist, use the latest basic-cli release.

- [ ] **Step 2: Verify it compiles**

Run: `roc check app/phase-4-smoke.roc`
Expected: No errors

- [ ] **Step 3: Run the smoke test**

Run: `roc run app/phase-4-smoke.roc`
Expected output:
```
=== Phase 4 Standing Query Smoke Test ===

--- Scenario 1: Single-node property match ---
  Created subscription: 1 SQ state(s)
  Initial effects: 0
  After SetProp: 1 EmitSqResult effect(s)
  PASS: SQ result emitted for property match

=== Smoke test complete ===
```

- [ ] **Step 4: Commit**

```bash
git add app/phase-4-smoke.roc
git commit -m "phase-4d: smoke test app for standing query lifecycle"
```

---

## Task 10: Full Test Suite Verification and Cleanup

**Files:**
- All modified files from Tasks 1-9

- [ ] **Step 1: Run all Roc tests across the project**

Run all test files to ensure nothing is broken:

```bash
roc test packages/graph/shard/SqDispatch.roc
roc test packages/graph/shard/ShardState.roc
roc test packages/graph/codec/SqStateCodec.roc
roc test packages/graph/codec/Codec.roc
roc test packages/graph/standing/state/SqPartState.roc
roc test packages/graph/standing/index/WatchableEventIndex.roc
roc test packages/graph/standing/result/ResultDiff.roc
roc test packages/graph/standing/ast/MvStandingQuery.roc
```

Expected: All tests pass, zero failures

- [ ] **Step 2: Run the Rust platform build**

```bash
cd platform && cargo build 2>&1
```

Expected: Compiles cleanly

- [ ] **Step 3: Run the smoke test app**

```bash
roc run app/phase-4-smoke.roc
```

Expected: All scenarios pass

- [ ] **Step 4: Update docs/roc-quirks.md if any new quirks were discovered**

If any new Roc compiler quirks were encountered during implementation, document them following the existing format (numbered, with Problem/Workaround/Affected modules/Discovered in sections).

- [ ] **Step 5: Final commit if any cleanup was needed**

```bash
git add -A
git commit -m "phase-4d: test suite verification and cleanup"
```

---

## Task 11: Close Beads and Push

- [ ] **Step 1: Close the Phase 4d beads issue**

```bash
bd close <phase-4d-issue-id> --reason="Phase 4d complete: emit_sq_result host function, UpdateStandingQueries broadcast, SqPartState persistence, backpressure, smoke test"
```

- [ ] **Step 2: Record Phase 4d completion in bd memories**

```bash
bd remember "Phase 4d (platform wiring) complete 2026-04-20. New host function roc_fx_emit_sq_result in Rust, EmitSqResult wired in graph-app.roc. UpdateStandingQueries broadcasts CreateSqSubscription to awake nodes. SqPartState encoded/decoded via SqStateCodec (tag+part_id skeleton, rehydrated on wake). Backpressure via drain_sq_results. Smoke test app at app/phase-4-smoke.roc. Deferred to Phase 5+: full QuineValue serialization in SQ results, cross-shard SQ routing, WatchableEventIndex cleanup on cancel, output sink integration."
```

- [ ] **Step 3: Push to remote**

```bash
git pull --rebase
bd dolt push
git push
git status
```

Expected: `git status` shows "up to date with origin"

---

## Deferred Work (Not in Phase 4d Scope)

| Item | Deferred to | Notes |
|------|-------------|-------|
| Full QuineValue serialization in SQ result payload | Phase 5 | Currently encodes pair count only; Phase 5 query language needs full serialization |
| Cross-shard SQ routing | Phase 5/6 | UpdateStandingQueries only targets awake nodes on local shard |
| WatchableEventIndex cleanup on cancel | Post-4d | handle_cancel_subscription removes sq_states but doesn't unregister from index |
| UpdateStandingQueries shard-to-shard broadcast | Phase 5 | Currently shard-local only |
| Output sink integration (consuming SQ results) | Phase 6 | SQ result channel exists but no consumers |
| SQ state compaction / GC | Post-Phase 4 | |
| EdgeSubscriptionReciprocalState full persistence | Post-4d | Currently persists skeleton only; half_edge needs full serialization |
| CreateSqSubscription codec with full query AST | Phase 5 | Currently uses UnitSq placeholder on decode |
