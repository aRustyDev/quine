app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br",
    id: "../packages/core/id/main.roc",
    model: "../packages/core/model/main.roc",
    persistor: "../packages/persistor/memory/main.roc",
}

import cli.Stdout
import cli.Arg exposing [Arg]
import id.QuineId
import id.EventTime
import model.PropertyValue
import model.NodeState
import persistor.Persistor

main! : List Arg => Result {} _
main! = |_args|
    # === Setup ===
    p0 = Persistor.new({})
    qid = QuineId.from_bytes([0x01, 0x02, 0x03])

    # === Phase 1: build up node state through events ===
    state0 = NodeState.empty
    e1 = PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })
    e2 = PropertySet({ key: "age", value: PropertyValue.from_value(Integer(30)) })
    state1 = NodeState.apply_event(state0, e1)
    state_pre_crash = NodeState.apply_event(state1, e2)

    # Persist events to the journal
    t1 = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    t2 = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 1 })
    timed_events = [
        { event: e1, at_time: t1 },
        { event: e2, at_time: t2 },
    ]
    p1 =
        when Persistor.append_events(p0, qid, timed_events) is
            Ok(p) -> p
            Err(_) -> crash "append_events failed"

    # Take a snapshot at time t2
    snap = NodeState.to_snapshot(state_pre_crash, t2)
    p2 =
        when Persistor.put_snapshot(p1, qid, snap) is
            Ok(p) -> p
            Err(_) -> crash "put_snapshot failed"

    # === Phase 2: simulate a crash — discard state, keep only the persistor ===
    # (In real usage, this is process restart + new NodeState from scratch)

    # === Phase 3: restore ===
    # Find the latest snapshot at or before a future time
    future_time = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    latest_snap =
        when Persistor.get_latest_snapshot(p2, qid, future_time) is
            Ok(s) -> s
            Err(_) -> crash "get_latest_snapshot failed"

    restored_state = NodeState.from_snapshot(latest_snap)

    # === Verify ===
    if restored_state == state_pre_crash then
        Stdout.line!("Phase 2 smoke test PASSED")
    else
        Err(SmokeTestFailed)
