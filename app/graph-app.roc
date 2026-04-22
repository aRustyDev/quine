app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc",
      id: "../packages/core/id/main.roc",
      shard: "../packages/graph/shard/main.roc",
      codec: "../packages/graph/codec/main.roc",
      routing: "../packages/graph/routing/main.roc",
      types: "../packages/graph/types/main.roc",
      standing_result: "../packages/graph/standing/result/main.roc" }

import pf.Effect
import id.QuineId
import shard.ShardState
import codec.Codec
import routing.Routing
import types.Config exposing [default_config]
import types.Effects exposing [Effect]


## Type alias required by the platform's `requires { ShardState }` contract.
## Maps the app-level ShardState to the shard package's opaque type.
ShardState : ShardState.ShardState

## Tag bytes used in the wire protocol for shard messages.
tag_shard_msg : U8
tag_shard_msg = 0x01

tag_shard_cmd : U8
tag_shard_cmd = 0x02

tag_persist_result : U8
tag_persist_result = 0xFE

## Create a new shard with default configuration.
## Queries the host for the configured shard count.
init_shard! : U32 => ShardState
init_shard! = |shard_id|
    sc = Effect.shard_count!({})
    Effect.log!(2, "graph-app: shard $(Num.to_str(shard_id)) initializing ($(Num.to_str(sc)) shards)")
    ShardState.new(shard_id, sc, default_config)

## Handle an incoming message by discriminating on the tag byte.
handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, msg|
    when List.get(msg, 0) is
        Err(_) ->
            Effect.log!(1, "graph-app: empty message received")
            state

        Ok(tag) ->
            if tag == tag_shard_msg then
                handle_shard_msg!(state, msg)
            else if tag == tag_shard_cmd then
                handle_shard_cmd!(state, msg)
            else if tag == tag_persist_result then
                handle_persist_result!(state, msg)
            else
                Effect.log!(1, "graph-app: unknown tag 0x$(u8_to_hex(tag))")
                state

## Handle a shard envelope message: decode and dispatch to ShardState.
handle_shard_msg! : ShardState, List U8 => ShardState
handle_shard_msg! = |state, msg|
    now = Effect.current_time!({})
    # Decode the shard envelope starting after the tag byte (offset 1)
    when Codec.decode_shard_envelope(msg, 1) is
        Ok({ target, msg: node_msg, next: _ }) ->
            updated = ShardState.handle_message(state, target, node_msg, now)
            drain_effects!(updated)

        Err(err) ->
            err_str = decode_err_to_str(err)
            Effect.log!(1, "graph-app: decode error: $(err_str)")
            state

## Handle a shard-level command (SQ registration, update, cancellation).
## These are sent by the REST API to all shards, not targeted at a specific node.
handle_shard_cmd! : ShardState, List U8 => ShardState
handle_shard_cmd! = |state, msg|
    # Decode shard command starting after the TAG_SHARD_CMD byte (offset 1)
    when Codec.decode_shard_cmd(msg, 1) is
        Ok({ val: RegisterSq({ global_id, include_cancellations, query }) }) ->
            Effect.log!(2, "graph-app: registering SQ $(Num.to_str(global_id))")
            updated = ShardState.register_standing_query(state, global_id, query, include_cancellations)
            drain_effects!(updated)

        Ok({ val: UpdateSqs }) ->
            Effect.log!(3, "graph-app: broadcasting SQ update to nodes")
            updated = ShardState.broadcast_update_standing_queries(state)
            drain_effects!(updated)

        Ok({ val: CancelSq({ global_id }) }) ->
            Effect.log!(2, "graph-app: cancelling SQ $(Num.to_str(global_id))")
            updated = ShardState.cancel_standing_query(state, global_id)
            drain_effects!(updated)

        Err(err) ->
            err_str = decode_err_to_str(err)
            Effect.log!(1, "graph-app: shard cmd decode error: $(err_str)")
            state

## Handle timer ticks: run LRU eviction and drain effects.
on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    now = Effect.current_time!({})
    updated = ShardState.on_timer(state, now)
    drain_effects!(updated)

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
                    id_len : U64
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

## Execute all pending effects and return the state with effects cleared.
drain_effects! : ShardState => ShardState
drain_effects! = |state|
    effects = ShardState.pending_effects(state)
    List.for_each!(effects, |effect|
        execute_effect!(effect))
    ShardState.clear_effects(state)

## Execute a single effect via host functions.
execute_effect! : Effect => {}
execute_effect! = |effect|
    when effect is
        Reply({ request_id, payload }) ->
            encoded = encode_reply_payload(payload)
            Effect.reply!(request_id, encoded)

        SendToNode({ target, msg }) ->
            target_shard = Routing.shard_for_node(target, Effect.shard_count!({}))
            envelope = Codec.encode_shard_envelope(target, msg)
            when Effect.send_to_shard!(target_shard, envelope) is
                Ok({}) -> {}
                Err(ChannelFull) ->
                    Effect.log!(1, "graph-app: channel full sending to shard $(Num.to_str(target_shard))")

        SendToShard({ shard_id, payload }) ->
            when Effect.send_to_shard!(shard_id, payload) is
                Ok({}) -> {}
                Err(ChannelFull) ->
                    Effect.log!(1, "graph-app: channel full sending to shard $(Num.to_str(shard_id))")

        Persist({ command }) ->
            cmd_bytes = encode_persist_command(command)
            _req_id = Effect.persist_async!(cmd_bytes)
            {}

        EmitBackpressure(signal) ->
            signal_str = backpressure_to_str(signal)
            Effect.log!(2, "graph-app: backpressure signal: $(signal_str)")

        UpdateCostToSleep(_cost) ->
            # Internal bookkeeping — no host action needed
            {}

        EmitSqResult({ query_id, result }) ->
            payload = encode_sq_result_payload(query_id, result)
            when Effect.emit_sq_result!(payload) is
                Ok({}) ->
                    is_pos = if result.is_positive_match then "+" else "-"
                    Effect.log!(3, "graph-app: SQ result $(is_pos) for query $(Num.to_str(query_id))")
                Err(SqBufferFull) ->
                    Effect.log!(1, "graph-app: SQ result buffer full for query $(Num.to_str(query_id))")

## Encode a ReplyPayload to bytes for the host's reply! function.
##
## Props format: [prop_count:U32LE] repeated: [key_len:U16LE][key...][value_bytes...]
##               [edge_count:U32LE=0]
## Ack format: [prop_count:U32LE=0][edge_count:U32LE=0]
## Err format: [prop_count:U32LE=0][edge_count:U32LE=0] (error text discarded for now)
encode_reply_payload : [Props (Dict Str _), Edges (List _), NodeState { properties : Dict Str _, edges : List _ }, Ack, Err Str] -> List U8
encode_reply_payload = |payload|
    when payload is
        Props(props) ->
            prop_count = Dict.len(props) |> Num.to_u32
            header = encode_u32_le(prop_count)
            prop_bytes = Dict.walk(props, [], |acc, key, val|
                key_bytes = Str.to_utf8(key)
                key_len_bytes = encode_u16_le(Num.to_u16(List.len(key_bytes)))
                val_bytes = Codec.encode_property_value(val)
                acc
                |> List.concat(key_len_bytes)
                |> List.concat(key_bytes)
                |> List.concat(val_bytes))
            edge_count = encode_u32_le(0u32)
            header
            |> List.concat(prop_bytes)
            |> List.concat(edge_count)

        Edges(edges) ->
            prop_count = encode_u32_le(0u32)
            edge_count = List.len(edges) |> Num.to_u32 |> encode_u32_le
            edge_bytes = List.walk(edges, [], |acc, edge|
                List.concat(acc, Codec.encode_half_edge(edge)))
            prop_count
            |> List.concat(edge_count)
            |> List.concat(edge_bytes)

        NodeState({ properties, edges }) ->
            prop_count = Dict.len(properties) |> Num.to_u32
            prop_header = encode_u32_le(prop_count)
            prop_bytes = Dict.walk(properties, [], |acc, key, val|
                key_bytes = Str.to_utf8(key)
                key_len_bytes = encode_u16_le(Num.to_u16(List.len(key_bytes)))
                val_bytes = Codec.encode_property_value(val)
                acc
                |> List.concat(key_len_bytes)
                |> List.concat(key_bytes)
                |> List.concat(val_bytes))
            edge_count = List.len(edges) |> Num.to_u32 |> encode_u32_le
            edge_bytes = List.walk(edges, [], |acc, edge|
                List.concat(acc, Codec.encode_half_edge(edge)))
            prop_header
            |> List.concat(prop_bytes)
            |> List.concat(edge_count)
            |> List.concat(edge_bytes)

        Ack ->
            List.concat(encode_u32_le(0u32), encode_u32_le(0u32))

        Err(_) ->
            List.concat(encode_u32_le(0u32), encode_u32_le(0u32))

encode_u16_le : U16 -> List U8
encode_u16_le = |n|
    [Num.int_cast(Num.bitwise_and(n, 0xFF)),
     Num.int_cast(Num.shift_right_zf_by(n, 8))]

## Encode a StandingQueryResult for the host's emit_sq_result! function.
## Format: [query_id_lo:U64LE] [query_id_hi:U64LE] [is_positive:U8] [pair_count:U32LE]
## Full QuineValue serialization deferred to Phase 5.
encode_sq_result_payload : U128, { is_positive_match : Bool, data : Dict Str _ } -> List U8
encode_sq_result_payload = |query_id, result|
    lo = Num.int_cast(Num.bitwise_and(query_id, 0xFFFFFFFFFFFFFFFF)) |> encode_u64_le
    hi = Num.int_cast(Num.shift_right_zf_by(query_id, 64)) |> encode_u64_le
    is_positive_byte = if result.is_positive_match then 1u8 else 0u8
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

## Encode a PersistCommand to bytes for the host.
## Format: [tag:U8] [qid_len:U16LE] [qid_bytes...] [data...]
encode_persist_command : [PersistSnapshot { id : _, snapshot_bytes : List U8 }, LoadSnapshot { id : _ }] -> List U8
encode_persist_command = |command|
    when command is
        PersistSnapshot({ id, snapshot_bytes }) ->
            id_bytes = id |> QuineId.to_bytes
            id_len_lo = Num.int_cast(Num.bitwise_and(Num.to_u16(List.len(id_bytes)), 0xFF))
            id_len_hi = Num.int_cast(Num.shift_right_zf_by(Num.to_u16(List.len(id_bytes)), 8))
            [0x01, id_len_lo, id_len_hi]
            |> List.concat(id_bytes)
            |> List.concat(snapshot_bytes)

        LoadSnapshot({ id }) ->
            id_bytes = id |> QuineId.to_bytes
            id_len_lo = Num.int_cast(Num.bitwise_and(Num.to_u16(List.len(id_bytes)), 0xFF))
            id_len_hi = Num.int_cast(Num.shift_right_zf_by(Num.to_u16(List.len(id_bytes)), 8))
            [0x02, id_len_lo, id_len_hi]
            |> List.concat(id_bytes)

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

## Convert a decode error tag to a human-readable string.
decode_err_to_str : [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection] -> Str
decode_err_to_str = |err|
    when err is
        OutOfBounds -> "out of bounds"
        BadUtf8 -> "bad utf8"
        InvalidTag -> "invalid tag"
        InvalidDirection -> "invalid direction"

## Convert a backpressure signal to a human-readable string.
backpressure_to_str : [HardLimitReached, SqBufferFull, Clear] -> Str
backpressure_to_str = |signal|
    when signal is
        HardLimitReached -> "hard limit reached"
        SqBufferFull -> "sq buffer full"
        Clear -> "clear"

## Convert a U8 to a two-character hex string.
u8_to_hex : U8 -> Str
u8_to_hex = |b|
    hi = Num.shift_right_zf_by(b, 4)
    lo = Num.bitwise_and(b, 0x0F)
    hi_char = hex_nibble(hi)
    lo_char = hex_nibble(lo)
    when Str.from_utf8([hi_char, lo_char]) is
        Ok(s) -> s
        Err(_) -> "??"

hex_nibble : U8 -> U8
hex_nibble = |n|
    if n < 10 then
        n + '0'
    else
        n - 10 + 'a'
