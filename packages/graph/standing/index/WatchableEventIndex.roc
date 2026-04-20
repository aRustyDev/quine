module [
    WatchableEventIndex,
    SqSubscriber,
    empty,
    register_standing_query,
    unregister_standing_query,
    subscribers_for_event,
]

import id.QuineId
import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]
import model.NodeEvent exposing [NodeChangeEvent]
import ast.MvStandingQuery exposing [WatchableEventType]
import result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId]

## A subscriber identified by the global standing query ID and the part ID.
SqSubscriber : {
    global_id : StandingQueryId,
    part_id : StandingQueryPartId,
}

## Per-node index mapping watchable events to interested SQ subscribers.
##
## Provides O(1) lookup of which SQ states to notify when a node changes.
WatchableEventIndex : {
    watching_for_property : Dict Str (List SqSubscriber),
    watching_for_edge : Dict Str (List SqSubscriber),
    watching_for_any_edge : List SqSubscriber,
    watching_for_any_property : List SqSubscriber,
}

## Construct an empty index with no subscribers.
empty : WatchableEventIndex
empty = {
    watching_for_property: Dict.empty({}),
    watching_for_edge: Dict.empty({}),
    watching_for_any_edge: [],
    watching_for_any_property: [],
}

## Add a subscriber to the index slot for the given event type.
##
## Also returns the initial NodeChangeEvents derived from the current node
## state, so the subscriber can be immediately caught up on existing data.
register_standing_query :
    WatchableEventIndex,
    SqSubscriber,
    WatchableEventType,
    Dict Str PropertyValue,
    Dict Str (List HalfEdge)
    -> { index : WatchableEventIndex, initial_events : List NodeChangeEvent }
register_standing_query = |index, subscriber, event_type, current_properties, current_edges|
    when event_type is
        PropertyChange(key) ->
            existing = Dict.get(index.watching_for_property, key) |> Result.with_default([])
            updated_slot = List.append(existing, subscriber)
            new_index = { index & watching_for_property: Dict.insert(index.watching_for_property, key, updated_slot) }
            initial_events =
                when Dict.get(current_properties, key) is
                    Ok(value) -> [PropertySet({ key, value })]
                    Err(_) -> []
            { index: new_index, initial_events }

        AnyPropertyChange ->
            new_any_prop = List.append(index.watching_for_any_property, subscriber)
            new_index = { index & watching_for_any_property: new_any_prop }
            initial_events =
                Dict.walk(current_properties, [], |acc, key, value|
                    List.append(acc, PropertySet({ key, value }))
                )
            { index: new_index, initial_events }

        EdgeChange(Ok(key)) ->
            existing = Dict.get(index.watching_for_edge, key) |> Result.with_default([])
            updated_slot = List.append(existing, subscriber)
            new_index = { index & watching_for_edge: Dict.insert(index.watching_for_edge, key, updated_slot) }
            initial_events =
                when Dict.get(current_edges, key) is
                    Ok(edges) -> List.map(edges, |he| EdgeAdded(he))
                    Err(_) -> []
            { index: new_index, initial_events }

        EdgeChange(Err(AnyLabel)) ->
            new_any_edge = List.append(index.watching_for_any_edge, subscriber)
            new_index = { index & watching_for_any_edge: new_any_edge }
            initial_events =
                Dict.walk(current_edges, [], |acc, _key, edges|
                    List.concat(acc, List.map(edges, |he| EdgeAdded(he)))
                )
            { index: new_index, initial_events }

## Remove a subscriber from the index slot for the given event type.
##
## If the slot becomes empty after removal, the dict key is deleted.
unregister_standing_query :
    WatchableEventIndex,
    SqSubscriber,
    WatchableEventType
    -> WatchableEventIndex
unregister_standing_query = |index, subscriber, event_type|
    when event_type is
        PropertyChange(key) ->
            existing = Dict.get(index.watching_for_property, key) |> Result.with_default([])
            filtered = List.keep_if(existing, |sub| sub != subscriber)
            new_dict =
                if List.is_empty(filtered) then
                    Dict.remove(index.watching_for_property, key)
                else
                    Dict.insert(index.watching_for_property, key, filtered)
            { index & watching_for_property: new_dict }

        AnyPropertyChange ->
            filtered = List.keep_if(index.watching_for_any_property, |sub| sub != subscriber)
            { index & watching_for_any_property: filtered }

        EdgeChange(Ok(key)) ->
            existing = Dict.get(index.watching_for_edge, key) |> Result.with_default([])
            filtered = List.keep_if(existing, |sub| sub != subscriber)
            new_dict =
                if List.is_empty(filtered) then
                    Dict.remove(index.watching_for_edge, key)
                else
                    Dict.insert(index.watching_for_edge, key, filtered)
            { index & watching_for_edge: new_dict }

        EdgeChange(Err(AnyLabel)) ->
            filtered = List.keep_if(index.watching_for_any_edge, |sub| sub != subscriber)
            { index & watching_for_any_edge: filtered }

## Return all subscribers interested in a given node change event.
##
## - PropertySet / PropertyRemoved: returns subscribers for that key + any-property subscribers
## - EdgeAdded / EdgeRemoved: returns subscribers for that edge_type + any-edge subscribers
subscribers_for_event :
    WatchableEventIndex,
    NodeChangeEvent
    -> List SqSubscriber
subscribers_for_event = |index, event|
    when event is
        PropertySet({ key }) ->
            by_key = Dict.get(index.watching_for_property, key) |> Result.with_default([])
            List.concat(by_key, index.watching_for_any_property)

        PropertyRemoved({ key }) ->
            by_key = Dict.get(index.watching_for_property, key) |> Result.with_default([])
            List.concat(by_key, index.watching_for_any_property)

        EdgeAdded(half_edge) ->
            by_type = Dict.get(index.watching_for_edge, half_edge.edge_type) |> Result.with_default([])
            List.concat(by_type, index.watching_for_any_edge)

        EdgeRemoved(half_edge) ->
            by_type = Dict.get(index.watching_for_edge, half_edge.edge_type) |> Result.with_default([])
            List.concat(by_type, index.watching_for_any_edge)

# ===== Tests =====

# Test 1: Empty index returns no subscribers for any event
expect
    idx = empty
    edge : HalfEdge
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x01]) }
    List.len(subscribers_for_event(idx, PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) }))) == 0
    && List.len(subscribers_for_event(idx, EdgeAdded(edge))) == 0

# Test 2: Register for PropertyChange, lookup finds subscriber
# Note: Workaround for Roc compiler ICE (inc_dec.rs:400) — use field access
# instead of destructuring on records that combine WatchableEventIndex + List NodeChangeEvent.
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    r2 = register_standing_query(idx, sub_a, PropertyChange("name"), Dict.empty({}), Dict.empty({}))
    subs = subscribers_for_event(r2.index, PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) }))
    List.len(subs) == 1 && List.contains(subs, sub_a)

# Test 3: PropertyChange registration returns initial event if property exists
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    props = Dict.insert(Dict.empty({}), "color", PropertyValue.from_value(Str("red")))
    r3 = register_standing_query(idx, sub_a, PropertyChange("color"), props, Dict.empty({}))
    when r3.initial_events is
        [PropertySet({ key: "color" })] -> Bool.true
        _ -> Bool.false

# Test 4: PropertyChange registration returns no initial event if property absent
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    r4 = register_standing_query(idx, sub_a, PropertyChange("missing"), Dict.empty({}), Dict.empty({}))
    List.is_empty(r4.initial_events)

# Test 5: EdgeChange registration returns initial events for existing edges
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    he : HalfEdge
    he = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x01]) }
    edges = Dict.insert(Dict.empty({}), "KNOWS", [he])
    r5 = register_standing_query(idx, sub_a, EdgeChange(Ok("KNOWS")), Dict.empty({}), edges)
    when r5.initial_events is
        [EdgeAdded(_)] -> Bool.true
        _ -> Bool.false

# Test 6: AnyPropertyChange gets all property events as initial
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    props =
        Dict.empty({})
        |> Dict.insert("x", PropertyValue.from_value(Integer(1)))
        |> Dict.insert("y", PropertyValue.from_value(Integer(2)))
    r6 = register_standing_query(idx, sub_a, AnyPropertyChange, props, Dict.empty({}))
    List.len(r6.initial_events) == 2

# Test 7: Unregister removes subscriber
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    r7 = register_standing_query(idx, sub_a, PropertyChange("name"), Dict.empty({}), Dict.empty({}))
    idx3 = unregister_standing_query(r7.index, sub_a, PropertyChange("name"))
    subs = subscribers_for_event(idx3, PropertySet({ key: "name", value: PropertyValue.from_value(Str("x")) }))
    List.is_empty(subs)

# Test 8: Subscriber for unrelated property gets nothing
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    r8 = register_standing_query(idx, sub_a, PropertyChange("name"), Dict.empty({}), Dict.empty({}))
    subs = subscribers_for_event(r8.index, PropertySet({ key: "age", value: PropertyValue.from_value(Integer(30)) }))
    List.is_empty(subs)

# Test 9: AnyPropertyChange subscriber gets notified on any property
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    r9 = register_standing_query(idx, sub_a, AnyPropertyChange, Dict.empty({}), Dict.empty({}))
    subs_name = subscribers_for_event(r9.index, PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) }))
    subs_age = subscribers_for_event(r9.index, PropertySet({ key: "age", value: PropertyValue.from_value(Integer(42)) }))
    List.contains(subs_name, sub_a) && List.contains(subs_age, sub_a)

# Test 10: EdgeChange(AnyLabel) subscriber gets notified on any edge
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    r10 = register_standing_query(idx, sub_a, EdgeChange(Err(AnyLabel)), Dict.empty({}), Dict.empty({}))
    he_knows : HalfEdge
    he_knows = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x01]) }
    he_follows : HalfEdge
    he_follows = { edge_type: "FOLLOWS", direction: Incoming, other: QuineId.from_bytes([0x02]) }
    subs_knows = subscribers_for_event(r10.index, EdgeAdded(he_knows))
    subs_follows = subscribers_for_event(r10.index, EdgeAdded(he_follows))
    List.contains(subs_knows, sub_a) && List.contains(subs_follows, sub_a)

# Test 11: Two subscribers on same property slot — both returned
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    sub_b : SqSubscriber
    sub_b = { global_id: 2u128, part_id: 20u64 }
    idx = empty
    r11a = register_standing_query(idx, sub_a, PropertyChange("key"), Dict.empty({}), Dict.empty({}))
    r11b = register_standing_query(r11a.index, sub_b, PropertyChange("key"), Dict.empty({}), Dict.empty({}))
    subs = subscribers_for_event(r11b.index, PropertySet({ key: "key", value: PropertyValue.from_value(Str("v")) }))
    List.len(subs) == 2

# Test 12: PropertyRemoved also notifies property subscribers
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    r12 = register_standing_query(idx, sub_a, PropertyChange("name"), Dict.empty({}), Dict.empty({}))
    subs = subscribers_for_event(r12.index, PropertyRemoved({ key: "name", previous_value: PropertyValue.from_value(Str("old")) }))
    List.contains(subs, sub_a)

# Test 13: EdgeRemoved also notifies edge subscribers
expect
    sub_a : SqSubscriber
    sub_a = { global_id: 1u128, part_id: 10u64 }
    idx = empty
    r13 = register_standing_query(idx, sub_a, EdgeChange(Ok("KNOWS")), Dict.empty({}), Dict.empty({}))
    he : HalfEdge
    he = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x01]) }
    subs = subscribers_for_event(r13.index, EdgeRemoved(he))
    List.contains(subs, sub_a)
