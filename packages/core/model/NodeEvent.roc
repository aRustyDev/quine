module [
    NodeChangeEvent,
    TimestampedEvent,
]

import id.EventTime exposing [EventTime]
import id.QuineId
import PropertyValue exposing [PropertyValue]
import HalfEdge exposing [HalfEdge]

## A change to a node's data state.
##
## NodeChangeEvent is the granular unit of mutation in the event-sourced model.
## Every property update or edge change is represented as one of these events,
## stored in the node's journal, and replayed on wake-up.
##
## DomainIndexEvent (standing query subscription bookkeeping) is a separate
## concern deferred to Phase 4 (see ADR-005).
NodeChangeEvent : [
    PropertySet { key : Str, value : PropertyValue },
    PropertyRemoved { key : Str, previous_value : PropertyValue },
    EdgeAdded HalfEdge,
    EdgeRemoved HalfEdge,
]

## A NodeChangeEvent paired with the timestamp at which it occurred.
##
## TimestampedEvents are what get journaled to persistence. The bare
## NodeChangeEvent is used in-flight before a timestamp is assigned.
TimestampedEvent : {
    event : NodeChangeEvent,
    at_time : EventTime,
}

# ===== Tests =====

expect
    e1 = PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })
    when e1 is
        PropertySet(_) -> Bool.true
        _ -> Bool.false

expect
    e2 = PropertyRemoved({ key: "x", previous_value: PropertyValue.from_value(Integer(1)) })
    when e2 is
        PropertyRemoved(_) -> Bool.true
        _ -> Bool.false

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    e3 = EdgeAdded(edge)
    when e3 is
        EdgeAdded(_) -> Bool.true
        _ -> Bool.false

expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    e4 = EdgeRemoved(edge)
    when e4 is
        EdgeRemoved(_) -> Bool.true
        _ -> Bool.false

expect
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    e = PropertySet({ key: "k", value: PropertyValue.from_value(Integer(42)) })
    timed = { event: e, at_time: t }
    timed.at_time == t
