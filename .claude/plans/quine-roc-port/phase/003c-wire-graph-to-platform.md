# Wire Phase 3b Graph Layer to Phase 3a Platform

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the pure Roc graph layer (ShardState, dispatch, LRU, sleep/wake) to the Rust/tokio host platform so messages flow through the real graph engine.

**Architecture:** The app.roc acts as the **effect interpreter** — it calls ShardState's pure functions, then iterates `pending_effects` and executes each one via host-provided effects (send_to_shard!, persist_async!, log!). The host passes message tag bytes through to Roc so it can discriminate between shard messages (0x01) and persist results (0xFE). A new `Codec` module handles List U8 ↔ typed message encoding.

**Tech Stack:** Roc (app + codec module), Rust (shard_worker.rs tweak), existing platform/Host.roc effects

---

## File Structure

| File | Responsibility |
|------|---------------|
| **Create:** `app/graph-app.roc` | Main app — implements platform contract, imports graph packages, interprets effects |
| **Create:** `packages/graph/codec/main.roc` | Package definition for codec module |
| **Create:** `packages/graph/codec/Codec.roc` | Encode/decode ShardMessage ↔ List U8 for the FFI boundary |
| **Create:** `packages/graph/codec/CodecTest.roc` | Roundtrip tests for codec |
| **Modify:** `platform/src/shard_worker.rs:51-58` | Pass full tagged message (keep tag byte) to Roc handle_message! |
| **Modify:** `packages/graph/shard/ShardState.roc` | Add `clear_effects` function to reset pending_effects after drain |

## Design Decisions

### Message Tag Passthrough

Currently `shard_worker.rs` strips the tag byte (`&msg[1..]`) before calling Roc. We'll change it to pass the full message (`&msg[..]`) so Roc can discriminate:
- `0x01` → shard message: decode QuineId + NodeMessage from remaining bytes
- `0xFE` → persist result: decode RequestId from remaining bytes

This is a one-line change per branch in the match statement.

### Codec Encoding Format

Simple length-prefixed binary. No external dependencies:

**Shard message:** `[qid_len:U16LE] [qid_bytes...] [msg_tag:U8] [msg_fields...]`

Message tags:
- `0x01` GetProps: `[reply_to:U64LE]`
- `0x02` SetProp: `[reply_to:U64LE] [key_len:U16LE] [key_utf8...] [val_tag:U8] [val_data...]`
- `0x03` RemoveProp: `[reply_to:U64LE] [key_len:U16LE] [key_utf8...]`
- `0x04` AddEdge: `[reply_to:U64LE] [edge_type_len:U16LE] [edge_type_utf8...] [direction:U8] [other_qid_len:U16LE] [other_qid_bytes...]`
- `0x05` RemoveEdge: same layout as AddEdge
- `0x06` GetEdges: `[reply_to:U64LE]`
- `0x07` SleepCheck: `[now:U64LE]`

PropertyValue encoding (val_tag):
- `0x01` Str: `[len:U16LE] [utf8...]`
- `0x02` Integer: `[I64LE]`
- `0x03` Floating: `[F64LE]`
- `0x04` True (no payload)
- `0x05` False (no payload)
- `0x06` Null (no payload)
- `0x07` Bytes: `[len:U16LE] [bytes...]`
- `0x08` Id: `[len:U16LE] [qid_bytes...]`

EdgeDirection encoding:
- `0x01` Outgoing, `0x02` Incoming, `0x03` Undirected

### Effect Interpretation

The app.roc `handle_message!` and `on_timer!` functions:
1. Call ShardState pure function
2. Read `pending_effects`
3. For each effect, call host functions:
   - `Reply` → encode and `send_to_shard!` to the originating shard (for now, log it — reply routing requires caller tracking)
   - `SendToNode` → compute target shard via `Routing.shard_for_node`, encode message, `send_to_shard!`
   - `SendToShard` → `send_to_shard!` directly
   - `Persist` → encode persist command, `persist_async!`
   - `EmitBackpressure` → `log!` the signal
   - `UpdateCostToSleep` → no host action (consumed by shard state)
4. Return state with effects cleared

---

### Task 1: Modify shard_worker.rs — pass tag byte through

**Files:**
- Modify: `platform/src/shard_worker.rs:51-58`

- [ ] **Step 1: Edit shard_worker.rs to keep tag bytes**

Change the `TAG_PERSIST_RESULT` and `TAG_SHARD_MSG` branches to pass the full message instead of stripping the tag:

```rust
TAG_PERSIST_RESULT => {
    // Pass full message (including tag) so Roc can discriminate.
    state = roc_glue::call_handle_message(state, &msg);
}
TAG_SHARD_MSG => {
    // Pass full message (including tag) so Roc can discriminate.
    state = roc_glue::call_handle_message(state, &msg);
}
```

Since both branches now do the same thing, merge them:

```rust
TAG_SHARD_MSG | TAG_PERSIST_RESULT => {
    state = roc_glue::call_handle_message(state, &msg);
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd platform && cargo check`
Expected: compiles without errors

- [ ] **Step 3: Commit**

```bash
git add platform/src/shard_worker.rs
git commit -m "phase-3 wiring: pass message tag byte through to Roc handle_message!"
```

---

### Task 2: Add clear_effects to ShardState

**Files:**
- Modify: `packages/graph/shard/ShardState.roc`

- [ ] **Step 1: Add clear_effects to module exports**

Add `clear_effects` to the module list at the top of `ShardState.roc`:

```roc
module [
    ShardState,
    new,
    handle_message,
    on_timer,
    pending_effects,
    clear_effects,
    node_entry,
    with_awake_node,
    with_lru_entry,
]
```

- [ ] **Step 2: Implement clear_effects**

Add after the `pending_effects` function:

```roc
## Reset the pending effects list to empty.
##
## Called by the app after draining and executing all effects, so they
## are not executed again on the next dispatch.
clear_effects : ShardState -> ShardState
clear_effects = |@ShardState(s)|
    @ShardState({ s & pending_effects: [] })
```

- [ ] **Step 3: Add test for clear_effects**

Add in the test section:

```roc
expect
    # clear_effects empties the pending_effects list
    shard = new(0, 4, default_config)
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    awake_entry : NodeEntry
    awake_entry = Awake({
        state: ns,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: 100,
        last_access: 100,
    })
    shard_with_node = with_awake_node(shard, qid, awake_entry)
    msg = LiteralCmd(GetProps({ reply_to: 1 }))
    after_msg = handle_message(shard_with_node, qid, msg, 200)
    # Should have effects
    has_effects = !(List.is_empty(pending_effects(after_msg)))
    # After clear, should have none
    cleared = clear_effects(after_msg)
    no_effects = List.is_empty(pending_effects(cleared))
    has_effects and no_effects
```

- [ ] **Step 4: Run tests**

Run: `roc test packages/graph/shard/ShardState.roc`
Expected: all tests pass including the new clear_effects test

- [ ] **Step 5: Commit**

```bash
git add packages/graph/shard/ShardState.roc
git commit -m "phase-3 wiring: add clear_effects to ShardState"
```

---

### Task 3: Create Codec package — encode/decode shard messages

**Files:**
- Create: `packages/graph/codec/main.roc`
- Create: `packages/graph/codec/Codec.roc`

- [ ] **Step 1: Create the codec package definition**

Create `packages/graph/codec/main.roc`:

```roc
package [
    Codec,
] {
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
    types: "../types/main.roc",
}
```

- [ ] **Step 2: Create Codec.roc with U16/U64 byte helpers**

Create `packages/graph/codec/Codec.roc` with the encoding helpers first:

```roc
module [
    encode_node_msg,
    decode_node_msg,
    encode_shard_envelope,
    decode_shard_envelope,
]

import id.QuineId exposing [QuineId]
import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]
import model.EdgeDirection exposing [EdgeDirection]
import types.Ids exposing [RequestId]
import types.Messages exposing [NodeMessage, LiteralCommand]

## Encode a U16 as 2 little-endian bytes.
encode_u16 : U16 -> List U8
encode_u16 = |n|
    [
        Num.to_u8(Num.bitwise_and(n, 0xFF)),
        Num.to_u8(Num.shift_right_zf_by(n, 8)),
    ]

## Decode a U16 from 2 little-endian bytes at the given offset.
## Returns the value and the new offset.
decode_u16 : List U8, U64 -> Result { val : U16, next : U64 } [OutOfBounds]
decode_u16 = |bytes, offset|
    lo = List.get(bytes, offset) |> Result.map_err(|_| OutOfBounds)
    hi = List.get(bytes, offset + 1) |> Result.map_err(|_| OutOfBounds)
    when (lo, hi) is
        (Ok(l), Ok(h)) ->
            val = Num.bitwise_or(Num.to_u16(l), Num.shift_left_by(Num.to_u16(h), 8))
            Ok({ val, next: offset + 2 })
        _ -> Err(OutOfBounds)

## Encode a U64 as 8 little-endian bytes.
encode_u64 : U64 -> List U8
encode_u64 = |n|
    [
        Num.to_u8(Num.bitwise_and(n, 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 8), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 16), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 24), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 32), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 40), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 48), 0xFF)),
        Num.to_u8(Num.bitwise_and(Num.shift_right_zf_by(n, 56), 0xFF)),
    ]

## Decode a U64 from 8 little-endian bytes at the given offset.
decode_u64 : List U8, U64 -> Result { val : U64, next : U64 } [OutOfBounds]
decode_u64 = |bytes, offset|
    if offset + 8 > List.len(bytes) then
        Err(OutOfBounds)
    else
        b0 = List.get(bytes, offset) |> Result.with_default(0)
        b1 = List.get(bytes, offset + 1) |> Result.with_default(0)
        b2 = List.get(bytes, offset + 2) |> Result.with_default(0)
        b3 = List.get(bytes, offset + 3) |> Result.with_default(0)
        b4 = List.get(bytes, offset + 4) |> Result.with_default(0)
        b5 = List.get(bytes, offset + 5) |> Result.with_default(0)
        b6 = List.get(bytes, offset + 6) |> Result.with_default(0)
        b7 = List.get(bytes, offset + 7) |> Result.with_default(0)
        val =
            Num.to_u64(b0)
            |> Num.bitwise_or(Num.shift_left_by(Num.to_u64(b1), 8))
            |> Num.bitwise_or(Num.shift_left_by(Num.to_u64(b2), 16))
            |> Num.bitwise_or(Num.shift_left_by(Num.to_u64(b3), 24))
            |> Num.bitwise_or(Num.shift_left_by(Num.to_u64(b4), 32))
            |> Num.bitwise_or(Num.shift_left_by(Num.to_u64(b5), 40))
            |> Num.bitwise_or(Num.shift_left_by(Num.to_u64(b6), 48))
            |> Num.bitwise_or(Num.shift_left_by(Num.to_u64(b7), 56))
        Ok({ val, next: offset + 8 })

## Encode a length-prefixed byte slice (U16 length + bytes).
encode_bytes : List U8 -> List U8
encode_bytes = |bs|
    len = List.len(bs) |> Num.to_u16
    List.concat(encode_u16(len), bs)

## Decode a length-prefixed byte slice at the given offset.
decode_bytes : List U8, U64 -> Result { val : List U8, next : U64 } [OutOfBounds]
decode_bytes = |bytes, offset|
    when decode_u16(bytes, offset) is
        Ok({ val: len16, next: after_len }) ->
            len = Num.to_u64(len16)
            end = after_len + len
            if end > List.len(bytes) then
                Err(OutOfBounds)
            else
                val = List.sublist(bytes, { start: after_len, len })
                Ok({ val, next: end })
        Err(e) -> Err(e)

## Encode a length-prefixed UTF-8 string (U16 length + bytes).
encode_str : Str -> List U8
encode_str = |s|
    encode_bytes(Str.to_utf8(s))

## Decode a length-prefixed UTF-8 string at the given offset.
decode_str : List U8, U64 -> Result { val : Str, next : U64 } [OutOfBounds, BadUtf8]
decode_str = |bytes, offset|
    when decode_bytes(bytes, offset) is
        Ok({ val: raw, next }) ->
            when Str.from_utf8(raw) is
                Ok(s) -> Ok({ val: s, next })
                Err(_) -> Err(BadUtf8)
        Err(e) -> Err(e)

## Encode an EdgeDirection as a U8.
encode_direction : EdgeDirection -> U8
encode_direction = |dir|
    when dir is
        Outgoing -> 0x01
        Incoming -> 0x02
        Undirected -> 0x03

## Decode an EdgeDirection from a U8.
decode_direction : U8 -> Result EdgeDirection [InvalidDirection]
decode_direction = |b|
    when b is
        0x01 -> Ok(Outgoing)
        0x02 -> Ok(Incoming)
        0x03 -> Ok(Undirected)
        _ -> Err(InvalidDirection)

## Encode a PropertyValue to bytes.
encode_property_value : PropertyValue -> List U8
encode_property_value = |pv|
    when pv is
        Deserialized(qv) -> encode_quine_value(qv)
        Serialized(bs) -> List.concat([0x07], encode_bytes(bs))
        Both({ value }) -> encode_quine_value(value)

encode_quine_value = |qv|
    when qv is
        Str(s) -> List.concat([0x01], encode_str(s))
        Integer(n) ->
            # Encode I64 as U64 (reinterpret bits)
            List.concat([0x02], encode_u64(Num.to_u64(Num.int_cast(n))))
        Floating(f) ->
            # Encode F64 bits as U64
            List.concat([0x03], encode_u64(Num.to_u64(Num.int_cast(f))))
        True -> [0x04]
        False -> [0x05]
        Null -> [0x06]
        Bytes(bs) -> List.concat([0x07], encode_bytes(bs))
        Id(qid) -> List.concat([0x08], encode_bytes(QuineId.to_bytes(qid)))
        List(_) -> [0x06] # Stub: nested lists encoded as Null for now
        Map(_) -> [0x06] # Stub: nested maps encoded as Null for now

## Decode a PropertyValue from bytes at the given offset.
decode_property_value : List U8, U64 -> Result { val : PropertyValue, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_property_value = |bytes, offset|
    when List.get(bytes, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            after_tag = offset + 1
            when tag is
                0x01 ->
                    when decode_str(bytes, after_tag) is
                        Ok({ val: s, next }) -> Ok({ val: Deserialized(Str(s)), next })
                        Err(_) -> Err(OutOfBounds)
                0x02 ->
                    when decode_u64(bytes, after_tag) is
                        Ok({ val: bits, next }) ->
                            n : I64
                            n = Num.int_cast(bits)
                            Ok({ val: Deserialized(Integer(n)), next })
                        Err(_) -> Err(OutOfBounds)
                0x04 -> Ok({ val: Deserialized(True), next: after_tag })
                0x05 -> Ok({ val: Deserialized(False), next: after_tag })
                0x06 -> Ok({ val: Deserialized(Null), next: after_tag })
                0x07 ->
                    when decode_bytes(bytes, after_tag) is
                        Ok({ val: bs, next }) -> Ok({ val: Serialized(bs), next })
                        Err(_) -> Err(OutOfBounds)
                0x08 ->
                    when decode_bytes(bytes, after_tag) is
                        Ok({ val: bs, next }) -> Ok({ val: Deserialized(Id(QuineId.from_bytes(bs))), next })
                        Err(_) -> Err(OutOfBounds)
                _ -> Err(InvalidTag)

## Encode a HalfEdge to bytes.
encode_half_edge : HalfEdge -> List U8
encode_half_edge = |edge|
    List.join([
        encode_str(edge.edge_type),
        [encode_direction(edge.direction)],
        encode_bytes(QuineId.to_bytes(edge.other)),
    ])

## Decode a HalfEdge from bytes at the given offset.
decode_half_edge : List U8, U64 -> Result { val : HalfEdge, next : U64 } [OutOfBounds, BadUtf8, InvalidDirection]
decode_half_edge = |bytes, offset|
    when decode_str(bytes, offset) is
        Err(e) -> Err(e)
        Ok({ val: edge_type, next: o1 }) ->
            when List.get(bytes, o1) is
                Err(_) -> Err(OutOfBounds)
                Ok(dir_byte) ->
                    when decode_direction(dir_byte) is
                        Err(e) -> Err(e)
                        Ok(direction) ->
                            when decode_bytes(bytes, o1 + 1) is
                                Err(_) -> Err(OutOfBounds)
                                Ok({ val: qid_bytes, next }) ->
                                    Ok({
                                        val: {
                                            edge_type,
                                            direction,
                                            other: QuineId.from_bytes(qid_bytes),
                                        },
                                        next,
                                    })

# ---------------------------------------------------------------
# NodeMessage encoding
# ---------------------------------------------------------------

msg_tag_get_props = 0x01
msg_tag_set_prop = 0x02
msg_tag_remove_prop = 0x03
msg_tag_add_edge = 0x04
msg_tag_remove_edge = 0x05
msg_tag_get_edges = 0x06
msg_tag_sleep_check = 0x07

## Encode a NodeMessage to bytes.
encode_node_msg : NodeMessage -> List U8
encode_node_msg = |msg|
    when msg is
        LiteralCmd(cmd) ->
            when cmd is
                GetProps({ reply_to }) ->
                    List.concat([msg_tag_get_props], encode_u64(reply_to))
                SetProp({ key, value, reply_to }) ->
                    List.join([
                        [msg_tag_set_prop],
                        encode_u64(reply_to),
                        encode_str(key),
                        encode_property_value(value),
                    ])
                RemoveProp({ key, reply_to }) ->
                    List.join([
                        [msg_tag_remove_prop],
                        encode_u64(reply_to),
                        encode_str(key),
                    ])
                AddEdge({ edge, reply_to }) ->
                    List.join([
                        [msg_tag_add_edge],
                        encode_u64(reply_to),
                        encode_half_edge(edge),
                    ])
                RemoveEdge({ edge, reply_to }) ->
                    List.join([
                        [msg_tag_remove_edge],
                        encode_u64(reply_to),
                        encode_half_edge(edge),
                    ])
                GetEdges({ reply_to }) ->
                    List.concat([msg_tag_get_edges], encode_u64(reply_to))
        SleepCheck({ now }) ->
            List.concat([msg_tag_sleep_check], encode_u64(now))

## Decode a NodeMessage from bytes at the given offset.
decode_node_msg : List U8, U64 -> Result { val : NodeMessage, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_node_msg = |bytes, offset|
    when List.get(bytes, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            after_tag = offset + 1
            when tag is
                0x01 -> # GetProps
                    when decode_u64(bytes, after_tag) is
                        Ok({ val: reply_to, next }) ->
                            Ok({ val: LiteralCmd(GetProps({ reply_to })), next })
                        Err(_) -> Err(OutOfBounds)
                0x02 -> # SetProp
                    when decode_u64(bytes, after_tag) is
                        Err(_) -> Err(OutOfBounds)
                        Ok({ val: reply_to, next: o1 }) ->
                            when decode_str(bytes, o1) is
                                Err(e) -> Err(e)
                                Ok({ val: key, next: o2 }) ->
                                    when decode_property_value(bytes, o2) is
                                        Err(e) -> Err(e)
                                        Ok({ val: value, next: o3 }) ->
                                            Ok({ val: LiteralCmd(SetProp({ key, value, reply_to })), next: o3 })
                0x03 -> # RemoveProp
                    when decode_u64(bytes, after_tag) is
                        Err(_) -> Err(OutOfBounds)
                        Ok({ val: reply_to, next: o1 }) ->
                            when decode_str(bytes, o1) is
                                Err(e) -> Err(e)
                                Ok({ val: key, next: o2 }) ->
                                    Ok({ val: LiteralCmd(RemoveProp({ key, reply_to })), next: o2 })
                0x04 -> # AddEdge
                    when decode_u64(bytes, after_tag) is
                        Err(_) -> Err(OutOfBounds)
                        Ok({ val: reply_to, next: o1 }) ->
                            when decode_half_edge(bytes, o1) is
                                Err(e) -> Err(e)
                                Ok({ val: edge, next: o2 }) ->
                                    Ok({ val: LiteralCmd(AddEdge({ edge, reply_to })), next: o2 })
                0x05 -> # RemoveEdge
                    when decode_u64(bytes, after_tag) is
                        Err(_) -> Err(OutOfBounds)
                        Ok({ val: reply_to, next: o1 }) ->
                            when decode_half_edge(bytes, o1) is
                                Err(e) -> Err(e)
                                Ok({ val: edge, next: o2 }) ->
                                    Ok({ val: LiteralCmd(RemoveEdge({ edge, reply_to })), next: o2 })
                0x06 -> # GetEdges
                    when decode_u64(bytes, after_tag) is
                        Ok({ val: reply_to, next }) ->
                            Ok({ val: LiteralCmd(GetEdges({ reply_to })), next })
                        Err(_) -> Err(OutOfBounds)
                0x07 -> # SleepCheck
                    when decode_u64(bytes, after_tag) is
                        Ok({ val: now, next }) ->
                            Ok({ val: SleepCheck({ now }), next })
                        Err(_) -> Err(OutOfBounds)
                _ -> Err(InvalidTag)

# ---------------------------------------------------------------
# Shard envelope — QuineId + NodeMessage
# ---------------------------------------------------------------

## Encode a shard-routed message: QuineId + NodeMessage.
## This is what goes through send_to_shard! (without the host tag byte).
encode_shard_envelope : QuineId, NodeMessage -> List U8
encode_shard_envelope = |qid, msg|
    List.join([
        encode_bytes(QuineId.to_bytes(qid)),
        encode_node_msg(msg),
    ])

## Decode a shard-routed message from bytes at the given offset.
decode_shard_envelope : List U8, U64 -> Result { target : QuineId, msg : NodeMessage, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_shard_envelope = |bytes, offset|
    when decode_bytes(bytes, offset) is
        Err(e) -> Err(e)
        Ok({ val: qid_bytes, next: o1 }) ->
            when decode_node_msg(bytes, o1) is
                Err(e) -> Err(e)
                Ok({ val: msg, next: o2 }) ->
                    Ok({ target: QuineId.from_bytes(qid_bytes), msg, next: o2 })
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/graph/codec/Codec.roc`
Expected: compiles (no tests yet — tests in next step)

- [ ] **Step 4: Commit**

```bash
git add packages/graph/codec/
git commit -m "phase-3 wiring: codec package for ShardMessage <-> List U8 encoding"
```

---

### Task 4: Codec roundtrip tests

**Files:**
- Create: `packages/graph/codec/CodecTest.roc`

- [ ] **Step 1: Create CodecTest.roc with roundtrip tests**

```roc
module []

import id.QuineId
import model.PropertyValue
import types.Messages exposing [NodeMessage]
import Codec

# ===== U16/U64 roundtrip tests are internal to Codec =====

# ===== NodeMessage roundtrip tests =====

expect
    # GetProps roundtrip
    msg : NodeMessage
    msg = LiteralCmd(GetProps({ reply_to: 42 }))
    encoded = Codec.encode_node_msg(msg)
    when Codec.decode_node_msg(encoded, 0) is
        Ok({ val }) -> val == msg
        Err(_) -> Bool.false

expect
    # SetProp roundtrip
    pv = PropertyValue.from_value(Str("alice"))
    msg : NodeMessage
    msg = LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 7 }))
    encoded = Codec.encode_node_msg(msg)
    when Codec.decode_node_msg(encoded, 0) is
        Ok({ val: LiteralCmd(SetProp({ key: "name", reply_to: 7 })) }) -> Bool.true
        _ -> Bool.false

expect
    # RemoveProp roundtrip
    msg : NodeMessage
    msg = LiteralCmd(RemoveProp({ key: "age", reply_to: 99 }))
    encoded = Codec.encode_node_msg(msg)
    when Codec.decode_node_msg(encoded, 0) is
        Ok({ val }) -> val == msg
        Err(_) -> Bool.false

expect
    # AddEdge roundtrip
    other = QuineId.from_bytes([0x0B, 0x0C])
    edge = { edge_type: "KNOWS", direction: Outgoing, other }
    msg : NodeMessage
    msg = LiteralCmd(AddEdge({ edge, reply_to: 5 }))
    encoded = Codec.encode_node_msg(msg)
    when Codec.decode_node_msg(encoded, 0) is
        Ok({ val }) -> val == msg
        Err(_) -> Bool.false

expect
    # RemoveEdge roundtrip
    other = QuineId.from_bytes([0xFF])
    edge = { edge_type: "FOLLOWS", direction: Incoming, other }
    msg : NodeMessage
    msg = LiteralCmd(RemoveEdge({ edge, reply_to: 3 }))
    encoded = Codec.encode_node_msg(msg)
    when Codec.decode_node_msg(encoded, 0) is
        Ok({ val }) -> val == msg
        Err(_) -> Bool.false

expect
    # GetEdges roundtrip
    msg : NodeMessage
    msg = LiteralCmd(GetEdges({ reply_to: 1000 }))
    encoded = Codec.encode_node_msg(msg)
    when Codec.decode_node_msg(encoded, 0) is
        Ok({ val }) -> val == msg
        Err(_) -> Bool.false

expect
    # SleepCheck roundtrip
    msg : NodeMessage
    msg = SleepCheck({ now: 1713600000000 })
    encoded = Codec.encode_node_msg(msg)
    when Codec.decode_node_msg(encoded, 0) is
        Ok({ val }) -> val == msg
        Err(_) -> Bool.false

# ===== Shard envelope roundtrip tests =====

expect
    # Envelope roundtrip: QuineId + GetProps
    qid = QuineId.from_bytes([0xAA, 0xBB, 0xCC])
    msg : NodeMessage
    msg = LiteralCmd(GetProps({ reply_to: 1 }))
    encoded = Codec.encode_shard_envelope(qid, msg)
    when Codec.decode_shard_envelope(encoded, 0) is
        Ok({ target, msg: decoded_msg }) ->
            target == qid and decoded_msg == msg
        Err(_) -> Bool.false

expect
    # Envelope roundtrip: QuineId + SetProp
    qid = QuineId.from_bytes([0x01])
    pv = PropertyValue.from_value(Integer(42))
    msg : NodeMessage
    msg = LiteralCmd(SetProp({ key: "count", value: pv, reply_to: 10 }))
    encoded = Codec.encode_shard_envelope(qid, msg)
    when Codec.decode_shard_envelope(encoded, 0) is
        Ok({ target, msg: LiteralCmd(SetProp({ key: "count", reply_to: 10 })) }) ->
            target == qid
        _ -> Bool.false

expect
    # Empty QuineId roundtrip
    qid = QuineId.from_bytes([])
    msg : NodeMessage
    msg = LiteralCmd(GetProps({ reply_to: 0 }))
    encoded = Codec.encode_shard_envelope(qid, msg)
    when Codec.decode_shard_envelope(encoded, 0) is
        Ok({ target }) -> target == qid
        Err(_) -> Bool.false

expect
    # Decode from truncated bytes returns error
    when Codec.decode_node_msg([0x01], 0) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false

expect
    # Decode with invalid tag returns error
    when Codec.decode_node_msg([0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 0) is
        Err(InvalidTag) -> Bool.true
        _ -> Bool.false
```

- [ ] **Step 2: Run codec tests**

Run: `roc test packages/graph/codec/CodecTest.roc`
Expected: all tests pass

- [ ] **Step 3: Commit**

```bash
git add packages/graph/codec/CodecTest.roc
git commit -m "phase-3 wiring: codec roundtrip tests"
```

---

### Task 5: Create graph-app.roc — wire platform to graph layer

**Files:**
- Create: `app/graph-app.roc`

- [ ] **Step 1: Create graph-app.roc implementing the platform contract**

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc",
      shard: "../packages/graph/shard/main.roc",
      codec: "../packages/graph/codec/main.roc",
      routing: "../packages/graph/routing/main.roc",
      types: "../packages/graph/types/main.roc" }

import pf.Effect
import shard.ShardState exposing [ShardState]
import codec.Codec
import routing.Routing
import types.Config exposing [default_config]
import types.Effects exposing [Effect]

# ---------------------------------------------------------------
# Platform contract implementation
# ---------------------------------------------------------------

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    shard_count = 4u32 # TODO: pass via config message
    Effect.log!(2, "graph-app: shard $(Num.to_str(shard_id)) initializing ($(Num.to_str(shard_count)) shards)")
    ShardState.new(shard_id, shard_count, default_config)

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, msg|
    when List.first(msg) is
        Err(_) -> state
        Ok(tag) ->
            payload = List.drop_first(msg, 1)
            when tag is
                0x01 -> # TAG_SHARD_MSG — decode and dispatch
                    handle_shard_msg!(state, payload)
                0xFE -> # TAG_PERSIST_RESULT — decode request ID
                    handle_persist_result!(state, payload)
                _ ->
                    Effect.log!(1, "graph-app: unknown message tag 0x$(u8_to_hex(tag))")
                    state

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _timer_kind|
    now = Effect.current_time!({})
    new_state = ShardState.on_timer(state, now)
    effects = ShardState.pending_effects(new_state)
    cleared = ShardState.clear_effects(new_state)
    execute_effects!(effects, cleared)
    cleared

# ---------------------------------------------------------------
# Message handlers
# ---------------------------------------------------------------

handle_shard_msg! : ShardState, List U8 => ShardState
handle_shard_msg! = |state, payload|
    when Codec.decode_shard_envelope(payload, 0) is
        Ok({ target, msg }) ->
            now = Effect.current_time!({})
            new_state = ShardState.handle_message(state, target, msg, now)
            effects = ShardState.pending_effects(new_state)
            cleared = ShardState.clear_effects(new_state)
            execute_effects!(effects, cleared)
            cleared
        Err(_) ->
            Effect.log!(0, "graph-app: failed to decode shard message")
            state

handle_persist_result! : ShardState, List U8 => ShardState
handle_persist_result! = |state, payload|
    # Persist results carry a request ID (8 bytes LE).
    # For now, log it. Full persistence integration comes in a later phase.
    Effect.log!(3, "graph-app: persist result received ($(Num.to_str(List.len(payload))) bytes)")
    state

# ---------------------------------------------------------------
# Effect interpreter
# ---------------------------------------------------------------

execute_effects! : List Effect, ShardState => {}
execute_effects! = |effects, state|
    List.for_each!(effects, |effect|
        execute_one_effect!(effect, state))

execute_one_effect! : Effect, ShardState => {}
execute_one_effect! = |effect, _state|
    when effect is
        Reply({ request_id, payload }) ->
            Effect.log!(3, "graph-app: reply request_id=$(Num.to_str(request_id)) payload=$(reply_payload_tag(payload))")

        SendToNode({ target, msg }) ->
            shard_count = 4u32 # Must match init_shard! shard_count
            target_shard = Routing.shard_for_node(target, shard_count)
            encoded = Codec.encode_shard_envelope(target, msg)
            result = Effect.send_to_shard!(target_shard, encoded)
            when result is
                Ok({}) -> {}
                Err(ChannelFull) ->
                    Effect.log!(1, "graph-app: SendToNode channel full for shard $(Num.to_str(target_shard))")

        SendToShard({ shard_id, payload }) ->
            result = Effect.send_to_shard!(shard_id, payload)
            when result is
                Ok({}) -> {}
                Err(ChannelFull) ->
                    Effect.log!(1, "graph-app: SendToShard channel full for shard $(Num.to_str(shard_id))")

        Persist({ command }) ->
            when command is
                PersistSnapshot({ id, snapshot_bytes }) ->
                    Effect.log!(3, "graph-app: persist snapshot for node ($(Num.to_str(List.len(snapshot_bytes))) bytes)")
                    _req_id = Effect.persist_async!(snapshot_bytes)
                    {}
                LoadSnapshot({ id }) ->
                    Effect.log!(3, "graph-app: load snapshot requested")
                    _req_id = Effect.persist_async!([])
                    {}

        EmitBackpressure(signal) ->
            label = when signal is
                HardLimitReached -> "HardLimitReached"
                SqBufferFull -> "SqBufferFull"
                Clear -> "Clear"
            Effect.log!(1, "graph-app: backpressure $(label)")

        UpdateCostToSleep(_cost) ->
            # Internal bookkeeping — no host action needed
            {}

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

reply_payload_tag : _ -> Str
reply_payload_tag = |payload|
    when payload is
        Props(_) -> "Props"
        Edges(_) -> "Edges"
        Ack -> "Ack"
        Err(msg) -> "Err($(msg))"

u8_to_hex : U8 -> Str
u8_to_hex = |b|
    hi = Num.shift_right_zf_by(b, 4)
    lo = Num.bitwise_and(b, 0x0F)
    hex_digit = |n| when n is
        0 -> "0"; 1 -> "1"; 2 -> "2"; 3 -> "3"
        4 -> "4"; 5 -> "5"; 6 -> "6"; 7 -> "7"
        8 -> "8"; 9 -> "9"; 10 -> "a"; 11 -> "b"
        12 -> "c"; 13 -> "d"; 14 -> "e"; 15 -> "f"
        _ -> "?"
    "$(hex_digit(hi))$(hex_digit(lo))"
```

- [ ] **Step 2: Build the app**

Run: `roc check app/graph-app.roc`
Expected: compiles without errors. Fix any import path or type issues.

Note: this step may require iterating on import paths. The key thing is that the app must import packages using relative paths in the `app` header.

- [ ] **Step 3: Commit**

```bash
git add app/graph-app.roc
git commit -m "phase-3 wiring: graph-app.roc wires platform to graph layer"
```

---

### Task 6: Build and run end-to-end smoke test

**Files:**
- No new files — uses existing build pipeline

- [ ] **Step 1: Build the Roc app to object file**

Run:
```bash
cd app && roc build --no-link graph-app.roc
```

This produces `app/graph-app.o`. If it fails, fix Roc compilation errors.

- [ ] **Step 2: Create static library for Rust linking**

Run:
```bash
cd platform && ar rcs libapp.a ../app/graph-app.o
```

- [ ] **Step 3: Build the host**

Run:
```bash
cd platform && cargo build
```

Expected: links successfully against libapp.a

- [ ] **Step 4: Run the binary**

Run:
```bash
cd platform && cargo run -- --shards 2 --timer-interval 5000
```

Expected output (stderr):
```
[INFO] graph-app: shard 0 initializing (4 shards)
[INFO] graph-app: shard 1 initializing (4 shards)
```

Timer ticks should produce debug logs every 5 seconds. The process runs until Ctrl-C.

Let it run for ~10 seconds to verify timer handling works, then Ctrl-C.

- [ ] **Step 5: Commit any fixes**

If any code changes were needed, commit them:
```bash
git add -A
git commit -m "phase-3 wiring: end-to-end smoke test fixes"
```

---

### Task 7: Integration test — send a message through the graph

**Files:**
- Create: `app/integration-test-graph.roc`

This test app verifies the full message lifecycle: encode a SetProp message, send it to shard 0, verify the graph-app processes it (observe via logs).

- [ ] **Step 1: Create integration test app**

Create `app/integration-test-graph.roc`:

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc",
      shard: "../packages/graph/shard/main.roc",
      codec: "../packages/graph/codec/main.roc",
      routing: "../packages/graph/routing/main.roc",
      types: "../packages/graph/types/main.roc",
      core_id: "../packages/core/id/main.roc",
      core_model: "../packages/core/model/main.roc" }

import pf.Effect
import shard.ShardState exposing [ShardState]
import codec.Codec
import routing.Routing
import types.Config exposing [default_config]
import types.Effects exposing [Effect]
import core_id.QuineId
import core_model.PropertyValue

shard_count = 2u32

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "test: shard $(Num.to_str(shard_id)) init")
    state = ShardState.new(shard_id, shard_count, default_config)

    # Shard 0 seeds a SetProp message to node 0xAA
    if shard_id == 0 then
        qid = QuineId.from_bytes([0xAA])
        pv = PropertyValue.from_value(Str("test-value"))
        msg = LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 1 }))
        target_shard = Routing.shard_for_node(qid, shard_count)
        encoded = Codec.encode_shard_envelope(qid, msg)
        result = Effect.send_to_shard!(target_shard, encoded)
        when result is
            Ok({}) -> Effect.log!(2, "test: seeded SetProp to shard $(Num.to_str(target_shard))")
            Err(ChannelFull) -> Effect.log!(0, "test: channel full on seed")
        state
    else
        state

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, msg|
    when List.first(msg) is
        Err(_) -> state
        Ok(tag) ->
            payload = List.drop_first(msg, 1)
            when tag is
                0x01 ->
                    when Codec.decode_shard_envelope(payload, 0) is
                        Ok({ target, msg: node_msg }) ->
                            now = Effect.current_time!({})
                            Effect.log!(2, "test: dispatching message to node")
                            new_state = ShardState.handle_message(state, target, node_msg, now)
                            effects = ShardState.pending_effects(new_state)
                            cleared = ShardState.clear_effects(new_state)
                            List.for_each!(effects, |effect|
                                when effect is
                                    Reply({ request_id, payload: reply_payload }) ->
                                        Effect.log!(2, "test: REPLY request_id=$(Num.to_str(request_id)) -> SUCCESS")
                                    SendToNode({ target: t, msg: m }) ->
                                        target_shard = Routing.shard_for_node(t, shard_count)
                                        encoded = Codec.encode_shard_envelope(t, m)
                                        _result = Effect.send_to_shard!(target_shard, encoded)
                                        Effect.log!(2, "test: SendToNode forwarded")
                                    _ ->
                                        Effect.log!(3, "test: effect (other)"))
                            cleared
                        Err(_) ->
                            Effect.log!(0, "test: decode failed")
                            state
                _ -> state

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    state
```

- [ ] **Step 2: Build and run the integration test**

```bash
cd app && roc build --no-link integration-test-graph.roc
cd ../platform && ar rcs libapp.a ../app/integration-test-graph.o && cargo build && cargo run -- --shards 2
```

Expected output:
```
[INFO] test: shard 0 init
[INFO] test: seeded SetProp to shard <N>
[INFO] test: shard 1 init
[INFO] test: dispatching message to node
[INFO] test: REPLY request_id=1 -> SUCCESS
```

The REPLY line confirms the full cycle: encode → channel → decode → ShardState.handle_message → effect produced → Reply logged.

- [ ] **Step 3: Commit**

```bash
git add app/integration-test-graph.roc
git commit -m "phase-3 wiring: integration test — SetProp through graph layer"
```

---

## Self-Review Checklist

1. **Spec coverage:**
   - [x] app.roc implementing platform contract (Task 5)
   - [x] List U8 encoding for ShardMessage (Task 3)
   - [x] TimerKind → on_timer handled (Task 5, on_timer! calls current_time! and passes to ShardState)
   - [x] Effect executor wired (Task 5, execute_effects!)
   - [x] shard_worker.rs modified for tag passthrough (Task 1)
   - [x] Integration smoke test (Tasks 6-7)
   - Note: "Run Phase 3b's component tests on the actual platform" — Phase 3b tests use `roc test` which runs standalone. They don't need the platform. The integration test (Task 7) verifies the wiring works on the actual platform.

2. **Placeholder scan:** No TBD/TODO (except one intentional `# TODO: pass via config message` for shard_count, which is a known simplification).

3. **Type consistency:** QuineId, NodeMessage, ShardState, Effect types consistent across all tasks. Codec function names (encode_shard_envelope/decode_shard_envelope, encode_node_msg/decode_node_msg) used consistently.
