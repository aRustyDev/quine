# core/model

Data and event types for the Quine graph node model.

## Modules

- `QuineValue` — Runtime value tagged union (10 variants)
- `PropertyValue` — Lazy property value wrapper
- `EdgeDirection` — Outgoing/Incoming/Undirected
- `HalfEdge` — One side of an edge (label + direction + remote node)
- `NodeEvent` — `NodeChangeEvent` and `TimestampedEvent`
- `NodeSnapshot` — Serializable full node state
- `NodeState` — In-memory node state with `apply_event`

## Dependencies

- [`core/id`](../id/README.md) — for `QuineId`

## Scala Counterpart

- `quine-core/src/main/scala/com/thatdot/quine/model/QuineValue.scala`
- `quine-core/src/main/scala/com/thatdot/quine/model/PropertyValue.scala`
- `quine-core/src/main/scala/com/thatdot/quine/model/HalfEdge.scala`
- `quine-core/src/main/scala/com/thatdot/quine/model/EdgeDirection.scala`
- `quine-core/src/main/scala/com/thatdot/quine/graph/NodeEvent.scala`
- `quine-core/src/main/scala/com/thatdot/quine/graph/NodeSnapshot.scala`

## Analysis

See [`docs/src/core/graph/node/README.md`](../../../.claude/plans/quine-roc-port/docs/src/core/graph/node/README.md).
