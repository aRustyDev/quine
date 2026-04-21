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

tag_persist_result : U8
tag_persist_result = 0xFE

## Hardcoded shard count until the platform passes this via config.
shard_count : U32
shard_count = 4

## Create a new shard with default configuration.
init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "graph-app: shard $(Num.to_str(shard_id)) initializing")
    ShardState.new(shard_id, shard_count, default_config)

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
            else if tag == tag_persist_result then
                Effect.log!(3, "graph-app: persist result received ($(Num.to_str(List.len(msg))) bytes)")
                state
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

## Handle timer ticks: run LRU eviction and drain effects.
on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    now = Effect.current_time!({})
    updated = ShardState.on_timer(state, now)
    drain_effects!(updated)

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
        Reply({ request_id, payload: _ }) ->
            Effect.log!(3, "graph-app: reply for request $(Num.to_str(request_id)) (routing deferred)")

        SendToNode({ target, msg }) ->
            target_shard = Routing.shard_for_node(target, shard_count)
            envelope = Codec.encode_shard_envelope(target, msg)
            payload = List.concat([tag_shard_msg], envelope)
            when Effect.send_to_shard!(target_shard, payload) is
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
