app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

import pf.Effect

# Echo test: each shard receives messages and forwards them to the next shard
# (round-robin, wrapping at 4 shards). Shard 0 primes the pump by sending
# an initial message to shard 1. The on_timer! handler logs message counts.
#
# Expected output: messages bounce between shards, timer ticks log totals.
# The bounce will eventually fill the channel and hit ChannelFull, which is
# also logged. This exercises the full send_to_shard! path.

ShardState : { shard_id : U32, msg_count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "echo shard $(Num.to_str(shard_id)) initialized")

    # Shard 0 primes the echo by sending a message to shard 1
    if shard_id == 0 then
        msg = [0x01, 0x02, 0x03, 0x04] # 4-byte payload
        when Effect.send_to_shard!(1, msg) is
            Ok({}) ->
                Effect.log!(2, "shard 0: seeded echo to shard 1")
            Err(ChannelFull) ->
                Effect.log!(1, "shard 0: seed failed — channel full")
    else
        {}

    { shard_id, msg_count: 0 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, msg|
    new_count = state.msg_count + 1
    msg_len = Num.to_str(List.len(msg))
    Effect.log!(2, "echo shard $(Num.to_str(state.shard_id)): msg #$(Num.to_str(new_count)) ($(msg_len) bytes)")

    # Forward to next shard (round-robin across 4 shards)
    next_shard = Num.rem(state.shard_id + 1, 4)
    when Effect.send_to_shard!(next_shard, msg) is
        Ok({}) ->
            Effect.log!(3, "  forwarded to shard $(Num.to_str(next_shard))")
        Err(ChannelFull) ->
            Effect.log!(1, "  channel full on shard $(Num.to_str(next_shard)) — echo stopped")

    { state & msg_count: new_count }

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    Effect.log!(2, "echo shard $(Num.to_str(state.shard_id)): $(Num.to_str(state.msg_count)) messages processed")
    state
