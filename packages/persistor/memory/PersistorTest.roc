module []

import id.QuineId
import id.EventTime
import model.PropertyValue
import model.NodeSnapshot exposing [NodeSnapshot]
import Persistor

# ===== Component Tests =====

# Scenario 1: Insert many events, retrieve by range
expect
    p = Persistor.new({})
    qid = QuineId.from_bytes([0x42])

    # Build 10 events at times 100, 200, ..., 1000
    events = List.range({ start: At(1), end: At(10) })
        |> List.map(
            |i|
                t = EventTime.from_parts({ millis: Num.to_u64(i) * 100, message_seq: 0, event_seq: 0 })
                {
                    event: PropertySet({
                        key: "counter",
                        value: PropertyValue.from_value(Integer(i)),
                    }),
                    at_time: t,
                },
        )

    # Append all events
    when Persistor.append_events(p, qid, events) is
        Err(_) -> Bool.false
        Ok(p1) ->
            # Retrieve events in range [300, 700] — should get 5 events (at 300, 400, 500, 600, 700)
            t_start = EventTime.from_parts({ millis: 300, message_seq: 0, event_seq: 0 })
            t_end = EventTime.from_parts({ millis: 700, message_seq: 0, event_seq: 0 })
            when Persistor.get_events(p1, qid, { start: t_start, end: t_end }) is
                Ok(result) -> List.len(result) == 5
                _ -> Bool.false

# Scenario 2: Snapshot + journal replay simulation
expect
    p = Persistor.new({})
    qid = QuineId.from_bytes([0x01])

    # Create a snapshot at time T1
    t1 = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    props_at_t1 = Dict.empty({}) |> Dict.insert("name", PropertyValue.from_value(Str("Alice")))
    snap : NodeSnapshot
    snap = { properties: props_at_t1, edges: [], time: t1, sq_snapshot: [] }

    when Persistor.put_snapshot(p, qid, snap) is
        Err(_) -> Bool.false
        Ok(p1) ->
            # Append an event at time T2 > T1
            t2 = EventTime.from_parts({ millis: 2000, message_seq: 0, event_seq: 0 })
            e = {
                event: PropertySet({
                    key: "age",
                    value: PropertyValue.from_value(Integer(30)),
                }),
                at_time: t2,
            }
            when Persistor.append_events(p1, qid, [e]) is
                Err(_) -> Bool.false
                Ok(p2) ->
                    # Query for latest snapshot at T3 > T2 — should return snap
                    t3 = EventTime.from_parts({ millis: 3000, message_seq: 0, event_seq: 0 })
                    when Persistor.get_latest_snapshot(p2, qid, t3) is
                        Err(_) -> Bool.false
                        Ok(found) ->
                            # Find events between snapshot's time and query time
                            when Persistor.get_events(p2, qid, { start: found.time, end: t3 }) is
                                Ok(events) ->
                                    # We should have 1 event (the one at T2)
                                    List.len(events) == 1 and found.time == t1
                                _ -> Bool.false

# Scenario 3: Delete node's events but keep snapshots
expect
    p = Persistor.new({})
    qid = QuineId.from_bytes([0x77])

    # Add a snapshot and an event
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    snap : NodeSnapshot
    snap = { properties: Dict.empty({}), edges: [], time: t, sq_snapshot: [] }
    e = { event: PropertySet({ key: "k", value: PropertyValue.from_value(Integer(1)) }), at_time: t }

    when Persistor.put_snapshot(p, qid, snap) is
        Err(_) -> Bool.false
        Ok(p1) ->
            when Persistor.append_events(p1, qid, [e]) is
                Err(_) -> Bool.false
                Ok(p2) ->
                    when Persistor.delete_events_for_node(p2, qid) is
                        Err(_) -> Bool.false
                        Ok(p3) ->
                            # Events gone
                            when Persistor.get_events(p3, qid, { start: t, end: t }) is
                                Ok([]) ->
                                    # Snapshot still there
                                    when Persistor.get_latest_snapshot(p3, qid, t) is
                                        Ok(_) -> Bool.true
                                        _ -> Bool.false
                                _ -> Bool.false

# Scenario 4: empty_of_quine_data lifecycle
expect
    p = Persistor.new({})

    # Fresh: empty
    init_empty =
        when Persistor.empty_of_quine_data(p) is
            Ok(val) -> val == Bool.true
            _ -> Bool.false

    # After an event: not empty
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    e = { event: PropertySet({ key: "k", value: PropertyValue.from_value(Integer(1)) }), at_time: t }

    after_append =
        when Persistor.append_events(p, qid, [e]) is
            Ok(p1) ->
                when Persistor.empty_of_quine_data(p1) is
                    Ok(val) -> val == Bool.false
                    _ -> Bool.false
            _ -> Bool.false

    # After delete: empty again
    full_cycle =
        when Persistor.append_events(p, qid, [e]) is
            Ok(p1) ->
                when Persistor.delete_events_for_node(p1, qid) is
                    Ok(p2) ->
                        when Persistor.empty_of_quine_data(p2) is
                            Ok(val) -> val == Bool.true
                            _ -> Bool.false
                    _ -> Bool.false
            _ -> Bool.false

    init_empty and after_append and full_cycle
