module [
    dispatch_node_msg,
]

import id.QuineId
import model.PropertyValue
import model.HalfEdge
import types.NodeEntry exposing [NodeState, empty_node_state]
import types.Messages exposing [NodeMessage, LiteralCommand]
import types.Effects exposing [Effect]
import standing_index.WatchableEventIndex
import standing_ast.MvStandingQuery exposing [MvStandingQuery]
import standing_result.StandingQueryResult exposing [StandingQueryPartId, StandingQueryId]
import SqDispatch

## Dispatch a message to the given node state, returning an updated state and
## a list of side-effects the shard should execute.
##
## LiteralCmd messages are dispatched to handle_literal, then node change
## events are derived and routed to any registered SQ states.
## SqCmd messages are routed to SqDispatch.handle_sq_command.
## SleepCheck is a no-op at this layer — the shard itself decides whether
## to proceed with sleep based on the result of should_decline_sleep.
dispatch_node_msg : NodeState, NodeMessage, (StandingQueryPartId -> Result MvStandingQuery [NotFound]) -> { state : NodeState, effects : List Effect }
dispatch_node_msg = |node, msg, lookup_fn|
    when msg is
        LiteralCmd(cmd) ->
            # Capture pre-mutation properties for event derivation
            old_properties = node.properties
            # Apply the literal command
            literal_result = handle_literal(node, cmd)
            # Derive change events
            events = SqDispatch.derive_events(cmd, old_properties)
            # Route events to interested SQ states
            sq_result = SqDispatch.dispatch_sq_events(
                literal_result.state, events, lookup_fn)
            {
                state: sq_result.state,
                effects: List.concat(literal_result.effects, sq_result.effects),
            }

        SqCmd(sq_cmd) ->
            SqDispatch.handle_sq_command(node, sq_cmd, lookup_fn)

        SleepCheck(_) ->
            { state: node, effects: [] }

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
            reply = Reply({ request_id: reply_to, payload: Ack })
            # Only send a reciprocal for originating commands (reply_to > 0).
            # Reciprocals arrive with reply_to = 0 — sending another would loop.
            if reply_to > 0 then
                reciprocal = HalfEdge.reflect(edge, node.id)
                send_reciprocal = SendToNode({ target: edge.other, msg: LiteralCmd(AddEdge({ edge: reciprocal, reply_to: 0 })) })
                { state: new_state, effects: [reply, send_reciprocal] }
            else
                { state: new_state, effects: [reply] }

        RemoveEdge({ edge, reply_to }) ->
            existing = Dict.get(node.edges, edge.edge_type) |> Result.with_default([])
            filtered = List.keep_if(existing, |e| e != edge)
            new_edges =
                if List.is_empty(filtered) then
                    Dict.remove(node.edges, edge.edge_type)
                else
                    Dict.insert(node.edges, edge.edge_type, filtered)
            new_state = { node & edges: new_edges }
            reply = Reply({ request_id: reply_to, payload: Ack })
            if reply_to > 0 then
                reciprocal = HalfEdge.reflect(edge, node.id)
                send_reciprocal = SendToNode({ target: edge.other, msg: LiteralCmd(RemoveEdge({ edge: reciprocal, reply_to: 0 })) })
                { state: new_state, effects: [reply, send_reciprocal] }
            else
                { state: new_state, effects: [reply] }

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
        sq_states: Dict.empty({}),
        watchable_event_index: WatchableEventIndex.empty,
    }
    result = dispatch_node_msg(node, LiteralCmd(GetProps({ reply_to: 1 })), |_| Err(NotFound))
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
        sq_states: Dict.empty({}),
        watchable_event_index: WatchableEventIndex.empty,
    }
    pv = PropertyValue.from_value(Str("alice"))
    result = dispatch_node_msg(node, LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 1 })), |_| Err(NotFound))
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
        sq_states: Dict.empty({}),
        watchable_event_index: WatchableEventIndex.empty,
    }
    pv = PropertyValue.from_value(Str("alice"))
    after_set = dispatch_node_msg(node, LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 1 })), |_| Err(NotFound))
    after_get = dispatch_node_msg(after_set.state, LiteralCmd(GetProps({ reply_to: 2 })), |_| Err(NotFound))
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
        sq_states: Dict.empty({}),
        watchable_event_index: WatchableEventIndex.empty,
    }
    result = dispatch_node_msg(node, LiteralCmd(RemoveProp({ key: "name", reply_to: 1 })), |_| Err(NotFound))
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
        sq_states: Dict.empty({}),
        watchable_event_index: WatchableEventIndex.empty,
    }
    edge = { edge_type: "KNOWS", direction: Outgoing, other: qid_b }
    result = dispatch_node_msg(node, LiteralCmd(AddEdge({ edge, reply_to: 1 })), |_| Err(NotFound))
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
        sq_states: Dict.empty({}),
        watchable_event_index: WatchableEventIndex.empty,
    }
    result = dispatch_node_msg(node, LiteralCmd(GetEdges({ reply_to: 1 })), |_| Err(NotFound))
    when List.first(result.effects) is
        Ok(Reply({ payload: Edges(edges) })) -> List.len(edges) == 2
        _ -> Bool.false

# Integration test: SqCmd(Create) then LiteralCmd(SetProp) produces EmitSqResult
expect
    qid = QuineId.from_bytes([0x01])
    node = empty_node_state(qid)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "age", constraint: Any, aliased_as: Ok("a") })
    pid = MvStandingQuery.query_part_id(query)
    global_id : StandingQueryId
    global_id = 7u128
    lookup = |p| if p == pid then Ok(query) else Err(NotFound)

    # Create subscription via dispatch
    sub_msg : NodeMessage
    sub_msg = SqCmd(CreateSqSubscription({ subscriber: GlobalSubscriber({ global_id }), query, global_id }))
    r1 = dispatch_node_msg(node, sub_msg, lookup)

    # Set property via dispatch
    pv = PropertyValue.from_value(Integer(30))
    set_msg : NodeMessage
    set_msg = LiteralCmd(SetProp({ key: "age", value: pv, reply_to: 1 }))
    r2 = dispatch_node_msg(r1.state, set_msg, lookup)

    # Should have Reply (Ack) + EmitSqResult
    has_ack = List.any(r2.effects, |e| when e is
        Reply({ payload: Ack }) -> Bool.true
        _ -> Bool.false)
    has_sq = List.any(r2.effects, |e| when e is
        EmitSqResult({ query_id }) -> query_id == global_id
        _ -> Bool.false)
    has_ack && has_sq
