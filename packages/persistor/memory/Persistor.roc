module [
    Persistor,
    Config,
    new,
    put_metadata,
    get_metadata,
    delete_metadata,
    get_all_metadata,
    append_events,
]

import id.QuineId exposing [QuineId]
import id.EventTime exposing [EventTime]
import model.PropertyValue
import model.HalfEdge
import model.NodeEvent exposing [TimestampedEvent]
import model.NodeSnapshot exposing [NodeSnapshot]

## Opaque in-memory persistor backend.
##
## Holds three independent stores: an append-only event journal, a
## replaceable-per-key snapshot store, and a flat metadata key-value store.
## All state is threaded through operations — callers receive a new
## `Persistor` from every mutating operation and pass it to subsequent calls.
##
## Roc's refcount-1 optimization means these operations mutate the underlying
## Dicts in place at runtime, so performance matches a mutable implementation
## despite the pure-functional API.
Persistor := {
    events : Dict QuineId (Dict EventTime (List TimestampedEvent)),
    snapshots : Dict QuineId (Dict EventTime NodeSnapshot),
    metadata : Dict Str (List U8),
}

## Configuration options for the in-memory persistor.
##
## Empty for Phase 2 — exists as a placeholder for future backends that will
## need backend-specific options (RocksDB path, Cassandra contact points, etc.)
## This keeps the constructor signature consistent across backends.
Config : {}

## Create a new, empty in-memory persistor.
new : Config -> Persistor
new = |_config|
    @Persistor({
        events: Dict.empty({}),
        snapshots: Dict.empty({}),
        metadata: Dict.empty({}),
    })

## Store an opaque byte value under a metadata key.
##
## Overwrites any existing value at the key (last-write-wins semantics).
put_metadata :
    Persistor,
    Str,
    List U8
    -> Result Persistor [Unavailable, Timeout]
put_metadata = |@Persistor(state), key, value|
    new_metadata = Dict.insert(state.metadata, key, value)
    Ok(@Persistor({ state & metadata: new_metadata }))

## Retrieve an opaque byte value for a metadata key.
##
## Returns `Err NotFound` if no value is stored at the key.
get_metadata :
    Persistor,
    Str
    -> Result (List U8) [NotFound, Unavailable, Timeout]
get_metadata = |@Persistor(state), key|
    when Dict.get(state.metadata, key) is
        Ok(value) -> Ok(value)
        Err(_) -> Err(NotFound)

## Remove a metadata key. No-op if the key does not exist.
delete_metadata :
    Persistor,
    Str
    -> Result Persistor [Unavailable, Timeout]
delete_metadata = |@Persistor(state), key|
    new_metadata = Dict.remove(state.metadata, key)
    Ok(@Persistor({ state & metadata: new_metadata }))

## Retrieve all metadata as a Dict. Returns an empty Dict if no metadata
## has been stored.
get_all_metadata :
    Persistor
    -> Result (Dict Str (List U8)) [Unavailable, Timeout]
get_all_metadata = |@Persistor(state)|
    Ok(state.metadata)

## Append a batch of events to a node's journal.
##
## Rejects with `DuplicateEventTime` if any event has an `EventTime` that
## already exists for the same node. This structurally enforces event
## immutability (see ADR-012).
append_events :
    Persistor,
    QuineId,
    List TimestampedEvent
    -> Result Persistor [DuplicateEventTime EventTime, Unavailable, Timeout]
append_events = |@Persistor(state), qid, events|
    node_events = Dict.get(state.events, qid) |> Result.with_default(Dict.empty({}))

    # Check for duplicates before applying any
    dup_check = List.walk_until(
        events,
        Ok(node_events),
        |acc_result, timed|
            when acc_result is
                Err(_) -> Break(acc_result)
                Ok(acc) ->
                    when Dict.get(acc, timed.at_time) is
                        Ok(_) -> Break(Err(DuplicateEventTime(timed.at_time)))
                        Err(_) ->
                            existing = Dict.get(acc, timed.at_time) |> Result.with_default([])
                            Continue(Ok(Dict.insert(acc, timed.at_time, List.append(existing, timed)))),
    )

    when dup_check is
        Err(e) -> Err(e)
        Ok(new_node_events) ->
            new_events = Dict.insert(state.events, qid, new_node_events)
            Ok(@Persistor({ state & events: new_events }))

# ===== Tests =====

expect
    # new produces an opaque Persistor
    p = new({})
    when p is
        @Persistor(_) -> Bool.true

expect
    # put_metadata stores a value at a key
    p = new({})
    when put_metadata(p, "version", [0x01, 0x02]) is
        Ok(@Persistor(state)) ->
            Dict.get(state.metadata, "version") == Ok([0x01, 0x02])
        Err(_) -> Bool.false

expect
    # get_metadata returns Ok for a stored key
    p = new({})
    when put_metadata(p, "k", [0xAA]) is
        Ok(p2) ->
            when get_metadata(p2, "k") is
                Ok([0xAA]) -> Bool.true
                _ -> Bool.false
        Err(_) -> Bool.false

expect
    # get_metadata returns Err NotFound for a missing key
    p = new({})
    when get_metadata(p, "missing") is
        Err(NotFound) -> Bool.true
        _ -> Bool.false

expect
    # delete_metadata removes a stored key
    p = new({})
    when put_metadata(p, "k", [0xFF]) is
        Ok(p2) ->
            when delete_metadata(p2, "k") is
                Ok(p3) ->
                    when get_metadata(p3, "k") is
                        Err(NotFound) -> Bool.true
                        _ -> Bool.false
                Err(_) -> Bool.false
        Err(_) -> Bool.false

expect
    # delete_metadata on missing key is a no-op (returns Ok)
    p = new({})
    when delete_metadata(p, "never-existed") is
        Ok(_) -> Bool.true
        _ -> Bool.false

expect
    # get_all_metadata returns empty Dict on fresh persistor
    p = new({})
    when get_all_metadata(p) is
        Ok(m) -> Dict.is_empty(m)
        Err(_) -> Bool.false

expect
    # get_all_metadata returns all stored keys
    p = new({})
    when put_metadata(p, "a", [0x01]) is
        Ok(p1) ->
            when put_metadata(p1, "b", [0x02]) is
                Ok(p2) ->
                    when get_all_metadata(p2) is
                        Ok(m) -> Dict.len(m) == 2
                        Err(_) -> Bool.false
                Err(_) -> Bool.false
        Err(_) -> Bool.false

expect
    # append_events adds a single event
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    event = PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })
    timed = { event, at_time: t }
    when append_events(p, qid, [timed]) is
        Ok(@Persistor(state)) ->
            Dict.len(state.events) == 1
        Err(_) -> Bool.false

expect
    # append_events rejects duplicate EventTime
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    e1 = { event: PropertySet({ key: "a", value: PropertyValue.from_value(Integer(1)) }), at_time: t }
    e2 = { event: PropertySet({ key: "b", value: PropertyValue.from_value(Integer(2)) }), at_time: t }
    when append_events(p, qid, [e1]) is
        Ok(p1) ->
            when append_events(p1, qid, [e2]) is
                Err(DuplicateEventTime(_)) -> Bool.true
                _ -> Bool.false
        Err(_) -> Bool.false

expect
    # append_events with multiple events at distinct times succeeds
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t1 = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    t2 = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 1 })
    e1 = { event: PropertySet({ key: "a", value: PropertyValue.from_value(Integer(1)) }), at_time: t1 }
    e2 = { event: PropertySet({ key: "b", value: PropertyValue.from_value(Integer(2)) }), at_time: t2 }
    when append_events(p, qid, [e1, e2]) is
        Ok(_) -> Bool.true
        _ -> Bool.false
