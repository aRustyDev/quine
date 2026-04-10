app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br",
    id: "../packages/core/id/main.roc",
    model: "../packages/core/model/main.roc",
}

import cli.Stdout
import cli.Arg exposing [Arg]
import id.QuineId
import id.EventTime
import model.PropertyValue
import model.NodeState

main! : List Arg => Result {} _
main! = |_args|
    # Create an empty node state
    initial = NodeState.empty

    # Apply some events
    e1 = PropertySet({
        key: "name",
        value: PropertyValue.from_value(Str("Alice")),
    })
    e2 = PropertySet({
        key: "age",
        value: PropertyValue.from_value(Integer(30)),
    })
    e3 = EdgeAdded({
        edge_type: "KNOWS",
        direction: Outgoing,
        other: QuineId.from_bytes([0xBB]),
    })

    final =
        initial
        |> NodeState.apply_event(e1)
        |> NodeState.apply_event(e2)
        |> NodeState.apply_event(e3)

    # Snapshot and restore
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    snap = NodeState.to_snapshot(final, t)
    restored = NodeState.from_snapshot(snap)

    if restored == final then
        Stdout.line!("Phase 1 smoke test PASSED")
    else
        Stdout.line!("Phase 1 smoke test FAILED")
