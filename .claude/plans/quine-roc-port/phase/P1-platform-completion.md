# P1: Platform Completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill the two missing Rust modules (`persistence_io.rs`, `timer.rs`), implement NodeSnapshot serialization in Roc, and wire the sleep/wake cycle to use real snapshots — making `cargo build` succeed and the platform binary runnable.

**Architecture:** Three parallel streams converge: (1) Rust persistence_io receives PersistSnapshot/LoadSnapshot commands over crossbeam, stores in HashMap, returns results via TAG_PERSIST_RESULT; (2) Rust timer spawns tokio intervals sending TAG_TIMER per shard; (3) Roc Codec encodes/decodes NodeSnapshot, SleepWake wires real bytes, graph-app.roc handles persist results to complete wake sequences.

**Tech Stack:** Rust (tokio, crossbeam-channel), Roc (codec/Codec.roc, shard/SleepWake.roc, graph-app.roc)

**Spec:** `.claude/plans/quine-roc-port/refs/specs/prototype-single-host.md` (Phase P1 section)

**Beads issues:** qr-8ty (persistence_io), qr-xt0 (timer), qr-83w (NodeSnapshot codec), qr-7uj (SleepWake wiring), qr-lfi (persist result handling), qr-9co (build verification)

---

## File Map

### Rust (platform/src/)

| File | Action | Responsibility |
|------|--------|---------------|
| `persistence_io.rs` | **Create** | In-memory HashMap persistence pool: receive PersistCommand, store/load snapshots, return TAG_PERSIST_RESULT |
| `timer.rs` | **Create** | Tokio interval tasks: one per shard, sends `[TAG_TIMER, 0x00]` at configured interval |
| `main.rs` | No change | Already references both modules and calls them correctly |
| `roc_glue.rs` | No change | Already imports `persistence_io::PersistCommand` and wires everything |

### Roc (packages/)

| File | Action | Responsibility |
|------|--------|---------------|
| `core/id/EventTime.roc` | **Modify** | Add `to_u64`, `from_u64` exports for codec round-tripping |
| `graph/codec/Codec.roc` | **Modify** | Add `encode_u32`/`decode_u32`, `encode_node_snapshot`/`decode_node_snapshot`, export them |
| `graph/codec/main.roc` | No change | Codec is already exported |
| `graph/shard/SleepWake.roc` | **Modify** | `begin_sleep` → encode real snapshot; add `create_snapshot` helper |
| `graph/shard/ShardState.roc` | **Modify** | Add `complete_node_wake` that transitions Waking→Awake and replays queued messages |
| `app/graph-app.roc` | **Modify** | Handle TAG_PERSIST_RESULT: decode result, call `ShardState.complete_node_wake` |

---

## Task 1: Implement `persistence_io.rs` (qr-8ty)

**Files:**
- Create: `platform/src/persistence_io.rs`

This module provides the `PersistCommand` type (already referenced by `roc_glue.rs`), a request ID generator, and the `start_persistence_pool` function that processes commands on a tokio runtime.

- [ ] **Step 1: Write persistence_io.rs**

```rust
// platform/src/persistence_io.rs

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};

use crossbeam_channel::{Receiver, Sender};

use crate::channels::{ShardMsg, TAG_PERSIST_RESULT};

/// A command sent from a shard worker to the persistence pool.
pub struct PersistCommand {
    pub request_id: u64,
    pub shard_id: u32,
    pub payload: Vec<u8>,
}

/// Global atomic counter for generating unique request IDs.
static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(1);

/// Generate a monotonically increasing request ID.
pub fn next_request_id() -> u64 {
    REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// Start the in-memory persistence pool.
///
/// Receives PersistCommands on a crossbeam channel, stores/loads snapshots
/// in a HashMap, and sends results back to the requesting shard.
///
/// Returns the command sender for callers to submit persist operations.
pub fn start_persistence_pool(
    shard_senders: Vec<Sender<ShardMsg>>,
    rt: &tokio::runtime::Runtime,
) -> Sender<PersistCommand> {
    let (cmd_tx, cmd_rx) = crossbeam_channel::bounded::<PersistCommand>(4096);

    rt.spawn(async move {
        run_persistence_loop(cmd_rx, shard_senders);
    });

    cmd_tx
}

/// The persistence loop: blocks on the command receiver, processes each command.
fn run_persistence_loop(
    cmd_rx: Receiver<PersistCommand>,
    shard_senders: Vec<Sender<ShardMsg>>,
) {
    let mut store: HashMap<Vec<u8>, Vec<u8>> = HashMap::new();

    loop {
        match cmd_rx.recv() {
            Ok(cmd) => process_command(&mut store, &shard_senders, cmd),
            Err(_) => {
                eprintln!("persistence pool: command channel closed, shutting down");
                break;
            }
        }
    }
}

/// Process a single persist command.
///
/// Wire format (from Roc encode_persist_command):
///   PersistSnapshot: [0x01][id_len:U16LE][id_bytes...][snapshot_bytes...]
///   LoadSnapshot:    [0x02][id_len:U16LE][id_bytes...]
fn process_command(
    store: &mut HashMap<Vec<u8>, Vec<u8>>,
    shard_senders: &[Sender<ShardMsg>],
    cmd: PersistCommand,
) {
    if cmd.payload.is_empty() {
        eprintln!("persistence pool: empty payload, ignoring");
        return;
    }

    match cmd.payload[0] {
        0x01 => handle_persist_snapshot(store, &cmd.payload),
        0x02 => handle_load_snapshot(store, shard_senders, cmd.shard_id, &cmd.payload),
        tag => {
            eprintln!("persistence pool: unknown command tag 0x{:02X}", tag);
        }
    }
}

/// PersistSnapshot: parse QuineId, store snapshot bytes.
fn handle_persist_snapshot(store: &mut HashMap<Vec<u8>, Vec<u8>>, payload: &[u8]) {
    // payload: [0x01][id_len:U16LE][id_bytes...][snapshot_bytes...]
    if payload.len() < 3 {
        eprintln!("persistence pool: PersistSnapshot payload too short");
        return;
    }
    let id_len = u16::from_le_bytes([payload[1], payload[2]]) as usize;
    let id_end = 3 + id_len;
    if payload.len() < id_end {
        eprintln!("persistence pool: PersistSnapshot truncated id");
        return;
    }
    let id_bytes = &payload[3..id_end];
    let snapshot_bytes = &payload[id_end..];

    store.insert(id_bytes.to_vec(), snapshot_bytes.to_vec());
}

/// LoadSnapshot: look up QuineId, send result back to requesting shard.
///
/// Result format sent to shard channel:
///   Found:     [TAG_PERSIST_RESULT][0x01][id_len:U16LE][id_bytes...][snap_len:U32LE][snapshot_bytes...]
///   Not found: [TAG_PERSIST_RESULT][0x00][id_len:U16LE][id_bytes...]
fn handle_load_snapshot(
    store: &HashMap<Vec<u8>, Vec<u8>>,
    shard_senders: &[Sender<ShardMsg>],
    shard_id: u32,
    payload: &[u8],
) {
    // payload: [0x02][id_len:U16LE][id_bytes...]
    if payload.len() < 3 {
        eprintln!("persistence pool: LoadSnapshot payload too short");
        return;
    }
    let id_len = u16::from_le_bytes([payload[1], payload[2]]) as usize;
    let id_end = 3 + id_len;
    if payload.len() < id_end {
        eprintln!("persistence pool: LoadSnapshot truncated id");
        return;
    }
    let id_bytes = &payload[3..id_end];

    let result_msg = match store.get(id_bytes) {
        Some(snapshot) => {
            // Found: [TAG][0x01][id_len:U16LE][id...][snap_len:U32LE][snap...]
            let snap_len = snapshot.len() as u32;
            let mut msg = Vec::with_capacity(1 + 1 + 2 + id_len + 4 + snapshot.len());
            msg.push(TAG_PERSIST_RESULT);
            msg.push(0x01); // found
            msg.extend_from_slice(&(id_len as u16).to_le_bytes());
            msg.extend_from_slice(id_bytes);
            msg.extend_from_slice(&snap_len.to_le_bytes());
            msg.extend_from_slice(snapshot);
            msg
        }
        None => {
            // Not found: [TAG][0x00][id_len:U16LE][id...]
            let mut msg = Vec::with_capacity(1 + 1 + 2 + id_len);
            msg.push(TAG_PERSIST_RESULT);
            msg.push(0x00); // not found
            msg.extend_from_slice(&(id_len as u16).to_le_bytes());
            msg.extend_from_slice(id_bytes);
            msg
        }
    };

    if let Some(sender) = shard_senders.get(shard_id as usize) {
        if sender.send(result_msg).is_err() {
            eprintln!(
                "persistence pool: failed to send result to shard {}",
                shard_id
            );
        }
    } else {
        eprintln!("persistence pool: invalid shard_id {}", shard_id);
    }
}
```

- [ ] **Step 2: Verify cargo build compiles persistence_io**

Run: `cd platform && cargo check 2>&1 | head -20`
Expected: Will still fail due to missing `timer.rs`, but `persistence_io.rs` errors should be gone. Look for errors in `persistence_io` specifically — there should be none.

- [ ] **Step 3: Commit**

```bash
git add platform/src/persistence_io.rs
git commit -m "P1: implement persistence_io.rs — in-memory HashMap persistence pool"
```

---

## Task 2: Implement `timer.rs` (qr-xt0)

**Files:**
- Create: `platform/src/timer.rs`

- [ ] **Step 1: Write timer.rs**

```rust
// platform/src/timer.rs

use crossbeam_channel::Sender;
use crate::channels::{ShardMsg, TAG_TIMER};

/// Start LRU check timers for all shards.
///
/// Creates a single-threaded tokio runtime. For each shard, spawns an
/// interval task that sends [TAG_TIMER, 0x00] (CheckLru) to the shard's
/// channel at the configured interval.
///
/// Returns the tokio Runtime. Caller must keep it alive — dropping stops all timers.
pub fn start_lru_timers(
    senders: Vec<Sender<ShardMsg>>,
    interval_ms: u64,
) -> tokio::runtime::Runtime {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime for timers");

    for (shard_id, sender) in senders.into_iter().enumerate() {
        rt.spawn(timer_task(shard_id, sender, interval_ms));
    }

    rt
}

/// A single timer task: ticks at `interval_ms` and sends TAG_TIMER to the shard.
async fn timer_task(shard_id: usize, sender: Sender<ShardMsg>, interval_ms: u64) {
    let mut interval = tokio::time::interval(std::time::Duration::from_millis(interval_ms));

    // The first tick completes immediately — skip it so the first real
    // timer fires after one full interval.
    interval.tick().await;

    loop {
        interval.tick().await;
        // 0x00 = CheckLru timer kind
        let msg = vec![TAG_TIMER, 0x00];
        if sender.send(msg).is_err() {
            eprintln!("timer: shard {} channel closed, stopping timer", shard_id);
            break;
        }
    }
}
```

- [ ] **Step 2: Verify cargo build compiles both new modules**

Run: `cd platform && cargo check 2>&1 | head -20`
Expected: No Rust compilation errors. May still have linker errors (missing Roc symbols) which is expected without a Roc app linked.

- [ ] **Step 3: Commit**

```bash
git add platform/src/timer.rs
git commit -m "P1: implement timer.rs — tokio interval LRU check timers"
```

---

## Task 3: Add U32 codec primitives and EventTime serialization helpers (qr-83w prep)

**Files:**
- Modify: `packages/core/id/EventTime.roc` (add `to_u64`, `from_u64`)
- Modify: `packages/graph/codec/Codec.roc` (add `encode_u32`, `decode_u32`)

EventTime is an opaque `U64`. The codec needs to read/write the packed value directly. Adding `to_u64`/`from_u64` avoids re-deriving the bit packing.

- [ ] **Step 1: Add `to_u64` and `from_u64` to EventTime.roc**

Add to the module export list: `to_u64, from_u64`

Add the functions:

```roc
## Extract the raw packed U64 (for codec serialization).
to_u64 : EventTime -> U64
to_u64 = |@EventTime(packed)| packed

## Construct from a raw packed U64 (for codec deserialization).
from_u64 : U64 -> EventTime
from_u64 = |packed| @EventTime(packed)
```

Add roundtrip test:

```roc
expect
    et = from_parts({ millis: 1000, message_seq: 5, event_seq: 3 })
    to_u64(et) |> from_u64 == et
```

- [ ] **Step 2: Add `encode_u32` and `decode_u32` to Codec.roc**

Add to the module export list: `encode_u32, decode_u32` (alongside existing `encode_node_msg, decode_node_msg, encode_shard_envelope, decode_shard_envelope`).

Add the functions (place after `decode_u16` and before `encode_u64`):

```roc
## Encode a U32 in little-endian byte order.
encode_u32 : U32 -> List U8
encode_u32 = |n|
    List.range({ start: At(0), end: Before(4) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))

## Decode a U32 from little-endian bytes at the given offset.
decode_u32 : List U8, U64 -> Result { val : U32, next : U64 } [OutOfBounds]
decode_u32 = |buf, offset|
    if offset + 4 > List.len(buf) then
        Err(OutOfBounds)
    else
        val = List.walk(
            List.range({ start: At(0u64), end: Before(4u64) }),
            0u32,
            |acc, i|
                when List.get(buf, offset + i) is
                    Ok(b) ->
                        shifted : U32
                        shifted = Num.shift_left_by(Num.int_cast(b), Num.int_cast(i) * 8)
                        Num.bitwise_or(acc, shifted)
                    Err(_) -> acc,
        )
        Ok({ val, next: offset + 4 })
```

Add tests at the end of the test section:

```roc
# -- U32 roundtrip --
expect
    encoded = encode_u32(0)
    when decode_u32(encoded, 0) is
        Ok({ val: 0, next: 4 }) -> Bool.true
        _ -> Bool.false

expect
    encoded = encode_u32(0xDEADBEEF)
    when decode_u32(encoded, 0) is
        Ok({ val, next: 4 }) -> val == 0xDEADBEEF
        _ -> Bool.false

expect
    when decode_u32([0x01], 0) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false
```

- [ ] **Step 3: Run Roc tests to verify**

Run: `roc test packages/core/id/EventTime.roc && roc test packages/graph/codec/Codec.roc`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add packages/core/id/EventTime.roc packages/graph/codec/Codec.roc
git commit -m "P1: add U32 codec primitives and EventTime to_u64/from_u64"
```

---

## Task 4: Implement `encode_node_snapshot` / `decode_node_snapshot` (qr-83w)

**Files:**
- Modify: `packages/graph/codec/Codec.roc` (add encode/decode functions and exports)

The NodeSnapshot encoding format composes existing PropertyValue, HalfEdge, and SqStateCodec encoders:

```
[prop_count:U32LE]
  repeated: [key_len:U16LE][key_bytes...][value_bytes (PropertyValue encoding)]
[edge_count:U32LE]
  repeated: [half_edge_bytes (HalfEdge encoding)]
[time_tag:U8][time_value:U64LE]  (0x00=NotSet, 0x01=AtTime)
[sq_count:U32LE]
  repeated: [global_id:U128LE][part_id:U64LE][state_len:U32LE][state_bytes...]
```

- [ ] **Step 1: Add imports for NodeSnapshot and EventTime**

Add to the import block in Codec.roc:

```roc
import model.NodeSnapshot exposing [NodeSnapshot, SqStateSnapshot]
import id.EventTime
```

- [ ] **Step 2: Add `encode_node_snapshot` to Codec.roc**

Add to the module export list: `encode_node_snapshot, decode_node_snapshot`

```roc
## Encode a NodeSnapshot to bytes.
## Format: [props...][edges...][time...][sq_snapshot...]
encode_node_snapshot : NodeSnapshot -> List U8
encode_node_snapshot = |snap|
    # Properties: [count:U32LE] then [key:str][value:PropertyValue]...
    props_list = Dict.to_list(snap.properties)
    prop_count : U32
    prop_count = Num.int_cast(List.len(props_list))
    props_bytes = List.walk(props_list, encode_u32(prop_count), |acc, (key, val)|
        acc
        |> List.concat(encode_str(key))
        |> List.concat(encode_property_value(val)))

    # Edges: [count:U32LE] then [half_edge_bytes]...
    edge_count : U32
    edge_count = Num.int_cast(List.len(snap.edges))
    edges_bytes = List.walk(snap.edges, encode_u32(edge_count), |acc, edge|
        List.concat(acc, encode_half_edge(edge)))

    # Time: [tag:U8][value:U64LE] — 0x01=AtTime always for snapshots
    time_raw = EventTime.to_u64(snap.time)
    time_bytes = [0x01] |> List.concat(encode_u64(time_raw))

    # SQ snapshot: [count:U32LE] then [global_id:U128][part_id:U64][state_len:U32][state_bytes]...
    sq_count : U32
    sq_count = Num.int_cast(List.len(snap.sq_snapshot))
    sq_bytes = List.walk(snap.sq_snapshot, encode_u32(sq_count), |acc, entry|
        state_len : U32
        state_len = Num.int_cast(List.len(entry.state_bytes))
        acc
        |> List.concat(encode_u128(entry.global_id))
        |> List.concat(encode_u64(entry.part_id))
        |> List.concat(encode_u32(state_len))
        |> List.concat(entry.state_bytes))

    props_bytes
    |> List.concat(edges_bytes)
    |> List.concat(time_bytes)
    |> List.concat(sq_bytes)
```

- [ ] **Step 3: Add `decode_node_snapshot` to Codec.roc**

```roc
## Decode a NodeSnapshot from the buffer at the given offset.
decode_node_snapshot : List U8, U64 -> Result { snapshot : NodeSnapshot, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_node_snapshot = |buf, offset|
    when decode_u32(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok({ val: prop_count_u32, next: props_start }) ->
            prop_count = Num.int_cast(prop_count_u32)
            when decode_properties(buf, props_start, prop_count, Dict.empty({})) is
                Err(e) -> Err(e)
                Ok({ val: properties, next: edges_count_start }) ->
                    when decode_u32(buf, edges_count_start) is
                        Err(_) -> Err(OutOfBounds)
                        Ok({ val: edge_count_u32, next: edges_start }) ->
                            edge_count = Num.int_cast(edge_count_u32)
                            when decode_edges(buf, edges_start, edge_count, []) is
                                Err(e) -> Err(e)
                                Ok({ val: edges, next: time_start }) ->
                                    when decode_event_time(buf, time_start) is
                                        Err(e) -> Err(e)
                                        Ok({ val: time, next: sq_count_start }) ->
                                            when decode_u32(buf, sq_count_start) is
                                                Err(_) -> Err(OutOfBounds)
                                                Ok({ val: sq_count_u32, next: sq_start }) ->
                                                    sq_count = Num.int_cast(sq_count_u32)
                                                    when decode_sq_snapshots(buf, sq_start, sq_count, []) is
                                                        Err(e) -> Err(e)
                                                        Ok({ val: sq_snapshot, next: final_next }) ->
                                                            Ok({
                                                                snapshot: { properties, edges, time, sq_snapshot },
                                                                next: final_next,
                                                            })

## Decode N properties from the buffer.
decode_properties : List U8, U64, U64, Dict Str PropertyValue -> Result { val : Dict Str PropertyValue, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_properties = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_str(buf, offset) is
            Err(OutOfBounds) -> Err(OutOfBounds)
            Err(BadUtf8) -> Err(BadUtf8)
            Ok({ val: key, next: val_start }) ->
                when decode_property_value(buf, val_start) is
                    Err(e) -> Err(e)
                    Ok({ val: pv, next: next_offset }) ->
                        decode_properties(buf, next_offset, remaining - 1, Dict.insert(acc, key, pv))

## Decode N HalfEdges from the buffer.
decode_edges : List U8, U64, U64, List HalfEdge -> Result { val : List HalfEdge, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_edges = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_half_edge(buf, offset) is
            Err(OutOfBounds) -> Err(OutOfBounds)
            Err(BadUtf8) -> Err(BadUtf8)
            Err(InvalidDirection) -> Err(InvalidDirection)
            Ok({ val: edge, next: next_offset }) ->
                decode_edges(buf, next_offset, remaining - 1, List.append(acc, edge))

## Decode an EventTime from the buffer (tag + optional U64).
decode_event_time : List U8, U64 -> Result { val : EventTime, next : U64 } [OutOfBounds, InvalidTag, BadUtf8, InvalidDirection]
decode_event_time = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            if tag == 0x00 then
                Ok({ val: EventTime.min_value, next: offset + 1 })
            else if tag == 0x01 then
                when decode_u64(buf, offset + 1) is
                    Ok({ val: raw, next }) -> Ok({ val: EventTime.from_u64(raw), next })
                    Err(e) -> Err(e)
            else
                Err(InvalidTag)

## Decode N SqStateSnapshot entries from the buffer.
decode_sq_snapshots : List U8, U64, U64, List SqStateSnapshot -> Result { val : List SqStateSnapshot, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_sq_snapshots = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_u128(buf, offset) is
            Err(e) -> Err(e)
            Ok({ val: global_id, next: pid_start }) ->
                when decode_u64(buf, pid_start) is
                    Err(e) -> Err(e)
                    Ok({ val: part_id, next: slen_start }) ->
                        when decode_u32(buf, slen_start) is
                            Err(_) -> Err(OutOfBounds)
                            Ok({ val: state_len_u32, next: state_start }) ->
                                state_len = Num.int_cast(state_len_u32)
                                state_bytes = List.sublist(buf, { start: state_start, len: state_len })
                                if List.len(state_bytes) == state_len then
                                    entry : SqStateSnapshot
                                    entry = { global_id, part_id, state_bytes }
                                    decode_sq_snapshots(buf, state_start + state_len, remaining - 1, List.append(acc, entry))
                                else
                                    Err(OutOfBounds)
```

- [ ] **Step 4: Add roundtrip tests**

Add at the end of Codec.roc tests:

```roc
# ===== NodeSnapshot Tests =====

# -- Empty snapshot roundtrip --
expect
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}),
        edges: [],
        time: EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 }),
        sq_snapshot: [],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            Dict.is_empty(snapshot.properties)
            and List.is_empty(snapshot.edges)
            and snapshot.time == EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
            and List.is_empty(snapshot.sq_snapshot)
        _ -> Bool.false

# -- Snapshot with properties --
expect
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}) |> Dict.insert("name", Deserialized(Str("Alice"))) |> Dict.insert("age", Deserialized(Integer(30))),
        edges: [],
        time: EventTime.from_parts({ millis: 2000, message_seq: 1, event_seq: 0 }),
        sq_snapshot: [],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            Dict.len(snapshot.properties) == 2
        _ -> Bool.false

# -- Snapshot with edges --
expect
    edge1 = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x01]) }
    edge2 = { edge_type: "FOLLOWS", direction: Incoming, other: QuineId.from_bytes([0x02]) }
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}),
        edges: [edge1, edge2],
        time: EventTime.from_parts({ millis: 3000, message_seq: 0, event_seq: 0 }),
        sq_snapshot: [],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            List.len(snapshot.edges) == 2
        _ -> Bool.false

# -- Snapshot with SQ state entries --
expect
    sq_entry : SqStateSnapshot
    sq_entry = { global_id: 42u128, part_id: 7u64, state_bytes: [0x20] }
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}),
        edges: [],
        time: EventTime.from_parts({ millis: 4000, message_seq: 0, event_seq: 0 }),
        sq_snapshot: [sq_entry],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            List.len(snapshot.sq_snapshot) == 1
            and (
                when List.get(snapshot.sq_snapshot, 0) is
                    Ok(entry) -> entry.global_id == 42u128 and entry.part_id == 7u64 and entry.state_bytes == [0x20]
                    _ -> Bool.false
            )
        _ -> Bool.false

# -- Full snapshot roundtrip --
expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0xAB]) }
    sq_entry : SqStateSnapshot
    sq_entry = { global_id: 100u128, part_id: 50u64, state_bytes: [0x22, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] }
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}) |> Dict.insert("x", Deserialized(Integer(99))),
        edges: [edge],
        time: EventTime.from_parts({ millis: 5000, message_seq: 2, event_seq: 1 }),
        sq_snapshot: [sq_entry],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            Dict.len(snapshot.properties) == 1
            and List.len(snapshot.edges) == 1
            and snapshot.time == EventTime.from_parts({ millis: 5000, message_seq: 2, event_seq: 1 })
            and List.len(snapshot.sq_snapshot) == 1
        _ -> Bool.false
```

- [ ] **Step 5: Run Roc tests**

Run: `roc test packages/graph/codec/Codec.roc`
Expected: All tests pass (existing + new).

- [ ] **Step 6: Commit**

```bash
git add packages/graph/codec/Codec.roc
git commit -m "P1: implement encode_node_snapshot / decode_node_snapshot in Codec.roc"
```

---

## Task 5: Wire `begin_sleep` to encode real snapshots (qr-7uj)

**Files:**
- Modify: `packages/graph/shard/SleepWake.roc`

Currently `begin_sleep` sends `snapshot_bytes: []`. We need to:
1. Add a `create_snapshot` helper that converts the node's live state into a `NodeSnapshot`
2. Encode it via `Codec.encode_node_snapshot`
3. Pass real bytes in the `PersistSnapshot` effect

- [ ] **Step 1: Add Codec and EventTime imports to SleepWake.roc**

Add to imports:

```roc
import codec.Codec
```

Note: EventTime is already importable through `id.EventTime` — check if it's already imported. We need `EventTime.from_parts`.

- [ ] **Step 2: Add `create_snapshot` helper to SleepWake.roc**

```roc
## Create a NodeSnapshot from a node's live state for persistence.
##
## Flattens the edge Dict (edge_type → List HalfEdge) into a single List HalfEdge,
## serializes SQ states, and stamps with the current time.
create_snapshot : NodeEntry.NodeState, U64 -> NodeSnapshot
create_snapshot = |state, now|
    flat_edges = Dict.walk(state.edges, [], |acc, _edge_type, edge_list|
        List.concat(acc, edge_list))
    sq_snap = build_sq_snapshot(state.sq_states)
    time = EventTime.from_parts({ millis: now, message_seq: 0, event_seq: 0 })
    { properties: state.properties, edges: flat_edges, time, sq_snapshot: sq_snap }
```

Also add the import at the top if not present: `import types.NodeEntry` — note: `NodeEntry` module is already imported for the `NodeEntry` type. We just need `NodeState` from it. Check the existing import: `import types.NodeEntry exposing [NodeEntry, WakefulState, SqStateKey, SqNodeState, empty_node_state, compute_cost_to_sleep]`. We need to add `NodeState` to the exposing list.

Update the import line to:
```roc
import types.NodeEntry exposing [NodeEntry, NodeState, WakefulState, SqStateKey, SqNodeState, empty_node_state, compute_cost_to_sleep]
```

- [ ] **Step 3: Change `begin_sleep` to encode real snapshot bytes**

Replace the line:
```roc
persist_effect = Persist({ command: PersistSnapshot({ id: qid, snapshot_bytes: [] }) })
```

With:
```roc
snapshot = create_snapshot(state, now)
snapshot_bytes = Codec.encode_node_snapshot(snapshot)
persist_effect = Persist({ command: PersistSnapshot({ id: qid, snapshot_bytes }) })
```

- [ ] **Step 4: Add test for create_snapshot**

```roc
expect
    # create_snapshot flattens edges and builds SQ snapshot
    qid = QuineId.from_bytes([0x01])
    pv = PropertyValue.from_value(Str("test"))
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x02]) }
    ns = {
        id: qid,
        properties: Dict.empty({}) |> Dict.insert("name", pv),
        edges: Dict.empty({}) |> Dict.insert("KNOWS", [edge]),
        journal: [],
        snapshot_base: None,
        edge_storage: Inline,
        sq_states: Dict.empty({}),
        watchable_event_index: WatchableEventIndex.empty,
    }
    snap = create_snapshot(ns, 5000)
    Dict.len(snap.properties) == 1
    and List.len(snap.edges) == 1
    and List.is_empty(snap.sq_snapshot)
```

- [ ] **Step 5: Add test for begin_sleep producing non-empty snapshot bytes**

```roc
expect
    # begin_sleep on eligible node produces non-empty snapshot_bytes
    config = {
        soft_limit: 10_000u32,
        hard_limit: 50_000u32,
        lru_check_interval_ms: 10_000u64,
        ask_timeout_ms: 5_000u64,
        decline_sleep_when_write_within_ms: 100u64,
        decline_sleep_when_access_within_ms: 0u64,
        sleep_deadline_ms: 3_000u64,
        max_edges_warning_threshold: 100_000u64,
    }
    qid = QuineId.from_bytes([0x01])
    pv = PropertyValue.from_value(Str("hello"))
    ns = { (empty_node_state(qid)) & properties: Dict.empty({}) |> Dict.insert("key", pv) }
    entry = Awake({
        state: ns,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: 500u64,
        last_access: 500u64,
    })
    nodes = Dict.insert(Dict.empty({}), qid, entry)
    result = begin_sleep(nodes, qid, 1000u64, config)
    # Check that the Persist effect has non-empty snapshot_bytes
    List.any(result.effects, |e|
        when e is
            Persist({ command: PersistSnapshot({ snapshot_bytes }) }) -> !(List.is_empty(snapshot_bytes))
            _ -> Bool.false)
```

- [ ] **Step 6: Run Roc tests**

Run: `roc test packages/graph/shard/SleepWake.roc`
Expected: All tests pass (existing + new).

- [ ] **Step 7: Commit**

```bash
git add packages/graph/shard/SleepWake.roc
git commit -m "P1: wire begin_sleep to encode real NodeSnapshot bytes"
```

---

## Task 6: Add `complete_node_wake` to ShardState (qr-lfi prep)

**Files:**
- Modify: `packages/graph/shard/ShardState.roc`

When a persist result arrives (LoadSnapshot response), the shard needs to:
1. Find the Waking entry for the target node
2. Call `SleepWake.complete_wake` to restore the Awake entry from the snapshot
3. Replay the queued messages that arrived while the node was Waking

- [ ] **Step 1: Add `complete_node_wake` to the module export list**

Add `complete_node_wake` to the `module [...]` list in ShardState.roc.

- [ ] **Step 2: Implement `complete_node_wake`**

Add after the `on_timer` function:

```roc
## Complete a node's wake sequence after its snapshot has been loaded.
##
## If the node is currently Waking, transitions it to Awake using the
## provided snapshot, then dispatches all queued messages that arrived
## while the node was sleeping.
##
## If the node is not in Waking state (e.g., it was already awake due to
## a race), the snapshot is discarded and the state is returned unchanged.
complete_node_wake : ShardState, QuineId, [None, Some NodeSnapshot], U64 -> ShardState
complete_node_wake = |@ShardState(s), qid, maybe_snapshot, now|
    when Dict.get(s.nodes, qid) is
        Ok(Waking({ queued })) ->
            wake_result = SleepWake.complete_wake(s.nodes, qid, maybe_snapshot, now)
            # Replay queued messages through the now-awake node
            lookup_fn = |pid| Dict.get(s.part_index, pid) |> Result.map_err(|_| NotFound)
            { final_nodes, all_effects } = List.walk(
                queued,
                { final_nodes: wake_result.nodes, all_effects: wake_result.effects },
                |acc, msg|
                    when Dict.get(acc.final_nodes, qid) is
                        Ok(Awake({ state, wakeful, cost_to_sleep: _, last_write, last_access: _ })) ->
                            result = Dispatch.dispatch_node_msg(state, msg, lookup_fn)
                            new_cost = compute_cost_to_sleep(result.state)
                            new_entry = Awake({
                                state: result.state,
                                wakeful,
                                cost_to_sleep: new_cost,
                                last_write,
                                last_access: now,
                            })
                            {
                                final_nodes: Dict.insert(acc.final_nodes, qid, new_entry),
                                all_effects: List.concat(acc.all_effects, result.effects),
                            }
                        _ -> acc,
            )
            new_lru = Lru.touch(s.lru_entries, qid, now, 0)
            @ShardState({ s &
                nodes: final_nodes,
                lru_entries: new_lru,
                pending_effects: all_effects,
            })

        _ ->
            # Not in Waking state — discard snapshot, no effects
            @ShardState({ s & pending_effects: [] })
```

- [ ] **Step 3: Add imports needed for complete_node_wake**

Ensure these are imported in ShardState.roc (check which are already present):
- `import model.NodeSnapshot exposing [NodeSnapshot]` — needed for the type annotation
- `Dispatch` is already imported (used in handle_message)
- `Lru` is already imported
- `SleepWake` is already imported
- `compute_cost_to_sleep` is already imported from `types.NodeEntry`

- [ ] **Step 4: Add test for complete_node_wake**

Add at the end of the ShardState.roc tests section (locate the `# ===== Tests =====` section or add after existing tests):

```roc
expect
    # complete_node_wake transitions Waking to Awake and replays queued SetProp
    config = default_config
    shard = new(0u32, 4u32, config)
    qid = QuineId.from_bytes([0x01])
    # Set up a Waking entry with one queued SetProp message
    pv = PropertyValue.from_value(Str("hello"))
    queued_msg : NodeMessage
    queued_msg = LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 0 }))
    waking_entry : NodeEntry
    waking_entry = Waking({ queued: [queued_msg] })
    shard2 = with_awake_node(shard, qid, waking_entry)
    # Complete wake with no snapshot (new node)
    shard3 = complete_node_wake(shard2, qid, None, 1000u64)
    # Node should be Awake with the SetProp applied
    when node_entry(shard3, qid) is
        Ok(Awake({ state })) ->
            when Dict.get(state.properties, "name") is
                Ok(_) -> Bool.true
                Err(_) -> Bool.false
        _ -> Bool.false

expect
    # complete_node_wake on non-Waking node returns unchanged state
    config = default_config
    shard = new(0u32, 4u32, config)
    qid = QuineId.from_bytes([0x02])
    shard2 = complete_node_wake(shard, qid, None, 1000u64)
    # Should have no entry for this node
    when node_entry(shard2, qid) is
        Err(_) -> Bool.true
        _ -> Bool.false
```

- [ ] **Step 5: Run Roc tests**

Run: `roc test packages/graph/shard/ShardState.roc`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add packages/graph/shard/ShardState.roc
git commit -m "P1: add complete_node_wake to ShardState — transitions Waking→Awake with replay"
```

---

## Task 7: Handle TAG_PERSIST_RESULT in graph-app.roc (qr-lfi)

**Files:**
- Modify: `app/graph-app.roc`

Currently, graph-app.roc logs and ignores TAG_PERSIST_RESULT. We need to:
1. Decode the persist result payload (found/not_found, QuineId, snapshot bytes)
2. If found, decode the snapshot bytes into a NodeSnapshot
3. Call `ShardState.complete_node_wake`

- [ ] **Step 1: Add NodeSnapshot import**

Add to the import block:
```roc
import model.NodeSnapshot exposing [NodeSnapshot]
```

Wait — graph-app.roc imports packages, not sub-modules directly. Looking at the existing imports:
```roc
import codec.Codec
import shard.ShardState
```

The `model` package isn't declared in graph-app.roc's package list. Check if `NodeSnapshot` can be accessed through existing imports. Looking at the app header, it has `types: "../packages/graph/types/main.roc"`. The `NodeSnapshot` type is in `packages/core/model/NodeSnapshot.roc`. We need to add a package reference.

Add to the app header's package list:
```roc
model: "../packages/core/model/main.roc",
```

Then import:
```roc
import model.NodeSnapshot exposing [NodeSnapshot]
```

- [ ] **Step 2: Replace the TAG_PERSIST_RESULT handler**

Replace:
```roc
            else if tag == tag_persist_result then
                Effect.log!(3, "graph-app: persist result received ($(Num.to_str(List.len(msg))) bytes)")
                state
```

With:
```roc
            else if tag == tag_persist_result then
                handle_persist_result!(state, msg)
```

- [ ] **Step 3: Add `handle_persist_result!` function**

```roc
## Handle a persistence result: decode the response and complete node wake.
##
## Persist result format (from persistence_io.rs):
##   Found:     [TAG_PERSIST_RESULT][0x01][id_len:U16LE][id_bytes...][snap_len:U32LE][snapshot_bytes...]
##   Not found: [TAG_PERSIST_RESULT][0x00][id_len:U16LE][id_bytes...]
handle_persist_result! : ShardState, List U8 => ShardState
handle_persist_result! = |state, msg|
    # msg[0] = TAG_PERSIST_RESULT (already matched)
    # msg[1] = found flag (0x00 or 0x01)
    when List.get(msg, 1) is
        Err(_) ->
            Effect.log!(1, "graph-app: persist result too short")
            state
        Ok(found_flag) ->
            # Decode id_len (U16LE at offset 2)
            when (List.get(msg, 2), List.get(msg, 3)) is
                (Ok(lo), Ok(hi)) ->
                    id_len = Num.int_cast(lo) |> Num.add(Num.shift_left_by(Num.int_cast(hi), 8))
                    id_bytes = List.sublist(msg, { start: 4, len: id_len })
                    if List.len(id_bytes) != id_len then
                        Effect.log!(1, "graph-app: persist result truncated id")
                        state
                    else
                        qid = QuineId.from_bytes(id_bytes)
                        now = Effect.current_time!({})
                        if found_flag == 0x01 then
                            # Found: decode snapshot_len (U32LE) then snapshot_bytes
                            snap_len_start = 4 + id_len
                            when decode_u32_at(msg, snap_len_start) is
                                Err(_) ->
                                    Effect.log!(1, "graph-app: persist result truncated snap_len")
                                    state
                                Ok(snap_len) ->
                                    snap_start = snap_len_start + 4
                                    snapshot_bytes = List.sublist(msg, { start: snap_start, len: Num.int_cast(snap_len) })
                                    when Codec.decode_node_snapshot(snapshot_bytes, 0) is
                                        Ok({ snapshot }) ->
                                            Effect.log!(3, "graph-app: restoring node from snapshot")
                                            updated = ShardState.complete_node_wake(state, qid, Some(snapshot), now)
                                            drain_effects!(updated)
                                        Err(_) ->
                                            Effect.log!(1, "graph-app: failed to decode snapshot, waking with empty state")
                                            updated = ShardState.complete_node_wake(state, qid, None, now)
                                            drain_effects!(updated)
                        else
                            # Not found: wake with empty state
                            Effect.log!(3, "graph-app: no snapshot found, waking new node")
                            updated = ShardState.complete_node_wake(state, qid, None, now)
                            drain_effects!(updated)

                _ ->
                    Effect.log!(1, "graph-app: persist result missing id_len")
                    state

## Decode a U32 from little-endian bytes at the given offset in a list.
## Local helper — avoids needing to export U32 decode from Codec.
decode_u32_at : List U8, U64 -> Result U32 [OutOfBounds]
decode_u32_at = |buf, offset|
    b0_result = List.get(buf, offset)
    b1_result = List.get(buf, offset + 1)
    b2_result = List.get(buf, offset + 2)
    b3_result = List.get(buf, offset + 3)
    when (b0_result, b1_result, b2_result, b3_result) is
        (Ok(b0), Ok(b1), Ok(b2), Ok(b3)) ->
            val : U32
            val =
                Num.int_cast(b0)
                |> Num.bitwise_or(Num.shift_left_by(Num.int_cast(b1), 8))
                |> Num.bitwise_or(Num.shift_left_by(Num.int_cast(b2), 16))
                |> Num.bitwise_or(Num.shift_left_by(Num.int_cast(b3), 24))
            Ok(val)
        _ -> Err(OutOfBounds)
```

- [ ] **Step 4: Verify the id_len decode uses the correct types**

The `id_len` computation uses `Num.int_cast(lo)` which returns U8 → needs to be widened to U64 for use with `List.sublist`. Verify the chain:
- `Num.int_cast(lo)` — lo is U8, needs explicit annotation to U64
- Fix: Use `id_len : U64` annotation or cast explicitly

Corrected version of that section:
```roc
                    id_len : U64
                    id_len = Num.int_cast(lo) |> Num.add(Num.shift_left_by(Num.int_cast(hi), 8))
```

(The `Num.int_cast` on U8 values needs the target type inferred from the annotation.)

- [ ] **Step 5: Commit**

```bash
git add app/graph-app.roc
git commit -m "P1: handle TAG_PERSIST_RESULT in graph-app.roc — decode and complete_node_wake"
```

---

## Task 8: Platform build verification and smoke test (qr-9co)

**Files:**
- No new files. This task verifies everything compiles and links.

- [ ] **Step 1: Verify Rust builds**

Run: `cd platform && cargo build 2>&1`
Expected: Build succeeds (or linker errors for Roc symbols, which is expected without linking the Roc app). The important thing is no Rust compile errors.

- [ ] **Step 2: Verify Roc tests pass**

Run all Roc tests across affected modules:

```bash
roc test packages/core/id/EventTime.roc
roc test packages/graph/codec/Codec.roc
roc test packages/graph/shard/SleepWake.roc
roc test packages/graph/shard/ShardState.roc
```

Expected: All tests pass. Count should be 317+ (existing) plus the ~15 new tests.

- [ ] **Step 3: Verify Roc app builds**

Run: `roc check app/graph-app.roc`
Expected: No type errors or compilation errors.

- [ ] **Step 4: Try full platform+app build**

Run: `roc build --lib app/graph-app.roc 2>&1 | head -30`
Expected: Produces `libapp.dylib` (macOS). If this succeeds, try `cd platform && cargo build` again — with the Roc library available, it should fully link.

- [ ] **Step 5: Close beads issues**

```bash
bd close qr-83w qr-8ty qr-xt0 qr-7uj qr-lfi qr-9co --reason="P1 platform completion implemented"
```

- [ ] **Step 6: Final commit and push**

```bash
git add -A
git commit -m "P1: platform completion — persistence_io, timer, NodeSnapshot codec, sleep/wake wiring"
git push
```

---

## Dependency Graph

```
Task 1 (persistence_io.rs)  ─────────────────────┐
                                                   │
Task 2 (timer.rs)  ──────────────────────────────┐ │
                                                   │ │
Task 3 (U32 + EventTime) ──→ Task 4 (NodeSnapshot │ │
                               codec)             │ │
                                  │                │ │
                                  ▼                │ │
                              Task 5 (SleepWake  ──┤ │
                               wiring)             │ │
                                  │                │ │
                                  ▼                │ │
                              Task 6 (ShardState ──┤ │
                               complete_node_wake) │ │
                                  │                │ │
                                  ▼                │ │
                              Task 7 (graph-app  ◄─┘ │
                               persist result)     ◄─┘
                                  │
                                  ▼
                              Task 8 (build verify)
```

**Parallelizable:** Tasks 1+2 (Rust) can run in parallel with Tasks 3+4 (Roc codec). Task 5 depends on Task 4. Task 6 depends on Task 5. Task 7 depends on Tasks 1+6. Task 8 depends on everything.
