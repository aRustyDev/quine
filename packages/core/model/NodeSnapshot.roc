module [
    NodeSnapshot,
    SqStateSnapshot,
]

import id.EventTime exposing [EventTime]
import PropertyValue exposing [PropertyValue]
import HalfEdge exposing [HalfEdge]

## A serializable snapshot of a node's state at a given time.
##
## Snapshots are periodically persisted to avoid replaying the full event journal
## on wake-up. Standing query subscription state fields are included as serialized
## bytes (full encoding deferred to Phase 4d, see ADR-005).
##
## Note: HalfEdge cannot be stored in a Set in Roc without an explicit Hash
## implementation. Phase 1 uses a List; Phase 2 will revisit if uniqueness
## enforcement becomes a hot path.
NodeSnapshot : {
    properties : Dict Str PropertyValue,
    edges : List HalfEdge,
    time : EventTime,
    sq_snapshot : List SqStateSnapshot,
}

## Snapshot of standing query state for a single SQ part on this node.
##
## Note: Uses raw types (U128, U64) to avoid creating a dependency from
## core/model on the standing query package. Matches StandingQueryId (U128)
## and StandingQueryPartId (U64).
SqStateSnapshot : {
    global_id : U128,
    part_id : U64,
    state_bytes : List U8,
}

# ===== Tests =====

expect
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    snap : NodeSnapshot
    snap = { properties: Dict.empty({}), edges: [], time: t, sq_snapshot: [] }
    Dict.is_empty(snap.properties) and List.is_empty(snap.edges) and snap.time == t

expect
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    props = Dict.empty({}) |> Dict.insert("name", PropertyValue.from_value(Str("Alice")))
    snap : NodeSnapshot
    snap = { properties: props, edges: [], time: t, sq_snapshot: [] }
    Dict.len(snap.properties) == 1
