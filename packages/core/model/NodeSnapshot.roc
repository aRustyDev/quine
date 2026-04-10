module [
    NodeSnapshot,
]

import id.EventTime exposing [EventTime]
import PropertyValue exposing [PropertyValue]
import HalfEdge exposing [HalfEdge]

## A serializable snapshot of a node's state at a given time.
##
## Snapshots are periodically persisted to avoid replaying the full event journal
## on wake-up. Standing query subscription state fields are deferred to Phase 4
## (see ADR-005).
##
## Note: HalfEdge cannot be stored in a Set in Roc without an explicit Hash
## implementation. Phase 1 uses a List; Phase 2 will revisit if uniqueness
## enforcement becomes a hot path.
NodeSnapshot : {
    properties : Dict Str PropertyValue,
    edges : List HalfEdge,
    time : EventTime,
}

# ===== Tests =====

expect
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    snap : NodeSnapshot
    snap = { properties: Dict.empty({}), edges: [], time: t }
    Dict.is_empty(snap.properties) and List.is_empty(snap.edges) and snap.time == t

expect
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    props = Dict.empty({}) |> Dict.insert("name", PropertyValue.from_value(Str("Alice")))
    snap : NodeSnapshot
    snap = { properties: props, edges: [], time: t }
    Dict.len(snap.properties) == 1
