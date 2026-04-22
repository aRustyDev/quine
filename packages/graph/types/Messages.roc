module [
    NodeMessage,
    LiteralCommand,
    ReplyPayload,
]

import id.QuineId
import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]
import Ids exposing [RequestId]
import standing_messages.SqMessages exposing [SqCommand]

## A message delivered to a node actor.
##
## LiteralCmd carries a typed command that expects a reply. SleepCheck is
## sent by the shard on its LRU timer to give nodes a chance to decide
## whether to sleep. SqCmd delivers a standing-query lifecycle command.
NodeMessage : [
    LiteralCmd LiteralCommand,
    SleepCheck { now : U64 },
    SqCmd SqCommand,
]

## A typed command delivered to a node, always paired with a RequestId for
## reply routing.
LiteralCommand : [
    GetProps { reply_to : RequestId },
    SetProp { key : Str, value : PropertyValue, reply_to : RequestId },
    RemoveProp { key : Str, reply_to : RequestId },
    AddEdge { edge : HalfEdge, reply_to : RequestId, is_reciprocal : Bool },
    RemoveEdge { edge : HalfEdge, reply_to : RequestId, is_reciprocal : Bool },
    GetEdges { reply_to : RequestId },
]

## The payload carried in a reply from a node back to the shard.
##
## Props and Edges are data-bearing success responses. Ack is the
## acknowledgement for mutations. Err carries a human-readable error string
## for unexpected failures.
ReplyPayload : [
    Props (Dict Str PropertyValue),
    Edges (List HalfEdge),
    NodeState { properties : Dict Str PropertyValue, edges : List HalfEdge },
    Ack,
    Err Str,
]

# ===== Tests =====

expect
    msg = LiteralCmd(GetProps({ reply_to: 0 }))
    when msg is
        LiteralCmd(GetProps(_)) -> Bool.true
        _ -> Bool.false

expect
    pv = PropertyValue.from_value(Str("hello"))
    msg = LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 1 }))
    when msg is
        LiteralCmd(SetProp(_)) -> Bool.true
        _ -> Bool.false

expect
    msg = LiteralCmd(RemoveProp({ key: "x", reply_to: 2 }))
    when msg is
        LiteralCmd(RemoveProp(_)) -> Bool.true
        _ -> Bool.false

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    msg = LiteralCmd(AddEdge({ edge, reply_to: 3, is_reciprocal: Bool.false }))
    when msg is
        LiteralCmd(AddEdge(_)) -> Bool.true
        _ -> Bool.false

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    msg = LiteralCmd(RemoveEdge({ edge, reply_to: 4, is_reciprocal: Bool.false }))
    when msg is
        LiteralCmd(RemoveEdge(_)) -> Bool.true
        _ -> Bool.false

expect
    msg = LiteralCmd(GetEdges({ reply_to: 5 }))
    when msg is
        LiteralCmd(GetEdges(_)) -> Bool.true
        _ -> Bool.false

expect
    msg : NodeMessage
    msg = SleepCheck({ now: 12345 })
    when msg is
        SleepCheck({ now: 12345 }) -> Bool.true
        _ -> Bool.false

expect
    reply : ReplyPayload
    reply = Props(Dict.empty({}))
    when reply is
        Props(_) -> Bool.true
        _ -> Bool.false

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    reply : ReplyPayload
    reply = Edges([edge])
    when reply is
        Edges(_) -> Bool.true
        _ -> Bool.false

expect
    reply : ReplyPayload
    reply = NodeState({ properties: Dict.empty({}), edges: [] })
    when reply is
        NodeState({ properties, edges }) -> Dict.is_empty(properties) and List.is_empty(edges)
        _ -> Bool.false

expect
    reply : ReplyPayload
    reply = Ack
    when reply is
        Ack -> Bool.true
        _ -> Bool.false

expect
    reply : ReplyPayload
    reply = Err("something went wrong")
    when reply is
        Err(_) -> Bool.true
        _ -> Bool.false

expect
    msg : NodeMessage
    msg = SqCmd(UpdateStandingQueries)
    when msg is
        SqCmd(UpdateStandingQueries) -> Bool.true
        _ -> Bool.false
