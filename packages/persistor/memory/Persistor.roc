module [
    Persistor,
    Config,
    new,
    put_metadata,
    get_metadata,
    delete_metadata,
    get_all_metadata,
    append_events,
    get_events,
    delete_events_for_node,
    put_snapshot,
    get_latest_snapshot,
    delete_snapshots_for_node,
    empty_of_quine_data,
    shutdown,
]

import id.QuineId exposing [QuineId]
import id.EventTime exposing [EventTime]
import model.PropertyValue
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
                            Continue(Ok(Dict.insert(acc, timed.at_time, [timed]))),
    )

    when dup_check is
        Err(e) -> Err(e)
        Ok(new_node_events) ->
            new_events = Dict.insert(state.events, qid, new_node_events)
            Ok(@Persistor({ state & events: new_events }))

## Retrieve events for a node within an inclusive time range.
##
## Returns events where `start <= at_time <= end`, ordered by time ascending.
## Returns an empty list if no events exist in the range (not an error).
get_events :
    Persistor,
    QuineId,
    { start : EventTime, end : EventTime }
    -> Result (List TimestampedEvent) [Unavailable, Timeout]
get_events = |@Persistor(state), qid, { start, end }|
    when Dict.get(state.events, qid) is
        Err(_) -> Ok([])
        Ok(node_events) ->
            # Iterate the node's event dict, filter by range, flatten lists
            all_in_range = Dict.walk(
                node_events,
                [],
                |acc, t, events_list|
                    if is_in_range(t, start, end) then
                        List.concat(acc, events_list)
                    else
                        acc,
            )
            # Sort by at_time ascending
            sorted = List.sort_with(
                all_in_range,
                |a, b| Num.compare(event_time_to_u64(a.at_time), event_time_to_u64(b.at_time)),
            )
            Ok(sorted)

is_in_range : EventTime, EventTime, EventTime -> Bool
is_in_range = |t, start, end|
    t_val = event_time_to_u64(t)
    start_val = event_time_to_u64(start)
    end_val = event_time_to_u64(end)
    t_val >= start_val and t_val <= end_val

# Helper: Extract the underlying U64 from an EventTime by reconstructing it from parts.
# This is needed because EventTime is opaque and doesn't expose its inner value directly.
# The bit-packed format means we can't easily compare without decomposing.
event_time_to_u64 : EventTime -> U64
event_time_to_u64 = |t|
    m = EventTime.millis(t)
    msg = Num.to_u64(EventTime.message_seq(t))
    ev = Num.to_u64(EventTime.event_seq(t))
    Num.shift_left_by(m, 22)
    |> Num.bitwise_or(Num.shift_left_by(msg, 8))
    |> Num.bitwise_or(ev)

## Delete all journal events for a node. No-op if the node has no events.
delete_events_for_node :
    Persistor,
    QuineId
    -> Result Persistor [Unavailable, Timeout]
delete_events_for_node = |@Persistor(state), qid|
    new_events = Dict.remove(state.events, qid)
    Ok(@Persistor({ state & events: new_events }))

## Store a snapshot for a node at the snapshot's embedded timestamp.
##
## Overwrites any existing snapshot at the same `(QuineId, EventTime)` —
## snapshots use last-write-wins semantics (unlike journal events).
put_snapshot :
    Persistor,
    QuineId,
    NodeSnapshot
    -> Result Persistor [Unavailable, Timeout]
put_snapshot = |@Persistor(state), qid, snap|
    node_snapshots = Dict.get(state.snapshots, qid) |> Result.with_default(Dict.empty({}))
    new_node_snapshots = Dict.insert(node_snapshots, snap.time, snap)
    new_snapshots = Dict.insert(state.snapshots, qid, new_node_snapshots)
    Ok(@Persistor({ state & snapshots: new_snapshots }))

## Retrieve the most recent snapshot for a node at or before the given time.
##
## Returns `Err NotFound` if no snapshot exists for the node at or before the
## time. Used on node wake-up to restore state: take the latest snapshot,
## then replay journal events after the snapshot's time.
get_latest_snapshot :
    Persistor,
    QuineId,
    EventTime
    -> Result NodeSnapshot [NotFound, Unavailable, Timeout]
get_latest_snapshot = |@Persistor(state), qid, up_to_time|
    when Dict.get(state.snapshots, qid) is
        Err(_) -> Err(NotFound)
        Ok(node_snapshots) ->
            up_to_u64 = event_time_to_u64(up_to_time)
            # Find the snapshot with the largest time <= up_to_u64
            result = Dict.walk(
                node_snapshots,
                Err(NotFound),
                |acc, t, snap|
                    t_u64 = event_time_to_u64(t)
                    if t_u64 <= up_to_u64 then
                        when acc is
                            Err(_) -> Ok(snap)
                            Ok(existing) ->
                                if t_u64 > event_time_to_u64(existing.time) then
                                    Ok(snap)
                                else
                                    acc
                    else
                        acc,
            )
            result

## Delete all snapshots for a node. No-op if the node has no snapshots.
delete_snapshots_for_node :
    Persistor,
    QuineId
    -> Result Persistor [Unavailable, Timeout]
delete_snapshots_for_node = |@Persistor(state), qid|
    new_snapshots = Dict.remove(state.snapshots, qid)
    Ok(@Persistor({ state & snapshots: new_snapshots }))

## Returns true if the persistor holds no node data (events or snapshots).
##
## Metadata is not considered "quine data" — a persistor with only metadata
## entries is still considered empty for node purposes.
empty_of_quine_data :
    Persistor
    -> Result Bool [Unavailable, Timeout]
empty_of_quine_data = |@Persistor(state)|
    Ok(Dict.is_empty(state.events) and Dict.is_empty(state.snapshots))

## Cleanly shut down the persistor.
##
## For the in-memory backend, this is a no-op — there's nothing to flush,
## close, or release. Future backends will use this to close file handles,
## flush write buffers, disconnect from remote storage, etc.
##
## This operation consumes the Persistor — callers should not use the
## handle after calling shutdown. The Roc type system doesn't enforce this,
## so callers must discipline themselves.
shutdown :
    Persistor
    -> Result {} [Unavailable, Timeout]
shutdown = |_| Ok({})

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

expect
    # get_events on a node with no events returns empty
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t1 = EventTime.from_parts({ millis: 0, message_seq: 0, event_seq: 0 })
    t2 = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    when get_events(p, qid, { start: t1, end: t2 }) is
        Ok([]) -> Bool.true
        _ -> Bool.false

expect
    # get_events returns events within the range
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t1 = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    t2 = EventTime.from_parts({ millis: 200, message_seq: 0, event_seq: 0 })
    t3 = EventTime.from_parts({ millis: 300, message_seq: 0, event_seq: 0 })
    e1 = { event: PropertySet({ key: "a", value: PropertyValue.from_value(Integer(1)) }), at_time: t1 }
    e2 = { event: PropertySet({ key: "b", value: PropertyValue.from_value(Integer(2)) }), at_time: t2 }
    e3 = { event: PropertySet({ key: "c", value: PropertyValue.from_value(Integer(3)) }), at_time: t3 }
    when append_events(p, qid, [e1, e2, e3]) is
        Ok(p1) ->
            when get_events(p1, qid, { start: t1, end: t2 }) is
                Ok(events) -> List.len(events) == 2
                _ -> Bool.false
        _ -> Bool.false

expect
    # delete_events_for_node removes all events for a node
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    e = { event: PropertySet({ key: "a", value: PropertyValue.from_value(Integer(1)) }), at_time: t }
    when append_events(p, qid, [e]) is
        Ok(p1) ->
            when delete_events_for_node(p1, qid) is
                Ok(p2) ->
                    when get_events(p2, qid, { start: t, end: t }) is
                        Ok([]) -> Bool.true
                        _ -> Bool.false
                Err(_) -> Bool.false
        Err(_) -> Bool.false

expect
    # delete_events_for_node on a missing node is a no-op
    p = new({})
    qid = QuineId.from_bytes([0x01])
    when delete_events_for_node(p, qid) is
        Ok(_) -> Bool.true
        _ -> Bool.false

expect
    # put_snapshot stores a snapshot
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    snap : NodeSnapshot
    snap = { properties: Dict.empty({}), edges: [], time: t, sq_snapshot: [] }
    when put_snapshot(p, qid, snap) is
        Ok(@Persistor(state)) ->
            when Dict.get(state.snapshots, qid) is
                Ok(_) -> Bool.true
                _ -> Bool.false
        Err(_) -> Bool.false

expect
    # put_snapshot overwrites at same time (last-write-wins)
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    snap1 : NodeSnapshot
    snap1 = { properties: Dict.empty({}), edges: [], time: t, sq_snapshot: [] }
    props = Dict.empty({}) |> Dict.insert("k", PropertyValue.from_value(Integer(1)))
    snap2 : NodeSnapshot
    snap2 = { properties: props, edges: [], time: t, sq_snapshot: [] }
    when put_snapshot(p, qid, snap1) is
        Ok(p1) ->
            when put_snapshot(p1, qid, snap2) is
                Ok(@Persistor(state)) ->
                    when Dict.get(state.snapshots, qid) is
                        Ok(node_snaps) ->
                            when Dict.get(node_snaps, t) is
                                Ok(s) -> Dict.len(s.properties) == 1
                                _ -> Bool.false
                        _ -> Bool.false
                Err(_) -> Bool.false
        Err(_) -> Bool.false

expect
    # get_latest_snapshot returns NotFound for a node with no snapshots
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    when get_latest_snapshot(p, qid, t) is
        Err(NotFound) -> Bool.true
        _ -> Bool.false

expect
    # get_latest_snapshot returns the most recent snapshot at or before time
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t1 = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    t2 = EventTime.from_parts({ millis: 200, message_seq: 0, event_seq: 0 })
    t3 = EventTime.from_parts({ millis: 300, message_seq: 0, event_seq: 0 })
    snap1 : NodeSnapshot
    snap1 = { properties: Dict.empty({}), edges: [], time: t1, sq_snapshot: [] }
    snap2 : NodeSnapshot
    snap2 = { properties: Dict.empty({}), edges: [], time: t2, sq_snapshot: [] }
    snap3 : NodeSnapshot
    snap3 = { properties: Dict.empty({}), edges: [], time: t3, sq_snapshot: [] }
    when put_snapshot(p, qid, snap1) is
        Ok(p1) ->
            when put_snapshot(p1, qid, snap2) is
                Ok(p2) ->
                    when put_snapshot(p2, qid, snap3) is
                        Ok(p3) ->
                            # Query at t2.5 should return snap2
                            t_query = EventTime.from_parts({ millis: 250, message_seq: 0, event_seq: 0 })
                            when get_latest_snapshot(p3, qid, t_query) is
                                Ok(found) -> found.time == t2
                                Err(_) -> Bool.false
                        Err(_) -> Bool.false
                Err(_) -> Bool.false
        Err(_) -> Bool.false

expect
    # delete_snapshots_for_node removes all snapshots for a node
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    snap : NodeSnapshot
    snap = { properties: Dict.empty({}), edges: [], time: t, sq_snapshot: [] }
    when put_snapshot(p, qid, snap) is
        Ok(p1) ->
            when delete_snapshots_for_node(p1, qid) is
                Ok(p2) ->
                    when get_latest_snapshot(p2, qid, t) is
                        Err(NotFound) -> Bool.true
                        _ -> Bool.false
                Err(_) -> Bool.false
        Err(_) -> Bool.false

expect
    # delete_snapshots_for_node on a missing node is a no-op
    p = new({})
    qid = QuineId.from_bytes([0x01])
    when delete_snapshots_for_node(p, qid) is
        Ok(_) -> Bool.true
        _ -> Bool.false

expect
    # empty_of_quine_data returns true on a fresh persistor
    p = new({})
    when empty_of_quine_data(p) is
        Ok(val) -> val == Bool.true
        _ -> Bool.false

expect
    # empty_of_quine_data returns false after appending an event
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    e = { event: PropertySet({ key: "a", value: PropertyValue.from_value(Integer(1)) }), at_time: t }
    when append_events(p, qid, [e]) is
        Ok(p1) ->
            when empty_of_quine_data(p1) is
                Ok(val) -> val == Bool.false
                _ -> Bool.false
        _ -> Bool.false

expect
    # empty_of_quine_data returns true after deleting all events
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    e = { event: PropertySet({ key: "a", value: PropertyValue.from_value(Integer(1)) }), at_time: t }
    when append_events(p, qid, [e]) is
        Ok(p1) ->
            when delete_events_for_node(p1, qid) is
                Ok(p2) ->
                    when empty_of_quine_data(p2) is
                        Ok(val) -> val == Bool.true
                        _ -> Bool.false
                _ -> Bool.false
        _ -> Bool.false

expect
    # empty_of_quine_data ignores metadata — metadata-only persistor is empty
    p = new({})
    when put_metadata(p, "version", [0x01]) is
        Ok(p1) ->
            when empty_of_quine_data(p1) is
                Ok(val) -> val == Bool.true
                _ -> Bool.false
        _ -> Bool.false

expect
    # shutdown returns Ok on a fresh persistor
    p = new({})
    when shutdown(p) is
        Ok({}) -> Bool.true
        _ -> Bool.false

expect
    # shutdown returns Ok on a persistor with data
    p = new({})
    when put_metadata(p, "k", [0x01]) is
        Ok(p1) ->
            when shutdown(p1) is
                Ok({}) -> Bool.true
                _ -> Bool.false
        _ -> Bool.false
