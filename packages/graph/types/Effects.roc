module [
    Effect,
    PersistCommand,
    BackpressureSignal,
]

import id.QuineId exposing [QuineId]
import Ids exposing [RequestId, ShardId]
import Messages exposing [NodeMessage, ReplyPayload]
import standing_result.StandingQueryResult exposing [StandingQueryId, StandingQueryResult]

## A side-effect produced by node logic.
##
## Node processing is pure: it takes a NodeState and a message and returns
## an updated NodeState plus a list of Effects. The shard interpreter then
## executes those effects — routing replies, forwarding messages, persisting
## data, and so on.
##
## This design keeps node logic testable without a running shard.
Effect : [
    ## Send a reply to the request with the given id.
    Reply { request_id : RequestId, payload : ReplyPayload },
    ## Forward a message to another node (may be on a different shard).
    SendToNode { target : QuineId, msg : NodeMessage },
    ## Send an opaque byte payload to the shard with the given id.
    ## Used for cross-shard coordination (e.g. standing query notifications).
    SendToShard { shard_id : ShardId, payload : List U8 },
    ## Durably persist something for this node.
    Persist { command : PersistCommand },
    ## Emit a backpressure signal to the shard.
    EmitBackpressure BackpressureSignal,
    ## Notify the shard that this node's sleep cost has changed.
    UpdateCostToSleep I64,
    ## Emit a standing query result to be sent to consumers.
    EmitSqResult { query_id : StandingQueryId, result : StandingQueryResult },
]

## A durable persistence operation requested by a node.
PersistCommand : [
    ## Write a snapshot for this node.
    PersistSnapshot { id : QuineId, snapshot_bytes : List U8 },
    ## Load the most recent snapshot for this node (triggers an async reply).
    LoadSnapshot { id : QuineId },
]

## A signal from a node (or shard) indicating that the system is under
## too much load and callers should slow down.
BackpressureSignal : [
    ## The shard has hit the hard node-count ceiling.
    HardLimitReached,
    ## The standing-query output buffer is full.
    SqBufferFull,
    ## Backpressure has cleared; normal rate may resume.
    Clear,
]

# ===== Tests =====

expect
    effect : Effect
    effect = Reply({ request_id: 1, payload: Ack })
    when effect is
        Reply(_) -> Bool.true
        _ -> Bool.false

expect
    effect : Effect
    effect = EmitBackpressure(HardLimitReached)
    when effect is
        EmitBackpressure(HardLimitReached) -> Bool.true
        _ -> Bool.false

expect
    effect : Effect
    effect = EmitBackpressure(SqBufferFull)
    when effect is
        EmitBackpressure(SqBufferFull) -> Bool.true
        _ -> Bool.false

expect
    effect : Effect
    effect = EmitBackpressure(Clear)
    when effect is
        EmitBackpressure(Clear) -> Bool.true
        _ -> Bool.false

expect
    qid = QuineId.from_bytes([0x01])
    effect : Effect
    effect = SendToNode({ target: qid, msg: SleepCheck({ now: 0 }) })
    when effect is
        SendToNode(_) -> Bool.true
        _ -> Bool.false

expect
    effect : Effect
    effect = SendToShard({ shard_id: 0, payload: [0x01, 0x02] })
    when effect is
        SendToShard(_) -> Bool.true
        _ -> Bool.false

expect
    qid = QuineId.from_bytes([0x01])
    effect : Effect
    effect = Persist({ command: PersistSnapshot({ id: qid, snapshot_bytes: [0xDE, 0xAD] }) })
    when effect is
        Persist(_) -> Bool.true
        _ -> Bool.false

expect
    qid = QuineId.from_bytes([0x01])
    effect : Effect
    effect = Persist({ command: LoadSnapshot({ id: qid }) })
    when effect is
        Persist({ command: LoadSnapshot(_) }) -> Bool.true
        _ -> Bool.false

expect
    effect : Effect
    effect = UpdateCostToSleep(5)
    when effect is
        UpdateCostToSleep(5) -> Bool.true
        _ -> Bool.false

expect
    result : StandingQueryResult
    result = { is_positive_match: Bool.true, data: Dict.empty({}) }
    effect : Effect
    effect = EmitSqResult({ query_id: 1u128, result })
    when effect is
        EmitSqResult({ query_id: 1u128 }) -> Bool.true
        _ -> Bool.false
