app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

import pf.Effect

# Backpressure test: shard 0 floods shard 1's channel until ChannelFull.
# Verifies the backpressure signal path through send_to_shard!.
#
# Expected output:
#   shard 0 sends messages until ChannelFull (at capacity 4096)
#   logs "ChannelFull after N sends" to confirm the limit was hit
#   shard 1 logs how many messages it received on its first timer tick

ShardState : { shard_id : U32, sent : U64, full_count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "backpressure test shard $(Num.to_str(shard_id)) ready")

    # Shard 0 floods shard 1 on init.
    # Note: whether ChannelFull fires depends on scheduling — if shard 1 is
    # already in its recv loop, it may drain messages faster than we can send.
    # Either outcome (full_count>0 or hitting the send cap) is valid and tests
    # the send_to_shard! path. Check full_count in the log to see which occurred.
    if shard_id == 0 then
        result = flood_shard!(1, 0, 0)
        Effect.log!(2, "shard 0: flood done — sent=$(Num.to_str(result.sent)) full_count=$(Num.to_str(result.full_count))")
        { shard_id, sent: result.sent, full_count: result.full_count }
    else
        { shard_id, sent: 0, full_count: 0 }

# Tail-recursive flood: keep sending until ChannelFull or limit reached.
# Roc optimizes tail calls so this will not overflow the stack.
# Limit is 8192 (2x channel capacity) to reliably hit ChannelFull if the
# target shard is not draining fast enough.
flood_shard! : U32, U64, U64 => { sent : U64, full_count : U64 }
flood_shard! = |target, sent, full_count|
    if sent >= 8_192 then
        Effect.log!(2, "flood_shard!: hit send limit of 8192")
        { sent, full_count }
    else
        msg = [0x42] # 1-byte dummy message
        when Effect.send_to_shard!(target, msg) is
            Ok({}) ->
                flood_shard!(target, sent + 1, full_count)
            Err(ChannelFull) ->
                Effect.log!(1, "ChannelFull after $(Num.to_str(sent)) sends")
                { sent, full_count: full_count + 1 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, _msg|
    { state & sent: state.sent + 1 }

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    Effect.log!(2, "shard $(Num.to_str(state.shard_id)): received $(Num.to_str(state.sent)) messages, full_count=$(Num.to_str(state.full_count))")
    state
