app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

import pf.Effect

ShardState : { shard_id : U32, count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    Effect.log!(2, "shard $(Num.to_str(shard_id)) initialized")
    { shard_id, count: 0 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, msg|
    now = Effect.current_time!({})
    new_count = state.count + 1
    Effect.log!(2, "shard $(Num.to_str(state.shard_id)) msg #$(Num.to_str(new_count)) at $(Num.to_str(now))ms ($(Num.to_str(List.len(msg))) bytes)")

    # Test send_to_shard!
    result = Effect.send_to_shard!(1, msg)
    when result is
        Ok({}) -> Effect.log!(2, "send_to_shard! succeeded")
        Err(ChannelFull) -> Effect.log!(1, "send_to_shard! channel full")

    { state & count: new_count }

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, kind|
    Effect.log!(3, "shard $(Num.to_str(state.shard_id)) timer kind=$(Num.to_str(kind))")
    state
