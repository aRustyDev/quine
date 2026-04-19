module [
    should_decline_sleep,
    begin_sleep,
    complete_sleep,
    start_wake,
    complete_wake,
]

import id.QuineId exposing [QuineId]
import model.NodeSnapshot exposing [NodeSnapshot]
import types.Config exposing [ShardConfig]
import types.NodeEntry exposing [NodeEntry, WakefulState, empty_node_state, compute_cost_to_sleep]
import types.Effects exposing [Effect]
import types.Messages exposing [NodeMessage]

## Return true if the node should NOT be put to sleep right now.
##
## Declines sleep if there was a recent write (within decline_sleep_when_write_within_ms)
## or a recent access (when the access threshold is > 0 and within the window).
should_decline_sleep : { last_write : U64, last_access : U64, now : U64, config : ShardConfig } -> Bool
should_decline_sleep = |{ last_write, last_access, now, config }|
    recent_write = (now - last_write) < config.decline_sleep_when_write_within_ms
    recent_access =
        config.decline_sleep_when_access_within_ms > 0
        and (now - last_access) < config.decline_sleep_when_access_within_ms
    recent_write or recent_access

## Attempt to begin putting a node to sleep.
##
## If the node is Awake and activity thresholds allow it, transitions the
## node to ConsideringSleep and emits a PersistSnapshot effect so the shard
## can durably record state before the node fully sleeps.
##
## Returns unchanged nodes if the node is Waking, not present, or has
## recent write/access activity.
begin_sleep : Dict QuineId NodeEntry, QuineId, U64, ShardConfig -> { nodes : Dict QuineId NodeEntry, effects : List Effect }
begin_sleep = |nodes, qid, now, config|
    when Dict.get(nodes, qid) is
        Err(_) -> { nodes, effects: [] }
        Ok(entry) ->
            when entry is
                Waking(_) -> { nodes, effects: [] }
                Awake({ state, cost_to_sleep, last_write, last_access }) ->
                    if should_decline_sleep({ last_write, last_access, now, config }) then
                        { nodes, effects: [] }
                    else
                        new_wakeful : WakefulState
                        new_wakeful = ConsideringSleep({ deadline: now + config.sleep_deadline_ms })
                        new_entry = Awake({
                            state,
                            wakeful: new_wakeful,
                            cost_to_sleep,
                            last_write,
                            last_access,
                        })
                        new_nodes = Dict.insert(nodes, qid, new_entry)
                        persist_effect = Persist({ command: PersistSnapshot({ id: qid, snapshot_bytes: [] }) })
                        { nodes: new_nodes, effects: [persist_effect] }

## Finalize the sleep of a node by removing it from the shard's live dict.
##
## Called once the node has confirmed it is safe to remove (i.e. the
## ConsideringSleep deadline has passed without new messages).
complete_sleep : Dict QuineId NodeEntry, QuineId -> Dict QuineId NodeEntry
complete_sleep = |nodes, qid|
    Dict.remove(nodes, qid)

## Begin waking a node that is currently asleep.
##
## If the shard is already at the hard node limit, emits HardLimitReached
## backpressure and leaves nodes unchanged. Otherwise, inserts a Waking
## entry with the triggering message queued, and emits a LoadSnapshot
## effect so the persistor can supply the node's last snapshot.
start_wake : Dict QuineId NodeEntry, QuineId, NodeMessage, U32, ShardConfig -> { nodes : Dict QuineId NodeEntry, effects : List Effect }
start_wake = |nodes, qid, msg, awake_count, config|
    if awake_count >= config.hard_limit then
        { nodes, effects: [EmitBackpressure(HardLimitReached)] }
    else
        new_entry = Waking({ queued: [msg] })
        new_nodes = Dict.insert(nodes, qid, new_entry)
        load_effect = Persist({ command: LoadSnapshot({ id: qid }) })
        { nodes: new_nodes, effects: [load_effect] }

## Complete the wake sequence for a node after its snapshot has been loaded.
##
## Reconstructs a NodeState from the snapshot (or uses an empty state for new
## nodes). Computes cost_to_sleep and inserts an Awake entry with both
## last_write and last_access set to `now`.
complete_wake : Dict QuineId NodeEntry, QuineId, [None, Some NodeSnapshot], U64 -> { nodes : Dict QuineId NodeEntry, effects : List Effect }
complete_wake = |nodes, qid, maybe_snapshot, now|
    state =
        when maybe_snapshot is
            None -> empty_node_state(qid)
            Some(snap) ->
                {
                    id: qid,
                    properties: snap.properties,
                    edges: Dict.empty({}),
                    journal: [],
                    snapshot_base: Some(snap),
                    edge_storage: Inline,
                }
    cost = compute_cost_to_sleep(state)
    new_entry = Awake({
        state,
        wakeful: Awake,
        cost_to_sleep: cost,
        last_write: now,
        last_access: now,
    })
    new_nodes = Dict.insert(nodes, qid, new_entry)
    { nodes: new_nodes, effects: [] }

# ===== Tests =====

expect
    # should_decline_sleep true for recent write
    config = {
        soft_limit: 10_000u32,
        hard_limit: 50_000u32,
        lru_check_interval_ms: 10_000u64,
        ask_timeout_ms: 5_000u64,
        decline_sleep_when_write_within_ms: 100u64,
        decline_sleep_when_access_within_ms: 0u64,
        sleep_deadline_ms: 3_000u64,
        max_edges_warning_threshold: 100_000u64,
    }
    # last_write = 950, now = 1000, diff = 50 < 100 => decline
    should_decline_sleep({ last_write: 950u64, last_access: 0u64, now: 1000u64, config })

expect
    # should_decline_sleep false for old write
    config = {
        soft_limit: 10_000u32,
        hard_limit: 50_000u32,
        lru_check_interval_ms: 10_000u64,
        ask_timeout_ms: 5_000u64,
        decline_sleep_when_write_within_ms: 100u64,
        decline_sleep_when_access_within_ms: 0u64,
        sleep_deadline_ms: 3_000u64,
        max_edges_warning_threshold: 100_000u64,
    }
    # last_write = 800, now = 1000, diff = 200 >= 100 => don't decline
    !(should_decline_sleep({ last_write: 800u64, last_access: 0u64, now: 1000u64, config }))

expect
    # begin_sleep on awake node with old activity transitions to ConsideringSleep
    config = {
        soft_limit: 10_000u32,
        hard_limit: 50_000u32,
        lru_check_interval_ms: 10_000u64,
        ask_timeout_ms: 5_000u64,
        decline_sleep_when_write_within_ms: 100u64,
        decline_sleep_when_access_within_ms: 0u64,
        sleep_deadline_ms: 3_000u64,
        max_edges_warning_threshold: 100_000u64,
    }
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    entry = Awake({
        state: ns,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: 500u64,
        last_access: 500u64,
    })
    nodes = Dict.insert(Dict.empty({}), qid, entry)
    # now=1000, last_write=500 => diff=500 >= 100 => OK to sleep
    result = begin_sleep(nodes, qid, 1000u64, config)
    when Dict.get(result.nodes, qid) is
        Ok(Awake({ wakeful: ConsideringSleep(_) })) -> Bool.true
        _ -> Bool.false

expect
    # begin_sleep on node with recent write stays Awake (no change)
    config = {
        soft_limit: 10_000u32,
        hard_limit: 50_000u32,
        lru_check_interval_ms: 10_000u64,
        ask_timeout_ms: 5_000u64,
        decline_sleep_when_write_within_ms: 100u64,
        decline_sleep_when_access_within_ms: 0u64,
        sleep_deadline_ms: 3_000u64,
        max_edges_warning_threshold: 100_000u64,
    }
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    entry = Awake({
        state: ns,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: 950u64,
        last_access: 950u64,
    })
    nodes = Dict.insert(Dict.empty({}), qid, entry)
    # now=1000, last_write=950 => diff=50 < 100 => decline sleep
    result = begin_sleep(nodes, qid, 1000u64, config)
    when Dict.get(result.nodes, qid) is
        Ok(Awake({ wakeful: Awake })) -> Bool.true
        _ -> Bool.false

expect
    # complete_sleep removes node from Dict
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    entry = Awake({
        state: ns,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: 0u64,
        last_access: 0u64,
    })
    nodes = Dict.insert(Dict.empty({}), qid, entry)
    after = complete_sleep(nodes, qid)
    !(Dict.contains(after, qid))

expect
    # start_wake inserts Waking entry
    config = {
        soft_limit: 10_000u32,
        hard_limit: 50_000u32,
        lru_check_interval_ms: 10_000u64,
        ask_timeout_ms: 5_000u64,
        decline_sleep_when_write_within_ms: 100u64,
        decline_sleep_when_access_within_ms: 0u64,
        sleep_deadline_ms: 3_000u64,
        max_edges_warning_threshold: 100_000u64,
    }
    qid = QuineId.from_bytes([0x01])
    msg : NodeMessage
    msg = SleepCheck({ now: 0 })
    result = start_wake(Dict.empty({}), qid, msg, 0u32, config)
    when Dict.get(result.nodes, qid) is
        Ok(Waking(_)) -> Bool.true
        _ -> Bool.false

expect
    # start_wake at hard limit emits HardLimitReached backpressure
    config = {
        soft_limit: 10_000u32,
        hard_limit: 50_000u32,
        lru_check_interval_ms: 10_000u64,
        ask_timeout_ms: 5_000u64,
        decline_sleep_when_write_within_ms: 100u64,
        decline_sleep_when_access_within_ms: 0u64,
        sleep_deadline_ms: 3_000u64,
        max_edges_warning_threshold: 100_000u64,
    }
    qid = QuineId.from_bytes([0x01])
    msg : NodeMessage
    msg = SleepCheck({ now: 0 })
    result = start_wake(Dict.empty({}), qid, msg, 50_000u32, config)
    List.any(result.effects, |e| when e is
        EmitBackpressure(HardLimitReached) -> Bool.true
        _ -> Bool.false)

expect
    # complete_wake from None snapshot produces Awake entry with empty properties
    qid = QuineId.from_bytes([0x01])
    result = complete_wake(Dict.empty({}), qid, None, 1000u64)
    when Dict.get(result.nodes, qid) is
        Ok(Awake({ state })) -> Dict.is_empty(state.properties)
        _ -> Bool.false
