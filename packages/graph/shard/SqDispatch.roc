module [
    derive_events,
    dispatch_sq_events,
    handle_sq_command,
]

import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import types.Messages exposing [LiteralCommand]
import id.QuineId exposing [QuineId]
import types.NodeEntry exposing [NodeState, SqStateKey, SqNodeState]
import types.Effects exposing [Effect]
import standing_index.WatchableEventIndex exposing [SqSubscriber]
import standing_state.SqPartState exposing [SqEffect, SqContext, SqSubscription, SqMsgSubscriber, SubscriptionResult, create_state]
import standing_state.StateDispatch
import standing_ast.MvStandingQuery exposing [MvStandingQuery, relevant_event_types]
import standing_result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId]
import standing_messages.SqMessages exposing [SqCommand]

## Compute the query part id for a standing query.
## Wraps MvStandingQuery.query_part_id to avoid name conflicts with record fields.
compute_part_id : MvStandingQuery -> StandingQueryPartId
compute_part_id = |query|
    MvStandingQuery.query_part_id(query)

## Derive NodeChangeEvents from a LiteralCommand and pre-mutation properties.
##
## SetProp -> PropertySet (value from command)
## RemoveProp -> PropertyRemoved (previous value from old_properties; no event if key absent)
## AddEdge -> EdgeAdded
## RemoveEdge -> EdgeRemoved
## GetProps, GetEdges -> no events (reads don't mutate)
derive_events : LiteralCommand, Dict Str PropertyValue -> List NodeChangeEvent
derive_events = |cmd, old_properties|
    when cmd is
        SetProp({ key, value }) ->
            [PropertySet({ key, value })]

        RemoveProp({ key }) ->
            when Dict.get(old_properties, key) is
                Ok(prev) -> [PropertyRemoved({ key, previous_value: prev })]
                Err(_) -> []

        AddEdge({ edge }) -> [EdgeAdded(edge)]
        RemoveEdge({ edge }) -> [EdgeRemoved(edge)]
        GetProps(_) -> []
        GetEdges(_) -> []

## Build an SqContext from a NodeState and a lookup function.
build_sq_context : NodeState, (StandingQueryPartId -> Result MvStandingQuery [NotFound]) -> SqContext
build_sq_context = |node, lookup_fn|
    {
        lookup_query: lookup_fn,
        executing_node_id: node.id,
        current_properties: node.properties,
        labels_property_key: "__labels",
    }

## Remove duplicate SqSubscribers by (global_id, part_id).
deduplicate_subscribers : List SqSubscriber -> List SqSubscriber
deduplicate_subscribers = |subscribers|
    List.walk(subscribers, [], |acc, sub|
        if List.any(acc, |existing| existing.global_id == sub.global_id && existing.part_id == sub.part_id) then
            acc
        else
            List.append(acc, sub)
    )

## Route NodeChangeEvents to interested SQ states.
##
## For each event, finds subscribers in the WatchableEventIndex, deduplicates
## them, then dispatches the events to each subscriber's state via StateDispatch.
dispatch_sq_events : NodeState, List NodeChangeEvent, (StandingQueryPartId -> Result MvStandingQuery [NotFound]) -> { state : NodeState, effects : List Effect }
dispatch_sq_events = |node, events, lookup_fn|
    if Dict.is_empty(node.sq_states) then
        { state: node, effects: [] }
    else
        # Collect all subscribers interested in any of the events
        all_subscribers = List.walk(events, [], |acc, event|
            subs = WatchableEventIndex.subscribers_for_event(node.watchable_event_index, event)
            List.concat(acc, subs)
        )
        unique_subscribers = deduplicate_subscribers(all_subscribers)

        # For each subscriber, dispatch the events to their state
        ctx = build_sq_context(node, lookup_fn)

        List.walk(unique_subscribers, { state: node, effects: [] }, |acc, subscriber|
            key : SqStateKey
            key = { global_id: subscriber.global_id, part_id: subscriber.part_id }
            current_node = acc.state
            when Dict.get(current_node.sq_states, key) is
                Ok(sq_node_state) ->
                    when lookup_fn(subscriber.part_id) is
                        Ok(query) ->
                            # Update context with current state
                            updated_ctx = { ctx & current_properties: current_node.properties }
                            dispatch_result = StateDispatch.dispatch_on_node_events(
                                sq_node_state.state, events, query, updated_ctx)
                            new_sq_node_state = { sq_node_state & state: dispatch_result.state }
                            new_sq_states = Dict.insert(current_node.sq_states, key, new_sq_node_state)
                            new_node = { current_node & sq_states: new_sq_states }
                            translated = translate_sq_effects(
                                dispatch_result.effects, sq_node_state.subscription, current_node.id)
                            { state: new_node, effects: List.concat(acc.effects, translated) }

                        Err(NotFound) ->
                            acc

                Err(_) ->
                    acc
        )

## Translate SqEffects into graph-level Effects.
translate_sq_effects : List SqEffect, SqSubscription, QuineId -> List Effect
translate_sq_effects = |sq_effects, subscription, executing_node_id|
    List.walk(sq_effects, [], |acc, sq_effect|
        when sq_effect is
            CreateSubscription({ on_node, query, global_id: gid, subscriber_part_id }) ->
                msg_subscriber : SqMsgSubscriber
                msg_subscriber = NodeSubscriber({
                    subscribing_node: executing_node_id,
                    global_id: gid,
                    query_part_id: subscriber_part_id,
                })
                effect = SendToNode({
                    target: on_node,
                    msg: SqCmd(CreateSqSubscription({ subscriber: msg_subscriber, query, global_id: gid })),
                })
                List.append(acc, effect)

            CancelSubscription({ on_node, query_part_id: cancel_pid, global_id: cancel_gid }) ->
                msg_subscriber : SqMsgSubscriber
                msg_subscriber = NodeSubscriber({
                    subscribing_node: executing_node_id,
                    global_id: cancel_gid,
                    query_part_id: cancel_pid,
                })
                effect = SendToNode({
                    target: on_node,
                    msg: SqCmd(CancelSqSubscription({ subscriber: msg_subscriber, query_part_id: cancel_pid, global_id: cancel_gid })),
                })
                List.append(acc, effect)

            ReportResults(result_rows) ->
                # For each subscriber, emit the results
                List.walk(subscription.subscribers, acc, |inner_acc, sub|
                    when sub is
                        NodeSubscriber({ subscribing_node, global_id: node_gid, query_part_id: node_pid }) ->
                            sub_result : SubscriptionResult
                            sub_result = {
                                from: executing_node_id,
                                query_part_id: subscription.for_query,
                                global_id: node_gid,
                                for_query_part_id: node_pid,
                                result_group: result_rows,
                            }
                            effect = SendToNode({
                                target: subscribing_node,
                                msg: SqCmd(NewSqResult(sub_result)),
                            })
                            List.append(inner_acc, effect)

                        GlobalSubscriber({ global_id: emit_gid }) ->
                            # Emit one EmitSqResult per result row
                            List.walk(result_rows, inner_acc, |row_acc, row|
                                sq_result = { is_positive_match: Bool.true, data: row }
                                effect = EmitSqResult({ query_id: emit_gid, result: sq_result })
                                List.append(row_acc, effect)
                            )
                )
    )

## Handle an SqCommand delivered to a node.
handle_sq_command : NodeState, SqCommand, (StandingQueryPartId -> Result MvStandingQuery [NotFound]) -> { state : NodeState, effects : List Effect }
handle_sq_command = |node, sq_cmd, lookup_fn|
    when sq_cmd is
        CreateSqSubscription({ subscriber, query, global_id }) ->
            handle_create_subscription(node, subscriber, query, global_id, lookup_fn)

        CancelSqSubscription({ query_part_id: cancel_pid, global_id: cancel_gid }) ->
            handle_cancel_subscription(node, cancel_pid, cancel_gid)

        NewSqResult(sub_result) ->
            handle_new_sq_result(node, sub_result, lookup_fn)

        UpdateStandingQueries ->
            { state: node, effects: [] }

## Handle creation of a new standing query subscription on a node.
handle_create_subscription : NodeState, SqMsgSubscriber, MvStandingQuery, StandingQueryId, (StandingQueryPartId -> Result MvStandingQuery [NotFound]) -> { state : NodeState, effects : List Effect }
handle_create_subscription = |node, subscriber, query, global_id, lookup_fn|
    part_id = compute_part_id(query)
    key : SqStateKey
    key = { global_id, part_id }

    when Dict.get(node.sq_states, key) is
        Ok(existing_sq_node_state) ->
            # Key already exists — just add the subscriber
            existing_sub = existing_sq_node_state.subscription
            new_subscribers = List.append(existing_sub.subscribers, subscriber)
            new_sub = { existing_sub & subscribers: new_subscribers }
            updated_sq_node_state = { existing_sq_node_state & subscription: new_sub }
            new_sq_states = Dict.insert(node.sq_states, key, updated_sq_node_state)
            new_node = { node & sq_states: new_sq_states }
            { state: new_node, effects: [] }

        Err(_) ->
            # New subscription — create state, initialize, register, seed
            initial_state = create_state(query)
            subscription : SqSubscription
            subscription = { for_query: part_id, global_id, subscribers: [subscriber] }

            ctx = build_sq_context(node, lookup_fn)

            # Initialize the state
            init_result = StateDispatch.dispatch_on_initialize(initial_state, query, ctx)

            # Register event types in the WatchableEventIndex
            event_types = relevant_event_types(query, "__labels")
            sq_subscriber : SqSubscriber
            sq_subscriber = { global_id, part_id }

            register_result = List.walk(event_types, { index: node.watchable_event_index, initial_events: [] }, |reg_acc, event_type|
                reg = WatchableEventIndex.register_standing_query(
                    reg_acc.index, sq_subscriber, event_type, node.properties, node.edges)
                # Use field access to avoid ICE
                new_index = reg.index
                new_events = reg.initial_events
                { index: new_index, initial_events: List.concat(reg_acc.initial_events, new_events) }
            )

            new_watchable_index = register_result.index
            initial_events = register_result.initial_events

            # Dispatch initial events to get the state caught up
            updated_ctx = { ctx & current_properties: node.properties }
            events_result = StateDispatch.dispatch_on_node_events(
                init_result.state, initial_events, query, updated_ctx)

            # Store the state
            sq_node_state : SqNodeState
            sq_node_state = { subscription, state: events_result.state }
            new_sq_states = Dict.insert(node.sq_states, key, sq_node_state)
            new_node = { node & sq_states: new_sq_states, watchable_event_index: new_watchable_index }

            # Translate all effects (init + events)
            all_sq_effects = List.concat(init_result.effects, events_result.effects)
            translated = translate_sq_effects(all_sq_effects, subscription, node.id)

            { state: new_node, effects: translated }

## Handle cancellation of a standing query subscription.
handle_cancel_subscription : NodeState, StandingQueryPartId, StandingQueryId -> { state : NodeState, effects : List Effect }
handle_cancel_subscription = |node, part_id, global_id|
    key : SqStateKey
    key = { global_id, part_id }
    new_sq_states = Dict.remove(node.sq_states, key)
    new_node = { node & sq_states: new_sq_states }
    { state: new_node, effects: [] }

## Handle a subscription result from a child node.
handle_new_sq_result : NodeState, SubscriptionResult, (StandingQueryPartId -> Result MvStandingQuery [NotFound]) -> { state : NodeState, effects : List Effect }
handle_new_sq_result = |node, sub_result, lookup_fn|
    key : SqStateKey
    key = { global_id: sub_result.global_id, part_id: sub_result.for_query_part_id }

    when Dict.get(node.sq_states, key) is
        Ok(sq_node_state) ->
            when lookup_fn(sub_result.for_query_part_id) is
                Ok(query) ->
                    ctx = build_sq_context(node, lookup_fn)
                    dispatch_result = StateDispatch.dispatch_on_subscription_result(
                        sq_node_state.state, sub_result, query, ctx)
                    new_sq_node_state = { sq_node_state & state: dispatch_result.state }
                    new_sq_states = Dict.insert(node.sq_states, key, new_sq_node_state)
                    new_node = { node & sq_states: new_sq_states }
                    translated = translate_sq_effects(
                        dispatch_result.effects, sq_node_state.subscription, node.id)
                    { state: new_node, effects: translated }

                Err(NotFound) ->
                    { state: node, effects: [] }

        Err(_) ->
            { state: node, effects: [] }

# ===== Tests =====

import id.QuineId

# --- derive_events tests (original 7) ---

# Test: SetProp produces PropertySet
expect
    pv = PropertyValue.from_value(Str("alice"))
    cmd = SetProp({ key: "name", value: pv, reply_to: 1 })
    events = derive_events(cmd, Dict.empty({}))
    when events is
        [PropertySet({ key: "name" })] -> Bool.true
        _ -> Bool.false

# Test: RemoveProp on existing key produces PropertyRemoved
expect
    pv = PropertyValue.from_value(Str("old"))
    old_props = Dict.insert(Dict.empty({}), "name", pv)
    cmd = RemoveProp({ key: "name", reply_to: 1 })
    events = derive_events(cmd, old_props)
    when events is
        [PropertyRemoved({ key: "name" })] -> Bool.true
        _ -> Bool.false

# Test: RemoveProp on missing key produces no events
expect
    cmd = RemoveProp({ key: "missing", reply_to: 1 })
    events = derive_events(cmd, Dict.empty({}))
    List.is_empty(events)

# Test: AddEdge produces EdgeAdded
expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([2]) }
    cmd = AddEdge({ edge, reply_to: 1 })
    events = derive_events(cmd, Dict.empty({}))
    when events is
        [EdgeAdded(_)] -> Bool.true
        _ -> Bool.false

# Test: RemoveEdge produces EdgeRemoved
expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([2]) }
    cmd = RemoveEdge({ edge, reply_to: 1 })
    events = derive_events(cmd, Dict.empty({}))
    when events is
        [EdgeRemoved(_)] -> Bool.true
        _ -> Bool.false

# Test: GetProps produces no events
expect
    cmd = GetProps({ reply_to: 1 })
    events = derive_events(cmd, Dict.empty({}))
    List.is_empty(events)

# Test: GetEdges produces no events
expect
    cmd = GetEdges({ reply_to: 1 })
    events = derive_events(cmd, Dict.empty({}))
    List.is_empty(events)

# --- dispatch_sq_events and handle_sq_command tests ---

import types.NodeEntry exposing [empty_node_state]

# Test 8: dispatch_sq_events with empty sq_states -> no effects
expect
    qid = QuineId.from_bytes([0x01])
    node = empty_node_state(qid)
    events = [PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })]
    result = dispatch_sq_events(node, events, |_| Err(NotFound))
    List.is_empty(result.effects)

# Test 9: deduplicate_subscribers removes duplicates
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    sub_b : SqSubscriber
    sub_b = { global_id: 2u128, part_id: 20u64 }
    input = [sub_a, sub_b, sub_a, sub_b, sub_a]
    result = deduplicate_subscribers(input)
    List.len(result) == 2

# Test 10: CreateSqSubscription creates state in sq_states
expect
    qid = QuineId.from_bytes([0x01])
    node = empty_node_state(qid)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    global_id : StandingQueryId
    global_id = 5u128
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    sq_cmd : SqCommand
    sq_cmd = CreateSqSubscription({ subscriber, query, global_id })
    result = handle_sq_command(node, sq_cmd, |_| Err(NotFound))
    Dict.len(result.state.sq_states) == 1

# Test 11: CreateSqSubscription on node with existing property -> EmitSqResult
expect
    qid = QuineId.from_bytes([0x01])
    node_base = empty_node_state(qid)
    pv = PropertyValue.from_value(Str("Alice"))
    node = { node_base & properties: Dict.insert(Dict.empty({}), "name", pv) }
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    pid = compute_part_id(query)
    global_id : StandingQueryId
    global_id = 5u128
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    lookup = |p| if p == pid then Ok(query) else Err(NotFound)
    sq_cmd : SqCommand
    sq_cmd = CreateSqSubscription({ subscriber, query, global_id })
    result = handle_sq_command(node, sq_cmd, lookup)
    List.any(result.effects, |e|
        when e is
            EmitSqResult({ query_id }) -> query_id == global_id
            _ -> Bool.false
    )

# Test 12: CancelSqSubscription removes state
expect
    qid = QuineId.from_bytes([0x01])
    node = empty_node_state(qid)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "age", constraint: Any, aliased_as: Ok("a") })
    pid = compute_part_id(query)
    global_id : StandingQueryId
    global_id = 7u128
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    lookup = |p| if p == pid then Ok(query) else Err(NotFound)
    # First create
    create_cmd : SqCommand
    create_cmd = CreateSqSubscription({ subscriber, query, global_id })
    r1 = handle_sq_command(node, create_cmd, lookup)
    # Then cancel
    cancel_cmd : SqCommand
    cancel_cmd = CancelSqSubscription({ subscriber, query_part_id: pid, global_id })
    r2 = handle_sq_command(r1.state, cancel_cmd, lookup)
    Dict.is_empty(r2.state.sq_states)

# Test 13: NewSqResult with no matching state -> no effects
expect
    qid = QuineId.from_bytes([0x01])
    node = empty_node_state(qid)
    sub_result : SubscriptionResult
    sub_result = {
        from: QuineId.from_bytes([0x02]),
        query_part_id: 99u64,
        global_id: 1u128,
        for_query_part_id: 42u64,
        result_group: [Dict.empty({})],
    }
    sq_cmd : SqCommand
    sq_cmd = NewSqResult(sub_result)
    result = handle_sq_command(node, sq_cmd, |_| Err(NotFound))
    List.is_empty(result.effects)

# Test 14: UpdateStandingQueries -> no effects
expect
    qid = QuineId.from_bytes([0x01])
    node = empty_node_state(qid)
    sq_cmd : SqCommand
    sq_cmd = UpdateStandingQueries
    result = handle_sq_command(node, sq_cmd, |_| Err(NotFound))
    List.is_empty(result.effects)

# Integration test: full single-node property match lifecycle
# 1. Register SQ for property "name" with Any constraint
# 2. Set property "name" on the node
# 3. Verify EmitSqResult is produced with the correct query_id
expect
    qid = QuineId.from_bytes([0x01])
    node0 = empty_node_state(qid)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    pid = compute_part_id(query)
    global_id = 42u128
    lookup = |p| if p == pid then Ok(query) else Err(NotFound)

    # Step 1: Create subscription
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    create_cmd : SqCommand
    create_cmd = CreateSqSubscription({ subscriber, query, global_id })
    r1 = handle_sq_command(node0, create_cmd, lookup)

    # Verify state was created
    key : SqStateKey
    key = { global_id, part_id: pid }
    has_state = Dict.contains(r1.state.sq_states, key)

    # Step 2: Set property — dispatch the event
    pv = PropertyValue.from_value(Str("alice"))
    events = [PropertySet({ key: "name", value: pv })]
    r2 = dispatch_sq_events(r1.state, events, lookup)

    # Step 3: Verify EmitSqResult with correct query_id
    has_emit = List.any(r2.effects, |e|
        when e is
            EmitSqResult({ query_id }) -> query_id == global_id
            _ -> Bool.false)

    has_state && has_emit

# Test 15: Full lifecycle - create subscription then dispatch PropertySet -> EmitSqResult
expect
    qid = QuineId.from_bytes([0x01])
    node = empty_node_state(qid)
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "score", constraint: Any, aliased_as: Ok("s") })
    pid = compute_part_id(query)
    global_id : StandingQueryId
    global_id = 10u128
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    lookup = |p| if p == pid then Ok(query) else Err(NotFound)

    # Create subscription
    create_cmd : SqCommand
    create_cmd = CreateSqSubscription({ subscriber, query, global_id })
    r1 = handle_sq_command(node, create_cmd, lookup)

    # Now dispatch a PropertySet event
    pv = PropertyValue.from_value(Integer(42))
    events = [PropertySet({ key: "score", value: pv })]
    r2 = dispatch_sq_events(r1.state, events, lookup)

    # Should produce EmitSqResult
    List.any(r2.effects, |e|
        when e is
            EmitSqResult({ query_id }) -> query_id == global_id
            _ -> Bool.false
    )

# Integration test: register SQ on shard, dispatch to node, verify result
expect
    # Setup: create shard with one awake node
    qid = QuineId.from_bytes([0x01])
    node0 = empty_node_state(qid)

    # Create a LocalProperty SQ watching "status" with Any constraint
    query : MvStandingQuery
    query = LocalProperty({ prop_key: "status", constraint: Any, aliased_as: Ok("s") })
    pid = compute_part_id(query)
    global_id : StandingQueryId
    global_id = 100u128

    # Build lookup function
    lookup = |p| if p == pid then Ok(query) else Err(NotFound)

    # Step 1: Create subscription on the node
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    create_cmd : SqCommand
    create_cmd = CreateSqSubscription({ subscriber, query, global_id })
    r1 = handle_sq_command(node0, create_cmd, lookup)
    has_state = Dict.len(r1.state.sq_states) == 1

    # Step 2: Set property "status" = "active"
    pv = PropertyValue.from_value(Str("active"))
    events = [PropertySet({ key: "status", value: pv })]
    r2 = dispatch_sq_events(r1.state, events, lookup)

    # Step 3: Verify EmitSqResult with positive match
    has_emit = List.any(r2.effects, |e|
        when e is
            EmitSqResult({ query_id: qid_val, result }) ->
                qid_val == global_id && result.is_positive_match
            _ -> Bool.false)

    # Step 4: Change property to different value
    pv2 = PropertyValue.from_value(Str("inactive"))
    events2 = [PropertySet({ key: "status", value: pv2 })]
    r3 = dispatch_sq_events(r2.state, events2, lookup)

    # Should still produce EmitSqResult (value changed but still matches Any)
    has_emit2 = List.any(r3.effects, |e|
        when e is
            EmitSqResult(_) -> Bool.true
            _ -> Bool.false)

    has_state && has_emit && has_emit2
