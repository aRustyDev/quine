module [
    ShardState,
    RunningQuery,
    new,
    handle_message,
    on_timer,
    complete_node_wake,
    persist_all_awake,
    pending_effects,
    clear_effects,
    node_entry,
    with_awake_node,
    with_lru_entry,
    register_standing_query,
    lookup_query,
    cancel_standing_query,
    buffer_sq_result,
    drain_sq_results,
    broadcast_update_standing_queries,
    all_node_ids,
]

import id.QuineId exposing [QuineId]
import types.Ids exposing [ShardId, NamespaceId]
import types.Config exposing [ShardConfig, SqConfig, default_config, default_sq_config]
import types.NodeEntry exposing [NodeEntry, compute_cost_to_sleep, empty_node_state]
import types.Messages exposing [NodeMessage]
import types.Effects exposing [Effect, BackpressureSignal]
import model.NodeSnapshot exposing [NodeSnapshot]
import model.PropertyValue
import Lru exposing [LruEntry]
import Dispatch
import SleepWake
import standing_ast.MvStandingQuery exposing [MvStandingQuery]
import standing_result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId, StandingQueryResult]
import standing_state.SqPartState exposing [SqMsgSubscriber]

## A standing query registered with this shard.
##
## Tracks the top-level query AST, whether cancellations should be forwarded,
## and the unique identifier used to address results back to subscribers.
RunningQuery : {
    id : StandingQueryId,
    query : MvStandingQuery,
    include_cancellations : Bool,
}

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
    part_index : Dict StandingQueryPartId MvStandingQuery,
    running_queries : Dict StandingQueryId RunningQuery,
    sq_result_buffer : List StandingQueryResult,
    sq_config : SqConfig,
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
        part_index: Dict.empty({}),
        running_queries: Dict.empty({}),
        sq_result_buffer: [],
        sq_config: default_sq_config,
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
    lookup_fn = |pid| Dict.get(s.part_index, pid) |> Result.map_err(|_| NotFound)
    when Dict.get(s.nodes, target) is
        Ok(Awake({ state, wakeful, cost_to_sleep: _, last_write, last_access: _ })) ->
            result = Dispatch.dispatch_node_msg(state, msg, lookup_fn)
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

## Complete a node's wake sequence after its snapshot has been loaded.
##
## If the node is currently Waking, transitions it to Awake using the
## provided snapshot, then dispatches all queued messages that arrived
## while the node was sleeping.
##
## If the node is not in Waking state (e.g., it was already awake due to
## a race), the snapshot is discarded and the state is returned unchanged.
complete_node_wake : ShardState, QuineId, [None, Some NodeSnapshot], U64 -> ShardState
complete_node_wake = |@ShardState(s), qid, maybe_snapshot, now|
    when Dict.get(s.nodes, qid) is
        Ok(Waking({ queued })) ->
            wake_result = SleepWake.complete_wake(s.nodes, qid, maybe_snapshot, now)
            # Replay queued messages through the now-awake node
            lookup_fn = |pid| Dict.get(s.part_index, pid) |> Result.map_err(|_| NotFound)
            { final_nodes, all_effects } = List.walk(
                queued,
                { final_nodes: wake_result.nodes, all_effects: wake_result.effects },
                |acc, msg|
                    when Dict.get(acc.final_nodes, qid) is
                        Ok(Awake({ state, wakeful, cost_to_sleep: _, last_write, last_access: _ })) ->
                            result = Dispatch.dispatch_node_msg(state, msg, lookup_fn)
                            new_cost = compute_cost_to_sleep(result.state)
                            new_entry = Awake({
                                state: result.state,
                                wakeful,
                                cost_to_sleep: new_cost,
                                last_write,
                                last_access: now,
                            })
                            {
                                final_nodes: Dict.insert(acc.final_nodes, qid, new_entry),
                                all_effects: List.concat(acc.all_effects, result.effects),
                            }
                        _ -> acc,
            )
            # Install SQ subscriptions for all running queries on the newly woken node.
            # Nodes lose their subscriber lists on sleep; this re-establishes them.
            sq_effects = Dict.walk(s.running_queries, [], |acc, _sq_id, running_query|
                subscriber : SqMsgSubscriber
                subscriber = GlobalSubscriber({ global_id: running_query.id })
                sq_msg : NodeMessage
                sq_msg = SqCmd(CreateSqSubscription({
                    subscriber,
                    query: running_query.query,
                    global_id: running_query.id,
                }))
                List.append(acc, SendToNode({ target: qid, msg: sq_msg }))
            )
            combined_effects = List.concat(all_effects, sq_effects)
            new_lru = Lru.touch(s.lru_entries, qid, now, 0)
            @ShardState({ s &
                nodes: final_nodes,
                lru_entries: new_lru,
                pending_effects: combined_effects,
            })

        _ ->
            # Not in Waking state — discard snapshot, no effects
            @ShardState({ s & pending_effects: [] })

## Return the pending effects list from a ShardState (for testing).
pending_effects : ShardState -> List Effect
pending_effects = |@ShardState(s)| s.pending_effects

## Reset the pending effects list to empty.
##
## Called by the app after draining and executing all effects, so they
## are not executed again on the next dispatch.
clear_effects : ShardState -> ShardState
clear_effects = |@ShardState(s)|
    @ShardState({ s & pending_effects: [] })

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

## Register a standing query with this shard.
##
## Stores a RunningQuery entry in `running_queries` and adds all
## globally-indexable sub-queries to `part_index` (keyed by part ID).
## Registering the same ID twice overwrites the previous registration.
register_standing_query : ShardState, StandingQueryId, MvStandingQuery, Bool -> ShardState
register_standing_query = |@ShardState(s), sq_id, query, include_cancellations|
    running = { id: sq_id, query, include_cancellations }
    new_running = Dict.insert(s.running_queries, sq_id, running)
    subqueries = MvStandingQuery.indexable_subqueries(query)
    new_part_index = List.walk(
        subqueries,
        s.part_index,
        |idx, sub|
            pid = MvStandingQuery.query_part_id(sub)
            Dict.insert(idx, pid, sub),
    )
    @ShardState({ s &
        running_queries: new_running,
        part_index: new_part_index,
    })

## Look up an indexable sub-query by its part ID.
##
## Returns Ok(query) if the part ID is registered, or Err(NotFound) otherwise.
lookup_query : ShardState, StandingQueryPartId -> Result MvStandingQuery [NotFound]
lookup_query = |@ShardState(s), part_id|
    Dict.get(s.part_index, part_id)
    |> Result.map_err(|_| NotFound)

## Cancel a standing query, removing it and all its parts from the indexes.
##
## Removes the query from `running_queries`, then rebuilds `part_index`
## from the remaining queries so that orphaned part IDs are cleaned up.
cancel_standing_query : ShardState, StandingQueryId -> ShardState
cancel_standing_query = |@ShardState(s), sq_id|
    new_running = Dict.remove(s.running_queries, sq_id)
    new_part_index = Dict.walk(
        new_running,
        Dict.empty({}),
        |idx, _, rq|
            subqueries = MvStandingQuery.indexable_subqueries(rq.query)
            List.walk(
                subqueries,
                idx,
                |inner_idx, sub|
                    pid = MvStandingQuery.query_part_id(sub)
                    Dict.insert(inner_idx, pid, sub),
            ),
    )
    @ShardState({ s &
        running_queries: new_running,
        part_index: new_part_index,
    })

## Append a standing query result to the shard's result buffer.
##
## If the buffer length after appending meets or exceeds the configured
## `result_buffer_size`, returns Ok(EmitBackpressure(SqBufferFull)) as the
## effect.  Otherwise returns Err(NoEffect).
buffer_sq_result : ShardState, StandingQueryResult -> { state : ShardState, effect : Result Effect [NoEffect] }
buffer_sq_result = |@ShardState(s), result|
    new_buffer = List.append(s.sq_result_buffer, result)
    buffer_len = List.len(new_buffer) |> Num.to_u32
    new_state = @ShardState({ s & sq_result_buffer: new_buffer })
    if buffer_len >= s.sq_config.result_buffer_size then
        { state: new_state, effect: Ok(EmitBackpressure(SqBufferFull)) }
    else
        { state: new_state, effect: Err(NoEffect) }

## Drain all results from the SQ result buffer and return them.
## Clears the buffer and resets backpressure to Clear if it was SqBufferFull.
drain_sq_results : ShardState -> { state : ShardState, results : List StandingQueryResult }
drain_sq_results = |@ShardState(s)|
    results = s.sq_result_buffer
    new_backpressure =
        when s.backpressure is
            SqBufferFull -> Clear
            other -> other
    new_state = @ShardState({ s & sq_result_buffer: [], backpressure: new_backpressure })
    { state: new_state, results }

## Generate CreateSqSubscription messages for all awake nodes for all running queries.
##
## Called after a new SQ is registered or an existing one is cancelled.
## Produces SendToNode effects that will be drained by the app layer.
broadcast_update_standing_queries : ShardState -> ShardState
broadcast_update_standing_queries = |@ShardState(s)|
    effects = Dict.walk(s.running_queries, [], |acc, _sq_id, running_query|
        Dict.walk(s.nodes, acc, |inner_acc, node_id, entry|
            when entry is
                Awake(_) ->
                    subscriber : SqMsgSubscriber
                    subscriber = GlobalSubscriber({ global_id: running_query.id })
                    msg = SqCmd(CreateSqSubscription({
                        subscriber,
                        query: running_query.query,
                        global_id: running_query.id,
                    }))
                    effect = SendToNode({ target: node_id, msg })
                    List.append(inner_acc, effect)
                _ ->
                    inner_acc
        )
    )
    @ShardState({ s & pending_effects: List.concat(s.pending_effects, effects) })

## Persist all awake nodes unconditionally (for graceful shutdown).
## Generates a PersistSnapshot effect for each awake node, bypassing
## activity thresholds. Waking nodes are ignored (they have no live state).
persist_all_awake : ShardState, U64 -> ShardState
persist_all_awake = |@ShardState(s), now|
    effects = Dict.walk(s.nodes, [], |acc, qid, entry|
        when entry is
            Awake({ state }) ->
                List.append(acc, SleepWake.force_persist_snapshot(qid, state, now))
            _ -> acc
    )
    @ShardState({ s & pending_effects: List.concat(s.pending_effects, effects) })

## Return all node IDs in this shard (for broadcast).
all_node_ids : ShardState -> List QuineId
all_node_ids = |@ShardState(s)|
    Dict.keys(s.nodes)

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

expect
    # register_standing_query adds the query to part_index so lookup succeeds
    shard = new(0, 4, default_config)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    pid = MvStandingQuery.query_part_id(query)
    shard2 = register_standing_query(shard, 1u128, query, Bool.true)
    when lookup_query(shard2, pid) is
        Ok(_) -> Bool.true
        Err(_) -> Bool.false

expect
    # cancel_standing_query removes the query from part_index so lookup fails
    shard = new(0, 4, default_config)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    pid = MvStandingQuery.query_part_id(query)
    shard2 = register_standing_query(shard, 1u128, query, Bool.true)
    shard3 = cancel_standing_query(shard2, 1u128)
    when lookup_query(shard3, pid) is
        Ok(_) -> Bool.false
        Err(_) -> Bool.true

expect
    # buffer_sq_result returns NoEffect when below result_buffer_size
    shard = new(0, 4, default_config)
    result : StandingQueryResult
    result = { is_positive_match: Bool.true, data: Dict.empty({}) }
    out = buffer_sq_result(shard, result)
    when out.effect is
        Err(NoEffect) -> Bool.true
        _ -> Bool.false

expect
    # buffer_sq_result returns EmitBackpressure(SqBufferFull) when buffer fills
    # Use a config with result_buffer_size = 1 so a single item triggers it
    tiny_config : SqConfig
    tiny_config = { result_buffer_size: 1u32, backpressure_threshold: 1u32, include_cancellations: Bool.false }
    base = new(0, 4, default_config)
    # Patch sq_config directly via opaque unwrap (allowed within the same module)
    shard =
        when base is
            @ShardState(s) -> @ShardState({ s & sq_config: tiny_config })
    result : StandingQueryResult
    result = { is_positive_match: Bool.true, data: Dict.empty({}) }
    out = buffer_sq_result(shard, result)
    when out.effect is
        Ok(EmitBackpressure(SqBufferFull)) -> Bool.true
        _ -> Bool.false

expect
    # broadcast_update_standing_queries generates SendToNode for each awake node x running query
    shard = new(0, 4, default_config)
    qid1 = QuineId.from_bytes([0x01])
    qid2 = QuineId.from_bytes([0x02])
    ns1 = empty_node_state(qid1)
    ns2 = empty_node_state(qid2)
    awake1 : NodeEntry
    awake1 = Awake({ state: ns1, wakeful: Awake, cost_to_sleep: 0, last_write: 100, last_access: 100 })
    awake2 : NodeEntry
    awake2 = Awake({ state: ns2, wakeful: Awake, cost_to_sleep: 0, last_write: 100, last_access: 100 })
    shard2 = with_awake_node(shard, qid1, awake1)
    shard3 = with_awake_node(shard2, qid2, awake2)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    shard4 = register_standing_query(shard3, 1u128, query, Bool.true)
    shard5 = broadcast_update_standing_queries(shard4)
    effects = pending_effects(shard5)
    # Should have 2 SendToNode effects (one per awake node)
    send_count = List.count_if(effects, |e|
        when e is
            SendToNode(_) -> Bool.true
            _ -> Bool.false)
    send_count == 2

expect
    # persist_all_awake generates PersistSnapshot for each awake node
    shard = new(0, 4, default_config)
    qid1 = QuineId.from_bytes([0x01])
    qid2 = QuineId.from_bytes([0x02])
    ns1 = empty_node_state(qid1)
    ns2 = empty_node_state(qid2)
    awake1 : NodeEntry
    awake1 = Awake({ state: ns1, wakeful: Awake, cost_to_sleep: 0, last_write: 100, last_access: 100 })
    awake2 : NodeEntry
    awake2 = Awake({ state: ns2, wakeful: Awake, cost_to_sleep: 0, last_write: 100, last_access: 100 })
    shard2 = with_awake_node(shard, qid1, awake1)
    shard3 = with_awake_node(shard2, qid2, awake2)
    shard4 = persist_all_awake(shard3, 2000u64)
    effects = pending_effects(shard4)
    persist_count = List.count_if(effects, |e|
        when e is
            Persist({ command: PersistSnapshot(_) }) -> Bool.true
            _ -> Bool.false)
    persist_count == 2

expect
    # persist_all_awake with no nodes produces no effects
    shard = new(0, 4, default_config)
    shard2 = persist_all_awake(shard, 2000u64)
    List.is_empty(pending_effects(shard2))

expect
    # persist_all_awake ignores Waking nodes
    shard = new(0, 4, default_config)
    qid = QuineId.from_bytes([0x05])
    waking_entry : NodeEntry
    waking_entry = Waking({ queued: [] })
    shard2 = with_awake_node(shard, qid, waking_entry)
    shard3 = persist_all_awake(shard2, 2000u64)
    List.is_empty(pending_effects(shard3))

expect
    # drain_sq_results returns buffered results and clears the buffer
    shard = new(0, 4, default_config)
    result1 : StandingQueryResult
    result1 = { is_positive_match: Bool.true, data: Dict.empty({}) }
    result2 : StandingQueryResult
    result2 = { is_positive_match: Bool.false, data: Dict.empty({}) }
    out1 = buffer_sq_result(shard, result1)
    out2 = buffer_sq_result(out1.state, result2)
    drained = drain_sq_results(out2.state)
    has_two = List.len(drained.results) == 2
    is_empty =
        when drained.state is
            @ShardState(s) -> List.is_empty(s.sq_result_buffer)
    has_two && is_empty

expect
    # complete_node_wake transitions Waking to Awake and replays queued SetProp
    config = default_config
    shard = new(0u32, 4u32, config)
    qid = QuineId.from_bytes([0x01])
    # Set up a Waking entry with one queued SetProp message
    pv = PropertyValue.from_value(Str("hello"))
    queued_msg : NodeMessage
    queued_msg = LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 0 }))
    waking_entry : NodeEntry
    waking_entry = Waking({ queued: [queued_msg] })
    shard2 = with_awake_node(shard, qid, waking_entry)
    # Complete wake with no snapshot (new node)
    shard3 = complete_node_wake(shard2, qid, None, 1000u64)
    # Node should be Awake with the SetProp applied
    when node_entry(shard3, qid) is
        Ok(Awake({ state })) ->
            when Dict.get(state.properties, "name") is
                Ok(_) -> Bool.true
                Err(_) -> Bool.false
        _ -> Bool.false

expect
    # complete_node_wake generates CreateSqSubscription for running queries
    config = default_config
    shard = new(0u32, 4u32, config)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    shard2 = register_standing_query(shard, 1u128, query, Bool.true)
    qid = QuineId.from_bytes([0x03])
    waking_entry : NodeEntry
    waking_entry = Waking({ queued: [] })
    shard3 = with_awake_node(shard2, qid, waking_entry)
    shard4 = complete_node_wake(shard3, qid, None, 2000u64)
    effects = pending_effects(shard4)
    List.any(effects, |e|
        when e is
            SendToNode({ msg: SqCmd(CreateSqSubscription(_)) }) -> Bool.true
            _ -> Bool.false)

expect
    # complete_node_wake with no running queries produces no SQ effects
    config = default_config
    shard = new(0u32, 4u32, config)
    qid = QuineId.from_bytes([0x04])
    waking_entry : NodeEntry
    waking_entry = Waking({ queued: [] })
    shard2 = with_awake_node(shard, qid, waking_entry)
    shard3 = complete_node_wake(shard2, qid, None, 2000u64)
    effects = pending_effects(shard3)
    sq_count = List.count_if(effects, |e|
        when e is
            SendToNode({ msg: SqCmd(CreateSqSubscription(_)) }) -> Bool.true
            _ -> Bool.false)
    sq_count == 0

expect
    # complete_node_wake on non-Waking node returns unchanged state
    config = default_config
    shard = new(0u32, 4u32, config)
    qid = QuineId.from_bytes([0x02])
    shard2 = complete_node_wake(shard, qid, None, 1000u64)
    # Should have no entry for this node
    when node_entry(shard2, qid) is
        Err(_) -> Bool.true
        _ -> Bool.false
