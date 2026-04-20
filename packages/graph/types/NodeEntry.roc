module [
    NodeEntry,
    WakefulState,
    NodeState,
    SqStateKey,
    SqNodeState,
    empty_node_state,
    compute_cost_to_sleep,
]

import id.QuineId exposing [QuineId]
import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]
import model.NodeEvent exposing [TimestampedEvent]
import model.NodeSnapshot exposing [NodeSnapshot]
import Messages exposing [NodeMessage]
import standing_index.WatchableEventIndex exposing [WatchableEventIndex]
import standing_state.SqPartState exposing [SqPartState, SqSubscription]
import standing_result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId]

## The in-memory lifecycle state of a node slot in a shard.
##
## A shard entry is either fully awake with live state, or in the process of
## waking up (Waking) with a backlog of queued messages waiting for the node
## to become ready. Once awake the shard can dispatch messages directly.
NodeEntry : [
    Awake {
        state : NodeState,
        wakeful : WakefulState,
        cost_to_sleep : I64,
        last_write : U64,
        last_access : U64,
    },
    Waking { queued : List NodeMessage },
]

## Whether a fully-awake node is actively processing or on the path to sleep.
##
## ConsideringSleep carries a deadline: if the node does not receive a new
## message before the deadline, the shard will finalize the sleep transition.
WakefulState : [
    Awake,
    ConsideringSleep { deadline : U64 },
]

## Uniquely identifies one standing query part's state on a given node.
##
## Combines the top-level standing query ID with the specific part ID so that
## multiple parts of the same standing query can each have independent state.
SqStateKey : {
    global_id : StandingQueryId,
    part_id : StandingQueryPartId,
}

## Per-node per-part standing query state.
##
## Holds both the subscription record (who is subscribed to this part's output)
## and the evaluator state (what the part has seen so far).
SqNodeState : {
    subscription : SqSubscription,
    state : SqPartState,
}

## A node's live in-memory state held by an awake shard entry.
##
## This is the graph-layer view of node data. It extends the core model's
## NodeState with the node's own QuineId (needed to compute derived data),
## a journal of events since the last snapshot, and a snapshot base for
## write-back on sleep.
##
## edges is keyed by edge_type for efficient per-type lookup; the List of
## HalfEdge per key holds all edges of that type (across all directions).
##
## sq_states holds per-part standing query evaluation state, keyed by
## (global_id, part_id). watchable_event_index provides O(1) lookup of
## which SQ parts to notify when this node's properties or edges change.
NodeState : {
    id : QuineId,
    properties : Dict Str PropertyValue,
    edges : Dict Str (List HalfEdge),
    journal : List TimestampedEvent,
    snapshot_base : [None, Some NodeSnapshot],
    edge_storage : [Inline],
    sq_states : Dict SqStateKey SqNodeState,
    watchable_event_index : WatchableEventIndex,
}

## Create a fresh, empty NodeState for the given node id.
empty_node_state : QuineId -> NodeState
empty_node_state = |qid|
    {
        id: qid,
        properties: Dict.empty({}),
        edges: Dict.empty({}),
        journal: [],
        snapshot_base: None,
        edge_storage: Inline,
        sq_states: Dict.empty({}),
        watchable_event_index: WatchableEventIndex.empty,
    }

## Approximate log base-2 of n (integer, floor).
##
## Returns 0 for n == 0. Used to compute cost_to_sleep without floating point.
log2_approx : U64 -> I64
log2_approx = |n|
    if n == 0 then
        0
    else
        helper = |remaining, acc|
            if remaining <= 1 then
                acc
            else
                helper(Num.shift_right_zf_by(remaining, 1), acc + 1)
        helper(n, 0)

## Compute the cost-to-sleep for a node.
##
## Cost is max(0, log2(total_edge_count) - 2). Nodes with 4 or fewer edges
## have zero cost. Above that, nodes with more edges are more expensive to
## evict (they hold more graph topology in memory that is costly to restore).
##
## The total edge count sums all HalfEdge values across all edge_type buckets.
compute_cost_to_sleep : NodeState -> I64
compute_cost_to_sleep = |state|
    edge_count = Dict.walk(
        state.edges,
        0u64,
        |acc, _key, edge_list| acc + List.len(edge_list),
    )
    raw = log2_approx(edge_count) - 2
    if raw < 0 then 0 else raw

# ===== Tests =====

expect
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    Dict.is_empty(ns.properties)

expect
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    Dict.is_empty(ns.edges)

expect
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    List.is_empty(ns.journal)

expect
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    when ns.snapshot_base is
        None -> Bool.true
        _ -> Bool.false

expect
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    cost = compute_cost_to_sleep(ns)
    cost == 0

expect
    log2_approx(1) == 0

expect
    log2_approx(2) == 1

expect
    log2_approx(8) == 3

expect
    log2_approx(1024) == 10

expect
    log2_approx(0) == 0

expect
    # Nodes with 4 or fewer edges have zero cost
    qid = QuineId.from_bytes([0x01])
    edge1 = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([2]) }
    edge2 = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([3]) }
    ns = empty_node_state(qid)
    ns2 = { ns & edges: Dict.insert(ns.edges, "KNOWS", [edge1, edge2]) }
    compute_cost_to_sleep(ns2) == 0

expect
    # 8 edges gives cost = log2(8) - 2 = 3 - 2 = 1
    qid = QuineId.from_bytes([0x01])
    make_edge = |i| { edge_type: "REL", direction: Outgoing, other: QuineId.from_bytes([i]) }
    edge_list = List.range({ start: At(2), end: Before(10) }) |> List.map(Num.to_u8) |> List.map(make_edge)
    ns = empty_node_state(qid)
    ns2 = { ns & edges: Dict.insert(ns.edges, "REL", edge_list) }
    compute_cost_to_sleep(ns2) == 1

expect
    # Waking variant can hold a queue of messages
    entry : NodeEntry
    entry = Waking({ queued: [SleepCheck({ now: 0 })] })
    when entry is
        Waking({ queued }) -> List.len(queued) == 1
        _ -> Bool.false

expect
    # Awake variant can be constructed
    qid = QuineId.from_bytes([0x01])
    ns = empty_node_state(qid)
    entry : NodeEntry
    entry = Awake({
        state: ns,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: 0,
        last_access: 0,
    })
    when entry is
        Awake(_) -> Bool.true
        _ -> Bool.false

expect
    # ConsideringSleep variant of WakefulState
    ws : WakefulState
    ws = ConsideringSleep({ deadline: 9999 })
    when ws is
        ConsideringSleep({ deadline: 9999 }) -> Bool.true
        _ -> Bool.false
