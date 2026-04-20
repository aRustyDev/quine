app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc",
      id: "../packages/core/id/main.roc",
      model: "../packages/core/model/main.roc",
      shard: "../packages/graph/shard/main.roc",
      codec: "../packages/graph/codec/main.roc",
      routing: "../packages/graph/routing/main.roc",
      types: "../packages/graph/types/main.roc" }

import pf.Effect
import id.QuineId
import model.PropertyValue
import shard.ShardState
import codec.Codec
import routing.Routing
import types.Config exposing [default_config]
import types.Effects exposing [Effect]
import types.NodeEntry exposing [NodeEntry, empty_node_state]

## Type alias required by the platform's `requires { ShardState }` contract.
ShardState : ShardState.ShardState

## Tag byte the host prepends on the channel wire format.
tag_shard_msg : U8
tag_shard_msg = 0x01

## Shard count for the integration test (run with --shards 2).
shard_count : U32
shard_count = 2

## The target node for the test message.
target_node : QuineId.QuineId
target_node = QuineId.from_bytes([0xAA])

## Initialize a shard.
## - The shard that owns node 0xAA pre-populates it as Awake.
## - Shard 0 seeds a SetProp message to the owning shard.
init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "test: shard $(Num.to_str(shard_id)) init")

    state0 = ShardState.new(shard_id, shard_count, default_config)

    target_shard = Routing.shard_for_node(target_node, shard_count)

    # Pre-populate node 0xAA on the shard that owns it
    state =
        if Num.to_u32(shard_id) == target_shard then
            ns = empty_node_state(target_node)
            awake_entry : NodeEntry
            awake_entry = Awake({
                state: ns,
                wakeful: Awake,
                cost_to_sleep: 0,
                last_write: 0,
                last_access: 0,
            })
            ShardState.with_awake_node(state0, target_node, awake_entry)
        else
            state0

    # Shard 0 seeds the test message
    if shard_id == 0 then
        seed_set_prop!(state)
    else
        state

## Encode a SetProp message targeting node 0xAA and send it to the
## appropriate shard via send_to_shard!.
seed_set_prop! : ShardState => ShardState
seed_set_prop! = |state|
    target_shard = Routing.shard_for_node(target_node, shard_count)

    pv = PropertyValue.from_value(Str("hello"))
    msg = LiteralCmd(SetProp({ key: "greeting", value: pv, reply_to: 1 }))
    envelope = Codec.encode_shard_envelope(target_node, msg)

    # send_to_shard! — the host prepends TAG_SHARD_MSG (0x01) automatically
    when Effect.send_to_shard!(target_shard, envelope) is
        Ok({}) ->
            Effect.log!(2, "test: seeded SetProp to shard $(Num.to_str(target_shard))")
            state

        Err(ChannelFull) ->
            Effect.log!(1, "test: channel full, could not seed SetProp")
            state

## Handle an incoming message: discriminate on the tag byte, decode,
## dispatch to ShardState, and execute effects.
handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, msg|
    when List.get(msg, 0) is
        Err(_) ->
            Effect.log!(1, "test: empty message received")
            state

        Ok(tag) ->
            if tag == tag_shard_msg then
                handle_shard_msg!(state, msg)
            else
                Effect.log!(1, "test: unknown tag 0x$(u8_to_hex(tag))")
                state

## Decode a shard envelope and dispatch to ShardState.handle_message.
handle_shard_msg! : ShardState, List U8 => ShardState
handle_shard_msg! = |state, msg|
    Effect.log!(2, "test: dispatching message to node")
    now = Effect.current_time!({})

    when Codec.decode_shard_envelope(msg, 1) is
        Ok({ target, msg: node_msg, next: _ }) ->
            updated = ShardState.handle_message(state, target, node_msg, now)
            drain_effects!(updated)

        Err(err) ->
            err_str = decode_err_to_str(err)
            Effect.log!(1, "test: decode error: $(err_str)")
            state

## Timer handler: no-op for the integration test.
on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    state

## Execute all pending effects and return the state with effects cleared.
drain_effects! : ShardState => ShardState
drain_effects! = |state|
    effects = ShardState.pending_effects(state)
    List.for_each!(effects, |effect|
        execute_effect!(effect))
    ShardState.clear_effects(state)

## Execute a single effect: log Reply effects, handle others minimally.
execute_effect! : Effect => {}
execute_effect! = |effect|
    when effect is
        Reply({ request_id, payload }) ->
            payload_str = reply_payload_to_str(payload)
            Effect.log!(2, "test: REPLY request_id=$(Num.to_str(request_id)) -> $(payload_str)")

        SendToNode({ target, msg }) ->
            target_shard = Routing.shard_for_node(target, shard_count)
            envelope = Codec.encode_shard_envelope(target, msg)
            when Effect.send_to_shard!(target_shard, envelope) is
                Ok({}) -> {}
                Err(ChannelFull) ->
                    Effect.log!(1, "test: channel full sending to shard $(Num.to_str(target_shard))")

        SendToShard({ shard_id, payload }) ->
            when Effect.send_to_shard!(shard_id, payload) is
                Ok({}) -> {}
                Err(ChannelFull) ->
                    Effect.log!(1, "test: channel full sending to shard $(Num.to_str(shard_id))")

        Persist(_) ->
            # Ignore persistence for integration test
            {}

        EmitBackpressure(_) ->
            {}

        UpdateCostToSleep(_) ->
            {}

## Convert a ReplyPayload to a human-readable string.
reply_payload_to_str : [Props (Dict Str PropertyValue.PropertyValue), Edges (List _), Ack, Err Str] -> Str
reply_payload_to_str = |payload|
    when payload is
        Ack -> "Ack"
        Err(msg) -> "Err($(msg))"
        Props(_) -> "Props(...)"
        Edges(_) -> "Edges(...)"

## Convert a decode error tag to a human-readable string.
decode_err_to_str : [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection] -> Str
decode_err_to_str = |err|
    when err is
        OutOfBounds -> "out of bounds"
        BadUtf8 -> "bad utf8"
        InvalidTag -> "invalid tag"
        InvalidDirection -> "invalid direction"

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
