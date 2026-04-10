# core/id

Identity types for the Quine graph node model.

## Modules

- `QuineId` — Opaque byte-array node identifier
- `EventTime` — Bit-packed 64-bit timestamp (millis + message seq + event seq)
- `QuineIdProvider` — Record-of-functions abstraction over ID schemes

## Dependencies

None.

## Scala Counterpart

- `com.thatdot.common.quineid.QuineId` (external library, inlined here)
- `quine-core/src/main/scala/com/thatdot/quine/graph/EventTime.scala`
- `quine-core/src/main/scala/com/thatdot/quine/model/QuineIdProvider.scala`

## Analysis

See [`docs/src/core/graph/node/README.md`](../../../.claude/plans/quine-roc-port/docs/src/core/graph/node/README.md) for the full design analysis.
