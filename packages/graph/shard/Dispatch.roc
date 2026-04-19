module [
    dispatch_node_msg,
]

import id.QuineId
import model.PropertyValue
import model.HalfEdge
import types.NodeEntry exposing [NodeState]
import types.Messages exposing [NodeMessage, LiteralCommand]
import types.Effects exposing [Effect]

## Dispatch a message to the given node state, returning an updated state and
## a list of side-effects the shard should execute.
##
## LiteralCmd messages are dispatched to handle_literal. SleepCheck is a
## no-op at this layer — the shard itself decides whether to proceed with
## sleep based on the result of should_decline_sleep.
dispatch_node_msg : NodeState, NodeMessage -> { state : NodeState, effects : List Effect }
dispatch_node_msg = |node, msg|
    when msg is
        LiteralCmd(cmd) -> handle_literal(node, cmd)
        SleepCheck(_) -> { state: node, effects: [] }

## Handle a LiteralCommand against a node's live state.
##
## Each variant reads from or mutates node.properties / node.edges and
## returns any Reply and SendToNode effects the shard must execute.
handle_literal : NodeState, LiteralCommand -> { state : NodeState, effects : List Effect }
handle_literal = |node, cmd|
    when cmd is
        GetProps({ reply_to }) ->
            reply = Reply({ request_id: reply_to, payload: Props(node.properties) })
            { state: node, effects: [reply] }

        SetProp({ key, value, reply_to }) ->
            new_props = Dict.insert(node.properties, key, value)
            new_state = { node & properties: new_props }
            reply = Reply({ request_id: reply_to, payload: Ack })
            { state: new_state, effects: [reply] }

        RemoveProp({ key, reply_to }) ->
            new_props = Dict.remove(node.properties, key)
            new_state = { node & properties: new_props }
            reply = Reply({ request_id: reply_to, payload: Ack })
            { state: new_state, effects: [reply] }

        AddEdge({ edge, reply_to }) ->
            existing = Dict.get(node.edges, edge.edge_type) |> Result.with_default([])
            new_list = List.append(existing, edge)
            new_edges = Dict.insert(node.edges, edge.edge_type, new_list)
            new_state = { node & edges: new_edges }
            reciprocal = HalfEdge.reflect(edge, node.id)
            send_reciprocal = SendToNode({ target: edge.other, msg: LiteralCmd(AddEdge({ edge: reciprocal, reply_to: 0 })) })
            reply = Reply({ request_id: reply_to, payload: Ack })
            { state: new_state, effects: [reply, send_reciprocal] }

        RemoveEdge({ edge, reply_to }) ->
            existing = Dict.get(node.edges, edge.edge_type) |> Result.with_default([])
            filtered = List.keep_if(existing, |e| e != edge)
            new_edges =
                if List.is_empty(filtered) then
                    Dict.remove(node.edges, edge.edge_type)
                else
                    Dict.insert(node.edges, edge.edge_type, filtered)
            new_state = { node & edges: new_edges }
            reciprocal = HalfEdge.reflect(edge, node.id)
            send_reciprocal = SendToNode({ target: edge.other, msg: LiteralCmd(RemoveEdge({ edge: reciprocal, reply_to: 0 })) })
            reply = Reply({ request_id: reply_to, payload: Ack })
            { state: new_state, effects: [reply, send_reciprocal] }

        GetEdges({ reply_to }) ->
            all_edges = Dict.walk(node.edges, [], |acc, _key, edge_list| List.concat(acc, edge_list))
            reply = Reply({ request_id: reply_to, payload: Edges(all_edges) })
            { state: node, effects: [reply] }

# ===== Tests =====

expect
    # GetProps on empty node returns Reply with empty Dict
    qid = QuineId.from_bytes([0x01])
    node = {
        id: qid,
        properties: Dict.empty({}),
        edges: Dict.empty({}),
        journal: [],
        snapshot_base: None,
        edge_storage: Inline,
    }
    result = dispatch_node_msg(node, LiteralCmd(GetProps({ reply_to: 1 })))
    when List.first(result.effects) is
        Ok(Reply({ payload: Props(props) })) -> Dict.is_empty(props)
        _ -> Bool.false

expect
    # SetProp adds a property (Dict.len == 1)
    qid = QuineId.from_bytes([0x01])
    node = {
        id: qid,
        properties: Dict.empty({}),
        edges: Dict.empty({}),
        journal: [],
        snapshot_base: None,
        edge_storage: Inline,
    }
    pv = PropertyValue.from_value(Str("alice"))
    result = dispatch_node_msg(node, LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 1 })))
    Dict.len(result.state.properties) == 1

expect
    # SetProp then GetProps returns the stored value
    qid = QuineId.from_bytes([0x01])
    node = {
        id: qid,
        properties: Dict.empty({}),
        edges: Dict.empty({}),
        journal: [],
        snapshot_base: None,
        edge_storage: Inline,
    }
    pv = PropertyValue.from_value(Str("alice"))
    after_set = dispatch_node_msg(node, LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 1 })))
    after_get = dispatch_node_msg(after_set.state, LiteralCmd(GetProps({ reply_to: 2 })))
    when List.first(after_get.effects) is
        Ok(Reply({ payload: Props(props) })) -> Dict.contains(props, "name")
        _ -> Bool.false

expect
    # RemoveProp removes a property
    qid = QuineId.from_bytes([0x01])
    pv = PropertyValue.from_value(Str("alice"))
    node = {
        id: qid,
        properties: Dict.insert(Dict.empty({}), "name", pv),
        edges: Dict.empty({}),
        journal: [],
        snapshot_base: None,
        edge_storage: Inline,
    }
    result = dispatch_node_msg(node, LiteralCmd(RemoveProp({ key: "name", reply_to: 1 })))
    Dict.is_empty(result.state.properties)

expect
    # AddEdge creates edge and emits SendToNode for reciprocal
    qid_a = QuineId.from_bytes([0x0A])
    qid_b = QuineId.from_bytes([0x0B])
    node = {
        id: qid_a,
        properties: Dict.empty({}),
        edges: Dict.empty({}),
        journal: [],
        snapshot_base: None,
        edge_storage: Inline,
    }
    edge = { edge_type: "KNOWS", direction: Outgoing, other: qid_b }
    result = dispatch_node_msg(node, LiteralCmd(AddEdge({ edge, reply_to: 1 })))
    # Should have reply + SendToNode
    has_reply = List.any(result.effects, |e| when e is
        Reply({ payload: Ack }) -> Bool.true
        _ -> Bool.false)
    has_send = List.any(result.effects, |e| when e is
        SendToNode({ target }) -> target == qid_b
        _ -> Bool.false)
    has_reply and has_send

expect
    # GetEdges returns all edges (flat list across all edge types)
    qid = QuineId.from_bytes([0x01])
    other1 = QuineId.from_bytes([0x02])
    other2 = QuineId.from_bytes([0x03])
    edge1 = { edge_type: "KNOWS", direction: Outgoing, other: other1 }
    edge2 = { edge_type: "FOLLOWS", direction: Outgoing, other: other2 }
    edges_dict =
        Dict.empty({})
        |> Dict.insert("KNOWS", [edge1])
        |> Dict.insert("FOLLOWS", [edge2])
    node = {
        id: qid,
        properties: Dict.empty({}),
        edges: edges_dict,
        journal: [],
        snapshot_base: None,
        edge_storage: Inline,
    }
    result = dispatch_node_msg(node, LiteralCmd(GetEdges({ reply_to: 1 })))
    when List.first(result.effects) is
        Ok(Reply({ payload: Edges(edges) })) -> List.len(edges) == 2
        _ -> Bool.false
