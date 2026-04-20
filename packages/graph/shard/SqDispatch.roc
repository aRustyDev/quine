module [
    derive_events,
]

import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import types.Messages exposing [LiteralCommand]

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

# ===== Tests =====

import id.QuineId

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
