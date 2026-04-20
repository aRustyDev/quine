app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc" }

ShardState : { shard_id : U32, count : U64 }

init_shard! : U32 => ShardState
init_shard! = |shard_id|
    { shard_id, count: 0 }

handle_message! : ShardState, List U8 => ShardState
handle_message! = |state, _msg|
    { state & count: state.count + 1 }

on_timer! : ShardState, U8 => ShardState
on_timer! = |state, _kind|
    state
