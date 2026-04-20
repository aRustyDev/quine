module [
    NodeState,
    empty,
    apply_event,
    from_snapshot,
    to_snapshot,
]

import id.EventTime exposing [EventTime]
import id.QuineId
import PropertyValue exposing [PropertyValue]
import HalfEdge exposing [HalfEdge]
import NodeEvent exposing [NodeChangeEvent]
import NodeSnapshot exposing [NodeSnapshot]

## A node's in-memory state: properties and edges.
##
## This is the live, mutable-by-replacement state held by an active node. It is
## NOT durably persisted directly — see NodeSnapshot for that. NodeState is the
## working representation that apply_event mutates.
NodeState : {
    properties : Dict Str PropertyValue,
    edges : List HalfEdge,
}

## An empty NodeState with no properties and no edges.
empty : NodeState
empty = { properties: Dict.empty({}), edges: [] }

## Apply a NodeChangeEvent to a NodeState, returning the updated state.
##
## This is the core pure function of the node model. Every state mutation
## flows through here. Operations are idempotent where they should be:
## - Setting a property to a value, then setting it again to the same value, is a no-op
## - Removing a non-existent property is a no-op
## - Adding an edge that already exists is a no-op
## - Removing a non-existent edge is a no-op
apply_event : NodeState, NodeChangeEvent -> NodeState
apply_event = |state, event|
    when event is
        PropertySet({ key, value }) ->
            { state & properties: Dict.insert(state.properties, key, value) }

        PropertyRemoved({ key }) ->
            { state & properties: Dict.remove(state.properties, key) }

        EdgeAdded(edge) ->
            if List.contains(state.edges, edge) then
                state
            else
                { state & edges: List.append(state.edges, edge) }

        EdgeRemoved(edge) ->
            { state & edges: List.drop_if(state.edges, |e| e == edge) }

## Restore a NodeState from a NodeSnapshot.
##
## The snapshot's time field is discarded — NodeState has no timestamp of its own.
## Callers needing the time should track it separately.
from_snapshot : NodeSnapshot -> NodeState
from_snapshot = |snap|
    { properties: snap.properties, edges: snap.edges }

## Capture a NodeState as a NodeSnapshot at the given time.
to_snapshot : NodeState, EventTime -> NodeSnapshot
to_snapshot = |state, time|
    { properties: state.properties, edges: state.edges, time: time, sq_snapshot: [] }

# ===== Tests =====

expect
    state = empty
    event = PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })
    new_state = apply_event(state, event)
    Dict.len(new_state.properties) == 1

expect
    initial = apply_event(empty, PropertySet({ key: "x", value: PropertyValue.from_value(Integer(1)) }))
    after_remove = apply_event(initial, PropertyRemoved({ key: "x", previous_value: PropertyValue.from_value(Integer(1)) }))
    Dict.is_empty(after_remove.properties)

expect
    state = apply_event(empty, PropertyRemoved({ key: "missing", previous_value: PropertyValue.from_value(Null) }))
    Dict.is_empty(state.properties)

expect
    s1 = apply_event(empty, PropertySet({ key: "k", value: PropertyValue.from_value(Integer(1)) }))
    s2 = apply_event(s1, PropertySet({ key: "k", value: PropertyValue.from_value(Integer(2)) }))
    Dict.len(s2.properties) == 1

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    state = apply_event(empty, EdgeAdded(edge))
    List.len(state.edges) == 1

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    s1 = apply_event(empty, EdgeAdded(edge))
    s2 = apply_event(s1, EdgeAdded(edge))
    List.len(s2.edges) == 1

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    s1 = apply_event(empty, EdgeAdded(edge))
    s2 = apply_event(s1, EdgeRemoved(edge))
    List.is_empty(s2.edges)

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    state = apply_event(empty, EdgeRemoved(edge))
    List.is_empty(state.edges)

expect
    e1 = PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })
    e2 = EdgeAdded({ edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) })
    final = empty |> apply_event(e1) |> apply_event(e2)
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    snap = to_snapshot(final, t)
    restored = from_snapshot(snap)
    restored == final
