module [
    ShardState,
    new,
    handle_message,
    on_timer,
    pending_effects,
    node_entry,
    with_awake_node,
    with_lru_entry,
]

import id.QuineId exposing [QuineId]
import types.Ids exposing [ShardId, NamespaceId]
import types.Config exposing [ShardConfig, default_config]
import types.NodeEntry exposing [NodeEntry, compute_cost_to_sleep]
import types.Messages exposing [NodeMessage]
import types.Effects exposing [Effect, BackpressureSignal]
import Lru exposing [LruEntry]
import Dispatch
import SleepWake

## Top-level in-memory state for one shard actor.
##
## A shard owns a partition of the node space and is responsible for waking,
## dispatching, and sleeping nodes within its slice.  All mutation is pure:
## callers read `pending_effects` after each call and execute those effects in
## the surrounding runtime.
ShardState := {
    shard_id : ShardId,
    shard_count : U32,
    config : ShardConfig,
    namespace : NamespaceId,
    nodes : Dict QuineId NodeEntry,
    lru_entries : Dict QuineId LruEntry,
    pending_effects : List Effect,
    request_counter : U64,
    backpressure : BackpressureSignal,
}

## Create a new, empty shard state.
##
## Starts with empty node and LRU dicts, no pending effects, counter at zero,
## and backpressure cleared.
new : ShardId, U32, ShardConfig -> ShardState
new = |shard_id, shard_count, config|
    @ShardState({
        shard_id,
        shard_count,
        config,
        namespace: Default,
        nodes: Dict.empty({}),
        lru_entries: Dict.empty({}),
        pending_effects: [],
        request_counter: 0,
        backpressure: Clear,
    })

## Dispatch a message to a node, updating shard state accordingly.
##
## Three cases:
##   - Awake: dispatch immediately, update LRU metadata, collect effects.
##   - Waking: queue the message on the existing Waking entry.
##   - Not present: trigger a wake via SleepWake.start_wake, which inserts a
##     Waking entry with the message already queued.
handle_message : ShardState, QuineId, NodeMessage, U64 -> ShardState
handle_message = |@ShardState(s), target, msg, now|
    when Dict.get(s.nodes, target) is
        Ok(Awake({ state, wakeful, cost_to_sleep: _, last_write, last_access: _ })) ->
            result = Dispatch.dispatch_node_msg(state, msg)
            new_cost = compute_cost_to_sleep(result.state)
            new_entry = Awake({
                state: result.state,
                wakeful,
                cost_to_sleep: new_cost,
                last_write,
                last_access: now,
            })
            new_nodes = Dict.insert(s.nodes, target, new_entry)
            new_lru = Lru.touch(s.lru_entries, target, now, new_cost)
            @ShardState({ s &
                nodes: new_nodes,
                lru_entries: new_lru,
                pending_effects: result.effects,
            })

        Ok(Waking({ queued })) ->
            new_entry = Waking({ queued: List.append(queued, msg) })
            new_nodes = Dict.insert(s.nodes, target, new_entry)
            @ShardState({ s &
                nodes: new_nodes,
                pending_effects: [],
            })

        Err(_) ->
            awake_count = Dict.len(s.nodes) |> Num.to_u32
            wake_result = SleepWake.start_wake(s.nodes, target, msg, awake_count, s.config)
            @ShardState({ s &
                nodes: wake_result.nodes,
                pending_effects: wake_result.effects,
            })

## Run the periodic LRU eviction check.
##
## If the number of awake nodes is at or below `soft_limit`, no action is
## taken.  Otherwise, the excess nodes (oldest + cheapest first) are
## transitioned toward sleep via SleepWake.begin_sleep.
on_timer : ShardState, U64 -> ShardState
on_timer = |@ShardState(s), now|
    awake_count = Dict.len(s.nodes)
    soft_limit = Num.to_u64(s.config.soft_limit)
    if awake_count <= soft_limit then
        @ShardState({ s & pending_effects: [] })
    else
        excess = awake_count - soft_limit
        candidates = Lru.evict_candidates(s.lru_entries, excess)
        { nodes: final_nodes, effects: all_effects } = List.walk(
            candidates,
            { nodes: s.nodes, effects: [] },
            |acc, qid|
                result = SleepWake.begin_sleep(acc.nodes, qid, now, s.config)
                {
                    nodes: result.nodes,
                    effects: List.concat(acc.effects, result.effects),
                },
        )
        @ShardState({ s &
            nodes: final_nodes,
            pending_effects: all_effects,
        })

## Return the pending effects list from a ShardState (for testing).
pending_effects : ShardState -> List Effect
pending_effects = |@ShardState(s)| s.pending_effects

## Return the NodeEntry for a given QuineId, if present (for testing).
node_entry : ShardState, QuineId -> Result NodeEntry [KeyNotFound]
node_entry = |@ShardState(s), qid| Dict.get(s.nodes, qid)

## Insert an Awake NodeEntry into a ShardState (for testing).
##
## Replaces any existing entry for `qid`.  Does not update the LRU dict —
## call with_lru_entry separately if the LRU is needed.
with_awake_node : ShardState, QuineId, NodeEntry -> ShardState
with_awake_node = |@ShardState(s), qid, entry|
    @ShardState({ s & nodes: Dict.insert(s.nodes, qid, entry) })

## Insert an LRU entry for a node (for testing).
##
## Equivalent to calling Lru.touch with the given timestamp and cost.
with_lru_entry : ShardState, QuineId, U64, I64 -> ShardState
with_lru_entry = |@ShardState(s), qid, ts, cost|
    @ShardState({ s & lru_entries: Lru.touch(s.lru_entries, qid, ts, cost) })

# ===== Tests =====

expect
    # New shard has empty nodes
    shard = new(0, 4, default_config)
    when shard is
        @ShardState(s) -> Dict.is_empty(s.nodes)

expect
    # handle_message for unknown node creates Waking entry
    shard = new(0, 4, default_config)
    qid = QuineId.from_bytes([1])
    msg = LiteralCmd(GetProps({ reply_to: 1 }))
    result = handle_message(shard, qid, msg, 1000)
    when result is
        @ShardState(s) ->
            when Dict.get(s.nodes, qid) is
                Ok(Waking(_)) -> Bool.true
                _ -> Bool.false

expect
    # on_timer with nodes below soft_limit does nothing
    shard = new(0, 4, default_config)
    result = on_timer(shard, 1000)
    when result is
        @ShardState(s) -> List.is_empty(s.pending_effects)
