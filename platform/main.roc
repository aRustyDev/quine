platform "quine-graph"
    requires { ShardState } {
        init_shard! : U32 => ShardState,
        handle_message! : ShardState, List U8 => ShardState,
        on_timer! : ShardState, U8 => ShardState,
    }
    exposes [Effect]
    packages {}
    imports []
    provides [init_shard_for_host!, handle_message_for_host!, on_timer_for_host!]

## Called once per shard at startup. Wraps the app's init_shard! with Box.
init_shard_for_host! : U32 => Box ShardState
init_shard_for_host! = |shard_id|
    Box.box(init_shard!(shard_id))

## Called for each message on a shard's channel.
handle_message_for_host! : Box ShardState, List U8 => Box ShardState
handle_message_for_host! = |boxed_state, msg|
    state = Box.unbox(boxed_state)
    new_state = handle_message!(state, msg)
    Box.box(new_state)

## Called on timer ticks (CheckLru=0, AskTimeout=1).
on_timer_for_host! : Box ShardState, U8 => Box ShardState
on_timer_for_host! = |boxed_state, timer_kind|
    state = Box.unbox(boxed_state)
    new_state = on_timer!(state, timer_kind)
    Box.box(new_state)
