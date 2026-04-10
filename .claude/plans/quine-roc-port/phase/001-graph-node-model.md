# Phase 1: Graph Node Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundational graph node model types in Roc — the atom of the entire Quine-to-Roc port — with inline tests and a working integration smoke test.

**Architecture:** Two independent Roc packages: `packages/core/id` (identity types) and `packages/core/model` (data and event types, depending on `id`). All types are tagged unions or records. One pure behavioral function (`apply_event`) validates the type design works. Tests are inline `expect` blocks.

**Tech Stack:** Roc (nightly d73ea109cc2 or later). No external dependencies. No platform required for the package crates themselves; the integration smoke test uses `basic-cli`.

**Spec:** `.claude/plans/quine-roc-port/refs/specs/phase-1-graph-node-model.md`

---

## File Map

| File | Purpose |
|------|---------|
| `packages/README.md` | Top-level overview of all packages, dependency diagram |
| `packages/core/README.md` | Core packages overview, links to analysis docs |
| `packages/core/id/README.md` | Identity layer: QuineId, EventTime, QuineIdProvider |
| `packages/core/id/main.roc` | Package header exposing identity modules |
| `packages/core/id/QuineId.roc` | Opaque byte-array identity |
| `packages/core/id/EventTime.roc` | Bit-packed timestamp |
| `packages/core/id/QuineIdProvider.roc` | Pluggable ID scheme record-of-functions |
| `packages/core/model/README.md` | Data layer overview |
| `packages/core/model/main.roc` | Package header exposing model modules |
| `packages/core/model/EdgeDirection.roc` | Edge direction tag union |
| `packages/core/model/HalfEdge.roc` | Half-edge record + reflect |
| `packages/core/model/QuineValue.roc` | Runtime value tagged union (10 variants) |
| `packages/core/model/PropertyValue.roc` | Lazy property value wrapper |
| `packages/core/model/NodeEvent.roc` | NodeChangeEvent and TimestampedEvent |
| `packages/core/model/NodeSnapshot.roc` | Serializable node state |
| `packages/core/model/NodeState.roc` | NodeState + apply_event |
| `app/main.roc` | Integration smoke test |
| `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0001-package-split.md` | ADR-001 |
| `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0002-model-depends-on-id.md` | ADR-002 |
| `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0003-property-value-lazy.md` | ADR-003 |
| `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0004-temporal-types-deferred.md` | ADR-004 |
| `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0005-standing-query-state-deferred.md` | ADR-005 |
| `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0006-apply-event-validation.md` | ADR-006 |

---

## Roc Conventions Used in This Plan

- **Inline tests:** Roc uses `expect` blocks at the top level of a module. Run with `roc test path/to/file.roc`.
- **Opaque types:** `QuineId := List U8` makes `QuineId` opaque outside the module. Inside the module, `@QuineId bytes` wraps and `@QuineId bytes ->` unwraps in pattern matching.
- **Module exposure:** `module [func1, func2, Type1]` lists what the module exposes.
- **Package exposure:** `package [Module1, Module2] {}` lists which modules in the package are public.
- **No null:** All optional values use `Result a err` or `[Some a, None]` tagged unions.
- **Snake case:** Functions and variables use `snake_case`. Types and tags use `PascalCase`.

---

## Task Dependencies

```
Task 1 (scaffolding) → Task 2 (QuineId) → Task 3 (EventTime) → Task 4 (QuineIdProvider)
                                                              → Task 5 (id package main)
Task 5 → Task 6 (EdgeDirection) → Task 7 (HalfEdge)
Task 5, 7 → Task 8 (QuineValue) → Task 9 (PropertyValue) → Task 10 (NodeEvent)
Task 10 → Task 11 (NodeSnapshot) → Task 12 (NodeState)
Task 12 → Task 13 (model package main)
Task 13 → Task 14 (app smoke test)
Task 14 → Task 15 (READMEs and ADRs)
```

All tasks must run sequentially; each builds on the previous one.

---

### Task 1: Project Scaffolding

**Files:**
- Create: `packages/core/id/` (directory)
- Create: `packages/core/model/` (directory)
- Create: `app/` (directory)
- Create: `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/` (directory)
- Create: `packages/README.md` (skeleton)
- Create: `packages/core/README.md` (skeleton)
- Create: `packages/core/id/README.md` (skeleton)
- Create: `packages/core/model/README.md` (skeleton)

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p packages/core/id packages/core/model app
mkdir -p .claude/plans/quine-roc-port/docs/src/adrs/phase-1
```

- [ ] **Step 2: Create skeleton READMEs**

Write `packages/README.md`:

```markdown
# Quine-Roc Packages

Roc packages for the Quine-to-Roc port. Each subdirectory of `core/` is an independent Roc package.

## Layout

- `core/id/` — Identity types: `QuineId`, `EventTime`, `QuineIdProvider`
- `core/model/` — Data types: `QuineValue`, `PropertyValue`, `HalfEdge`, `NodeEvent`, `NodeSnapshot`, `NodeState`. Depends on `core/id`.

## Status

Phase 1 of the [Quine-to-Roc port](../.claude/plans/quine-roc-port/README.md). See [Phase 1 spec](../.claude/plans/quine-roc-port/refs/specs/phase-1-graph-node-model.md).
```

Write `packages/core/README.md`:

```markdown
# Core Packages

Foundational types for the Quine graph model. Two packages:

- [`id/`](id/README.md) — Identity types (no dependencies)
- [`model/`](model/README.md) — Data and event types (depends on `id`)

These types are ports of `quine-core/src/main/scala/com/thatdot/quine/{model,graph}/`. See the [analysis](../../.claude/plans/quine-roc-port/docs/src/core/graph/node/README.md) for the original Scala design.
```

Write `packages/core/id/README.md`:

```markdown
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
```

Write `packages/core/model/README.md`:

```markdown
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
```

- [ ] **Step 3: Verify directories exist**

```bash
ls packages/core/id packages/core/model app .claude/plans/quine-roc-port/docs/src/adrs/phase-1
```

Expected: All four directories exist without errors.

- [ ] **Step 4: Commit**

```bash
git add packages/README.md packages/core/README.md packages/core/id/README.md packages/core/model/README.md
git commit -m "phase-1: scaffold core packages directory structure"
```

---

### Task 2: QuineId

**Files:**
- Create: `packages/core/id/QuineId.roc`

- [ ] **Step 1: Write the module with type, functions, and inline tests**

Write `packages/core/id/QuineId.roc`:

```roc
module [
    QuineId,
    from_bytes,
    to_bytes,
    from_hex_str,
    to_hex_str,
    empty,
]

## An opaque, byte-based identifier for graph nodes.
##
## QuineIds are arbitrary byte arrays. Different ID schemes (UUIDs, longs, strings)
## are wrapped in this opaque type via QuineIdProvider implementations.
QuineId := List U8 implements [Eq { is_eq: is_eq }]

is_eq : QuineId, QuineId -> Bool
is_eq = |@QuineId(a), @QuineId(b)| a == b

## Construct a QuineId from a list of bytes.
from_bytes : List U8 -> QuineId
from_bytes = |bytes| @QuineId(bytes)

## Extract the underlying bytes from a QuineId.
to_bytes : QuineId -> List U8
to_bytes = |@QuineId(bytes)| bytes

## The empty (zero-length) QuineId. Useful for testing.
empty : QuineId
empty = @QuineId([])

## Parse a QuineId from a lowercase hexadecimal string.
##
## Each pair of hex characters becomes one byte. Returns InvalidHex if the
## string has an odd length or contains non-hex characters.
from_hex_str : Str -> Result QuineId [InvalidHex]
from_hex_str = |s|
    chars = Str.to_utf8(s)
    if List.len(chars) % 2 != 0 then
        Err(InvalidHex)
    else
        result = List.walk(
            chars,
            { bytes: [], pending: None },
            |state, c|
                when hex_digit_value(c) is
                    Err(_) -> { bytes: [], pending: Err(InvalidHex) }
                    Ok(v) ->
                        when state.pending is
                            Err(_) -> state
                            None -> { bytes: state.bytes, pending: Some(v) }
                            Some(hi) ->
                                byte = Num.shift_left_by(hi, 4) |> Num.bitwise_or(v)
                                { bytes: List.append(state.bytes, byte), pending: None },
        )
        when result.pending is
            Err(InvalidHex) -> Err(InvalidHex)
            _ -> Ok(@QuineId(result.bytes))

hex_digit_value : U8 -> Result U8 [InvalidHex]
hex_digit_value = |c|
    if c >= '0' and c <= '9' then
        Ok(c - '0')
    else if c >= 'a' and c <= 'f' then
        Ok(c - 'a' + 10)
    else if c >= 'A' and c <= 'F' then
        Ok(c - 'A' + 10)
    else
        Err(InvalidHex)

## Convert a QuineId to a lowercase hexadecimal string.
to_hex_str : QuineId -> Str
to_hex_str = |@QuineId(bytes)|
    chars = List.walk(
        bytes,
        [],
        |acc, b|
            hi = Num.shift_right_zf_by(b, 4)
            lo = Num.bitwise_and(b, 0x0F)
            acc
            |> List.append(hex_char(hi))
            |> List.append(hex_char(lo)),
    )
    Str.from_utf8(chars) |> Result.with_default("")

hex_char : U8 -> U8
hex_char = |n|
    if n < 10 then
        n + '0'
    else
        n - 10 + 'a'

# ===== Tests =====

expect
    qid = from_bytes([1, 2, 3, 4])
    to_bytes(qid) == [1, 2, 3, 4]

expect
    to_bytes(empty) == []

expect
    qid_a = from_bytes([1, 2, 3])
    qid_b = from_bytes([1, 2, 3])
    qid_a == qid_b

expect
    qid_a = from_bytes([1, 2, 3])
    qid_b = from_bytes([1, 2, 4])
    qid_a != qid_b

expect
    # Round trip: bytes -> hex -> bytes
    bytes = [0xde, 0xad, 0xbe, 0xef]
    qid = from_bytes(bytes)
    hex = to_hex_str(qid)
    hex == "deadbeef"

expect
    # Round trip: hex -> QuineId -> hex
    when from_hex_str("deadbeef") is
        Ok(qid) -> to_hex_str(qid) == "deadbeef"
        Err(_) -> Bool.false

expect
    # Empty round trip
    when from_hex_str("") is
        Ok(qid) -> to_bytes(qid) == []
        Err(_) -> Bool.false

expect
    # Odd-length hex is invalid
    when from_hex_str("abc") is
        Err(InvalidHex) -> Bool.true
        _ -> Bool.false

expect
    # Non-hex character is invalid
    when from_hex_str("zz") is
        Err(InvalidHex) -> Bool.true
        _ -> Bool.false

expect
    # Uppercase hex is accepted
    when from_hex_str("DEADBEEF") is
        Ok(qid) -> to_hex_str(qid) == "deadbeef"
        Err(_) -> Bool.false
```

- [ ] **Step 2: Run roc check**

```bash
roc check packages/core/id/QuineId.roc
```

Expected: No errors (warnings about missing platform are fine — modules don't need a platform).

- [ ] **Step 3: Run inline tests**

```bash
roc test packages/core/id/QuineId.roc
```

Expected: All `expect` blocks pass (output shows passing test count).

- [ ] **Step 4: Commit**

```bash
git add packages/core/id/QuineId.roc
git commit -m "phase-1: implement QuineId opaque byte-array type"
```

---

### Task 3: EventTime

**Files:**
- Create: `packages/core/id/EventTime.roc`

- [ ] **Step 1: Write the module with bit-packing functions and tests**

Write `packages/core/id/EventTime.roc`:

```roc
module [
    EventTime,
    from_parts,
    millis,
    message_seq,
    event_seq,
    min_value,
    max_value,
    advance_event,
]

## A high-resolution timestamp for graph events.
##
## Packed into a single U64:
## - Top 42 bits: wall-clock milliseconds since epoch
## - Middle 14 bits: message sequence (disambiguates events in the same ms from different messages)
## - Bottom 8 bits: event sequence (disambiguates events from the same message)
##
## This packing gives every event a globally unique, totally-ordered timestamp.
EventTime := U64 implements [Eq { is_eq: is_eq }]

is_eq : EventTime, EventTime -> Bool
is_eq = |@EventTime(a), @EventTime(b)| a == b

## Bit layout constants
millis_shift : U8
millis_shift = 22

message_seq_shift : U8
message_seq_shift = 8

message_seq_mask : U64
message_seq_mask = 0x3FFF  # 14 bits

event_seq_mask : U64
event_seq_mask = 0xFF  # 8 bits

millis_max : U64
millis_max = 0x3FFFFFFFFFF  # 42 bits

## Construct an EventTime from its three components.
##
## Values are masked to fit their bit-widths; out-of-range inputs are silently truncated.
from_parts : { millis : U64, message_seq : U16, event_seq : U8 } -> EventTime
from_parts = |{ millis: m, message_seq: msg, event_seq: ev }|
    m_bits = Num.bitwise_and(m, millis_max) |> Num.shift_left_by(millis_shift)
    msg_bits = Num.bitwise_and(Num.to_u64(msg), message_seq_mask) |> Num.shift_left_by(message_seq_shift)
    ev_bits = Num.to_u64(ev)
    @EventTime(Num.bitwise_or(m_bits, Num.bitwise_or(msg_bits, ev_bits)))

## Extract the milliseconds-since-epoch component.
millis : EventTime -> U64
millis = |@EventTime(packed)|
    Num.shift_right_zf_by(packed, millis_shift)

## Extract the message sequence component.
message_seq : EventTime -> U16
message_seq = |@EventTime(packed)|
    Num.shift_right_zf_by(packed, message_seq_shift)
    |> Num.bitwise_and(message_seq_mask)
    |> Num.to_u16

## Extract the event sequence component.
event_seq : EventTime -> U8
event_seq = |@EventTime(packed)|
    Num.bitwise_and(packed, event_seq_mask) |> Num.to_u8

## The smallest possible EventTime (all zeros).
min_value : EventTime
min_value = @EventTime(0)

## The largest possible EventTime (all bits set).
max_value : EventTime
max_value = @EventTime(Num.max_u64)

## Increment the event sequence by one. If at maximum, wraps to zero.
##
## Note: this only advances the event sequence. The message and millis components
## are unchanged. Callers needing fresh timestamps for new messages should construct
## a new EventTime via from_parts.
advance_event : EventTime -> EventTime
advance_event = |@EventTime(packed)|
    ev = Num.bitwise_and(packed, event_seq_mask)
    if ev == event_seq_mask then
        # Wrap event sequence to 0, leave the rest alone
        @EventTime(Num.bitwise_and(packed, Num.bitwise_xor(event_seq_mask, Num.max_u64)))
    else
        @EventTime(packed + 1)

## Strict comparison (used for ordering)
is_less : EventTime, EventTime -> Bool
is_less = |@EventTime(a), @EventTime(b)| a < b

# ===== Tests =====

expect
    # Round trip a typical event time
    et = from_parts({ millis: 1000, message_seq: 5, event_seq: 3 })
    millis(et) == 1000 and message_seq(et) == 5 and event_seq(et) == 3

expect
    # Zero parts
    et = from_parts({ millis: 0, message_seq: 0, event_seq: 0 })
    millis(et) == 0 and message_seq(et) == 0 and event_seq(et) == 0

expect
    # Maximum values for each field
    et = from_parts({ millis: millis_max, message_seq: 0x3FFF, event_seq: 0xFF })
    millis(et) == millis_max and message_seq(et) == 0x3FFF and event_seq(et) == 0xFF

expect
    # Two events with same ms but different message seq are different
    et1 = from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    et2 = from_parts({ millis: 1000, message_seq: 1, event_seq: 0 })
    et1 != et2

expect
    # Ordering: earlier ms < later ms
    et1 = from_parts({ millis: 1000, message_seq: 99, event_seq: 99 })
    et2 = from_parts({ millis: 1001, message_seq: 0, event_seq: 0 })
    is_less(et1, et2)

expect
    # Ordering: same ms, smaller msg seq is earlier
    et1 = from_parts({ millis: 1000, message_seq: 0, event_seq: 99 })
    et2 = from_parts({ millis: 1000, message_seq: 1, event_seq: 0 })
    is_less(et1, et2)

expect
    # Ordering: same ms and msg, smaller event seq is earlier
    et1 = from_parts({ millis: 1000, message_seq: 5, event_seq: 0 })
    et2 = from_parts({ millis: 1000, message_seq: 5, event_seq: 1 })
    is_less(et1, et2)

expect
    # min_value < anything
    et = from_parts({ millis: 1, message_seq: 0, event_seq: 0 })
    is_less(min_value, et)

expect
    # max_value > anything
    et = from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    is_less(et, max_value)

expect
    # advance_event increments event seq
    et = from_parts({ millis: 1000, message_seq: 5, event_seq: 3 })
    et2 = advance_event(et)
    event_seq(et2) == 4 and message_seq(et2) == 5 and millis(et2) == 1000

expect
    # advance_event wraps at 0xFF
    et = from_parts({ millis: 1000, message_seq: 5, event_seq: 0xFF })
    et2 = advance_event(et)
    event_seq(et2) == 0 and message_seq(et2) == 5 and millis(et2) == 1000
```

- [ ] **Step 2: Run roc check**

```bash
roc check packages/core/id/EventTime.roc
```

Expected: No errors.

- [ ] **Step 3: Run inline tests**

```bash
roc test packages/core/id/EventTime.roc
```

Expected: All `expect` blocks pass.

- [ ] **Step 4: Commit**

```bash
git add packages/core/id/EventTime.roc
git commit -m "phase-1: implement EventTime bit-packed timestamp"
```

---

### Task 4: QuineIdProvider

**Files:**
- Create: `packages/core/id/QuineIdProvider.roc`

- [ ] **Step 1: Write the module**

Write `packages/core/id/QuineIdProvider.roc`:

```roc
module [
    QuineIdProvider,
    uuid_provider,
]

import QuineId exposing [QuineId]

## A pluggable ID scheme for graph nodes.
##
## QuineIdProvider is a record of functions (a manual vtable / type class) that
## abstracts over different ID generation strategies. Concrete providers implement
## the functions and pass the record around explicitly.
QuineIdProvider : {
    new_id : {} -> QuineId,
    from_bytes : List U8 -> Result QuineId [InvalidId Str],
    to_bytes : QuineId -> List U8,
    from_str : Str -> Result QuineId [InvalidId Str],
    to_str : QuineId -> Str,
    hashed_id : List U8 -> QuineId,
}

## A simple UUID-based provider.
##
## Phase 1 ships a deterministic stub: new_id always returns the empty QuineId,
## and hashed_id returns the input bytes wrapped as a QuineId. A real UUID v4
## generator requires platform support (random bytes) which Phase 1 does not have.
## Phase 2 will swap this for a real implementation.
uuid_provider : QuineIdProvider
uuid_provider = {
    new_id: |{}| QuineId.empty,
    from_bytes: |bytes| Ok(QuineId.from_bytes(bytes)),
    to_bytes: QuineId.to_bytes,
    from_str: |s|
        when QuineId.from_hex_str(s) is
            Ok(qid) -> Ok(qid)
            Err(_) -> Err(InvalidId("not valid hex")),
    to_str: QuineId.to_hex_str,
    hashed_id: |bytes| QuineId.from_bytes(bytes),
}

# ===== Tests =====

expect
    # uuid_provider.new_id returns the empty id (Phase 1 stub)
    p = uuid_provider
    p.new_id({}) == QuineId.empty

expect
    # uuid_provider.from_bytes / to_bytes round trip
    p = uuid_provider
    bytes = [0xde, 0xad, 0xbe, 0xef]
    when p.from_bytes(bytes) is
        Ok(qid) -> p.to_bytes(qid) == bytes
        Err(_) -> Bool.false

expect
    # uuid_provider.to_str / from_str round trip
    p = uuid_provider
    qid = QuineId.from_bytes([0xab, 0xcd])
    s = p.to_str(qid)
    when p.from_str(s) is
        Ok(parsed) -> p.to_bytes(parsed) == [0xab, 0xcd]
        Err(_) -> Bool.false

expect
    # uuid_provider.from_str rejects invalid input
    p = uuid_provider
    when p.from_str("not hex") is
        Err(InvalidId(_)) -> Bool.true
        _ -> Bool.false

expect
    # hashed_id is deterministic for the same bytes
    p = uuid_provider
    qid1 = p.hashed_id([1, 2, 3])
    qid2 = p.hashed_id([1, 2, 3])
    qid1 == qid2
```

- [ ] **Step 2: Run roc check**

```bash
roc check packages/core/id/QuineIdProvider.roc
```

Expected: No errors. Note: Roc may need to resolve `QuineId` from a sibling module — this requires the package header (Task 5) to be present, OR the file may compile standalone with relative imports. If it fails, proceed to Task 5 first and re-run check.

- [ ] **Step 3: Commit**

```bash
git add packages/core/id/QuineIdProvider.roc
git commit -m "phase-1: implement QuineIdProvider with stub uuid_provider"
```

---

### Task 5: id Package Header

**Files:**
- Create: `packages/core/id/main.roc`

- [ ] **Step 1: Write the package header**

Write `packages/core/id/main.roc`:

```roc
package [
    QuineId,
    EventTime,
    QuineIdProvider,
] {}
```

- [ ] **Step 2: Run roc check on the whole package**

```bash
roc check packages/core/id/main.roc
```

Expected: No errors. All three modules compile as a coherent package.

- [ ] **Step 3: Run all tests in the package**

```bash
roc test packages/core/id/main.roc
```

Expected: All `expect` blocks across the three modules pass.

- [ ] **Step 4: Commit**

```bash
git add packages/core/id/main.roc
git commit -m "phase-1: id package header exposing QuineId, EventTime, QuineIdProvider"
```

---

### Task 6: EdgeDirection

**Files:**
- Create: `packages/core/model/EdgeDirection.roc`

- [ ] **Step 1: Write the module**

Write `packages/core/model/EdgeDirection.roc`:

```roc
module [
    EdgeDirection,
    reverse,
]

## The direction of a half-edge.
##
## Outgoing and Incoming reverse to each other; Undirected reverses to itself.
EdgeDirection : [Outgoing, Incoming, Undirected]

## Reverse a direction. Used to construct reciprocal half-edges.
reverse : EdgeDirection -> EdgeDirection
reverse = |dir|
    when dir is
        Outgoing -> Incoming
        Incoming -> Outgoing
        Undirected -> Undirected

# ===== Tests =====

expect reverse(Outgoing) == Incoming
expect reverse(Incoming) == Outgoing
expect reverse(Undirected) == Undirected

expect
    # reverse is involutive
    reverse(reverse(Outgoing)) == Outgoing

expect
    reverse(reverse(Incoming)) == Incoming

expect
    reverse(reverse(Undirected)) == Undirected
```

- [ ] **Step 2: Run roc check and tests**

```bash
roc check packages/core/model/EdgeDirection.roc
roc test packages/core/model/EdgeDirection.roc
```

Expected: No errors, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add packages/core/model/EdgeDirection.roc
git commit -m "phase-1: implement EdgeDirection tag union"
```

---

### Task 7: HalfEdge

**Files:**
- Create: `packages/core/model/HalfEdge.roc`

- [ ] **Step 1: Write the module**

Write `packages/core/model/HalfEdge.roc`:

```roc
module [
    HalfEdge,
    reflect,
]

import id.QuineId exposing [QuineId]
import EdgeDirection exposing [EdgeDirection]

## One side of an edge in the graph.
##
## An edge between nodes A and B exists if and only if A holds a half-edge pointing
## at B AND B holds the reciprocal half-edge pointing at A. This design lets each
## node store only its own half of every edge — no global edge table is needed.
HalfEdge : {
    edge_type : Str,
    direction : EdgeDirection,
    other : QuineId,
}

## Compute the reciprocal half-edge for the other endpoint.
##
## Given a half-edge stored on `this_node`, returns the half-edge that the
## remote endpoint should store. Direction is reversed; the `other` field
## becomes `this_node`.
##
## Example: if A has HalfEdge(:KNOWS, Outgoing, B), then reflect(this, A) on
## that half-edge yields HalfEdge(:KNOWS, Incoming, A) — which B should hold.
reflect : HalfEdge, QuineId -> HalfEdge
reflect = |edge, this_node|
    {
        edge_type: edge.edge_type,
        direction: EdgeDirection.reverse(edge.direction),
        other: this_node,
    }

# ===== Tests =====

expect
    # reflect produces the reciprocal direction
    a_id = QuineId.from_bytes([0x0A])
    b_id = QuineId.from_bytes([0x0B])
    edge_on_a = { edge_type: "KNOWS", direction: Outgoing, other: b_id }
    edge_on_b = reflect(edge_on_a, a_id)
    edge_on_b.edge_type == "KNOWS"
        and edge_on_b.direction == Incoming
        and edge_on_b.other == a_id

expect
    # reflecting Incoming gives Outgoing
    a_id = QuineId.from_bytes([0x0A])
    b_id = QuineId.from_bytes([0x0B])
    edge = { edge_type: "FOLLOWS", direction: Incoming, other: b_id }
    reflected = reflect(edge, a_id)
    reflected.direction == Outgoing

expect
    # reflecting Undirected stays Undirected
    a_id = QuineId.from_bytes([0x0A])
    b_id = QuineId.from_bytes([0x0B])
    edge = { edge_type: "PEER", direction: Undirected, other: b_id }
    reflected = reflect(edge, a_id)
    reflected.direction == Undirected

expect
    # reflect is involutive when called from both sides
    a_id = QuineId.from_bytes([0x0A])
    b_id = QuineId.from_bytes([0x0B])
    edge_on_a = { edge_type: "REL", direction: Outgoing, other: b_id }
    edge_on_b = reflect(edge_on_a, a_id)
    back_to_a = reflect(edge_on_b, b_id)
    back_to_a == edge_on_a
```

- [ ] **Step 2: Run roc check and tests**

Note: This module imports from the `id` package, which requires the model package header to declare `id` as a dependency. The check may fail until Task 13 creates `model/main.roc`. If so, proceed and verify after Task 13.

- [ ] **Step 3: Commit**

```bash
git add packages/core/model/HalfEdge.roc
git commit -m "phase-1: implement HalfEdge with reflect"
```

---

### Task 8: QuineValue

**Files:**
- Create: `packages/core/model/QuineValue.roc`

- [ ] **Step 1: Write the module**

Write `packages/core/model/QuineValue.roc`:

```roc
module [
    QuineValue,
    QuineType,
    quine_type,
]

import id.QuineId exposing [QuineId]

## The runtime value type of Quine.
##
## A tagged union of every value Quine can hold in a property or expression.
## Temporal types (DateTime, Date, Time, Duration, etc.) are deferred to
## a later phase when Cypher temporal functions are needed (see ADR-004).
QuineValue : [
    Str Str,
    Integer I64,
    Floating F64,
    True,
    False,
    Null,
    Bytes (List U8),
    List (List QuineValue),
    Map (Dict Str QuineValue),
    Id QuineId,
]

## A flat enum mirroring QuineValue variants without their data payloads.
## Used for type checking and dispatch.
QuineType : [
    StrType,
    IntegerType,
    FloatingType,
    TrueType,
    FalseType,
    NullType,
    BytesType,
    ListType,
    MapType,
    IdType,
]

## Get the type tag of a QuineValue without unwrapping its data.
quine_type : QuineValue -> QuineType
quine_type = |v|
    when v is
        Str(_) -> StrType
        Integer(_) -> IntegerType
        Floating(_) -> FloatingType
        True -> TrueType
        False -> FalseType
        Null -> NullType
        Bytes(_) -> BytesType
        List(_) -> ListType
        Map(_) -> MapType
        Id(_) -> IdType

# ===== Tests =====

expect quine_type(Str("hello")) == StrType
expect quine_type(Integer(42)) == IntegerType
expect quine_type(Floating(3.14)) == FloatingType
expect quine_type(True) == TrueType
expect quine_type(False) == FalseType
expect quine_type(Null) == NullType
expect quine_type(Bytes([1, 2, 3])) == BytesType
expect quine_type(List([Integer(1), Integer(2)])) == ListType
expect quine_type(Map(Dict.empty({}))) == MapType
expect quine_type(Id(QuineId.from_bytes([0xab]))) == IdType

expect
    # Equality works for primitive variants
    Str("a") == Str("a")

expect
    # Inequality across variants
    Str("1") != Integer(1)

expect
    # Lists with same content are equal
    List([Integer(1), Str("two")]) == List([Integer(1), Str("two")])

expect
    # Nested map equality
    m1 = Dict.empty({}) |> Dict.insert("k", Integer(1))
    m2 = Dict.empty({}) |> Dict.insert("k", Integer(1))
    Map(m1) == Map(m2)

expect
    # Id values compare by underlying bytes
    Id(QuineId.from_bytes([1, 2])) == Id(QuineId.from_bytes([1, 2]))
```

- [ ] **Step 2: Commit**

```bash
git add packages/core/model/QuineValue.roc
git commit -m "phase-1: implement QuineValue with 10 variants and type tags"
```

---

### Task 9: PropertyValue

**Files:**
- Create: `packages/core/model/PropertyValue.roc`

- [ ] **Step 1: Write the module**

Write `packages/core/model/PropertyValue.roc`:

```roc
module [
    PropertyValue,
    from_value,
    from_bytes,
    get_value,
    get_bytes,
]

import QuineValue exposing [QuineValue]

## A property value with lazy serialization state.
##
## A PropertyValue exists in one of three states:
## - Deserialized: holds a QuineValue, no bytes computed yet
## - Serialized: holds raw bytes, value not yet decoded
## - Both: holds both, fully resolved
##
## Phase 1 does not implement real serialization. The transition functions
## (get_value on Serialized, get_bytes on Deserialized) are placeholder
## implementations that demonstrate the API shape. Real ser/deser lands in Phase 2.
PropertyValue : [
    Deserialized QuineValue,
    Serialized (List U8),
    Both { bytes : List U8, value : QuineValue },
]

## Construct a PropertyValue from a QuineValue (no serialization yet).
from_value : QuineValue -> PropertyValue
from_value = |v| Deserialized(v)

## Construct a PropertyValue from raw bytes (no deserialization yet).
##
## Always succeeds in Phase 1 — real validation lands in Phase 2.
from_bytes : List U8 -> Result PropertyValue [InvalidBytes]
from_bytes = |bytes| Ok(Serialized(bytes))

## Get the QuineValue, deserializing if needed.
##
## Phase 1 stub: Serialized variants return Err(DeserializeError) because
## no real serialization format is implemented. Both and Deserialized variants
## return their value.
get_value : PropertyValue -> Result QuineValue [DeserializeError]
get_value = |pv|
    when pv is
        Deserialized(v) -> Ok(v)
        Both({ value }) -> Ok(value)
        Serialized(_) -> Err(DeserializeError)

## Get the bytes, serializing if needed.
##
## Phase 1 stub: Deserialized variants return an empty byte list. Real
## serialization lands in Phase 2.
get_bytes : PropertyValue -> List U8
get_bytes = |pv|
    when pv is
        Serialized(bytes) -> bytes
        Both({ bytes }) -> bytes
        Deserialized(_) -> []

# ===== Tests =====

expect
    # from_value creates Deserialized
    pv = from_value(Integer(42))
    when pv is
        Deserialized(Integer(42)) -> Bool.true
        _ -> Bool.false

expect
    # from_bytes creates Serialized
    when from_bytes([1, 2, 3]) is
        Ok(Serialized([1, 2, 3])) -> Bool.true
        _ -> Bool.false

expect
    # get_value on Deserialized returns the value
    pv = from_value(Str("hi"))
    when get_value(pv) is
        Ok(Str("hi")) -> Bool.true
        _ -> Bool.false

expect
    # get_value on Serialized returns Err (Phase 1 stub)
    when from_bytes([1, 2, 3]) is
        Ok(pv) ->
            when get_value(pv) is
                Err(DeserializeError) -> Bool.true
                _ -> Bool.false
        Err(_) -> Bool.false

expect
    # get_value on Both returns the value
    pv = Both({ bytes: [1, 2], value: Integer(99) })
    when get_value(pv) is
        Ok(Integer(99)) -> Bool.true
        _ -> Bool.false

expect
    # get_bytes on Serialized returns the bytes
    when from_bytes([0xaa, 0xbb]) is
        Ok(pv) -> get_bytes(pv) == [0xaa, 0xbb]
        Err(_) -> Bool.false

expect
    # get_bytes on Deserialized returns empty (Phase 1 stub)
    pv = from_value(Integer(1))
    get_bytes(pv) == []

expect
    # get_bytes on Both returns the bytes
    pv = Both({ bytes: [0xcc], value: Integer(1) })
    get_bytes(pv) == [0xcc]
```

- [ ] **Step 2: Commit**

```bash
git add packages/core/model/PropertyValue.roc
git commit -m "phase-1: implement PropertyValue with lazy serialization stub"
```

---

### Task 10: NodeEvent

**Files:**
- Create: `packages/core/model/NodeEvent.roc`

- [ ] **Step 1: Write the module**

Write `packages/core/model/NodeEvent.roc`:

```roc
module [
    NodeChangeEvent,
    TimestampedEvent,
]

import id.EventTime exposing [EventTime]
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
    # Each variant constructible
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
    # TimestampedEvent wraps a NodeChangeEvent with a time
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    e = PropertySet({ key: "k", value: PropertyValue.from_value(Integer(42)) })
    timed = { event: e, at_time: t }
    timed.at_time == t
```

Note: the tests reference `QuineId.from_bytes` directly without importing — this needs an explicit import. Add `import id.QuineId exposing [QuineId]` to the imports if Roc doesn't auto-resolve it.

- [ ] **Step 2: Commit**

```bash
git add packages/core/model/NodeEvent.roc
git commit -m "phase-1: implement NodeChangeEvent and TimestampedEvent"
```

---

### Task 11: NodeSnapshot

**Files:**
- Create: `packages/core/model/NodeSnapshot.roc`

- [ ] **Step 1: Write the module**

Write `packages/core/model/NodeSnapshot.roc`:

```roc
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
    # Construct an empty snapshot
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    snap = { properties: Dict.empty({}), edges: [], time: t }
    Dict.is_empty(snap.properties) and List.is_empty(snap.edges) and snap.time == t

expect
    # Construct a snapshot with one property
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    props = Dict.empty({}) |> Dict.insert("name", PropertyValue.from_value(Str("Alice")))
    snap = { properties: props, edges: [], time: t }
    Dict.len(snap.properties) == 1
```

- [ ] **Step 2: Commit**

```bash
git add packages/core/model/NodeSnapshot.roc
git commit -m "phase-1: implement NodeSnapshot record"
```

---

### Task 12: NodeState and apply_event

**Files:**
- Create: `packages/core/model/NodeState.roc`

- [ ] **Step 1: Write the module**

Write `packages/core/model/NodeState.roc`:

```roc
module [
    NodeState,
    empty,
    apply_event,
    from_snapshot,
    to_snapshot,
]

import id.EventTime exposing [EventTime]
import PropertyValue exposing [PropertyValue]
import HalfEdge exposing [HalfEdge]
import NodeEvent exposing [NodeChangeEvent]
import NodeSnapshot exposing [NodeSnapshot]

## A node's in-memory state: properties and edges.
##
## This is the live, mutable-by-replacement state held by an active node. It is
## NOT durably persisted directly — see NodeSnapshot for that. NodeState is the
## working representation that apply_event mutates.
NodeState : {
    properties : Dict Str PropertyValue,
    edges : List HalfEdge,
}

## An empty NodeState with no properties and no edges.
empty : NodeState
empty = { properties: Dict.empty({}), edges: [] }

## Apply a NodeChangeEvent to a NodeState, returning the updated state.
##
## This is the core pure function of the node model. Every state mutation
## flows through here. Operations are idempotent where they should be:
## - Setting a property to a value, then setting it again to the same value, is a no-op
## - Removing a non-existent property is a no-op
## - Adding an edge that already exists is a no-op
## - Removing a non-existent edge is a no-op
apply_event : NodeState, NodeChangeEvent -> NodeState
apply_event = |state, event|
    when event is
        PropertySet({ key, value }) ->
            { state & properties: Dict.insert(state.properties, key, value) }

        PropertyRemoved({ key }) ->
            { state & properties: Dict.remove(state.properties, key) }

        EdgeAdded(edge) ->
            if List.contains(state.edges, edge) then
                state
            else
                { state & edges: List.append(state.edges, edge) }

        EdgeRemoved(edge) ->
            { state & edges: List.drop_if(state.edges, |e| e == edge) }

## Restore a NodeState from a NodeSnapshot.
##
## The snapshot's time field is discarded — NodeState has no timestamp of its own.
## Callers needing the time should track it separately.
from_snapshot : NodeSnapshot -> NodeState
from_snapshot = |snap|
    { properties: snap.properties, edges: snap.edges }

## Capture a NodeState as a NodeSnapshot at the given time.
to_snapshot : NodeState, EventTime -> NodeSnapshot
to_snapshot = |state, time|
    { properties: state.properties, edges: state.edges, time: time }

# ===== Tests =====

expect
    # apply PropertySet adds a property
    state = empty
    event = PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })
    new_state = apply_event(state, event)
    Dict.len(new_state.properties) == 1

expect
    # apply PropertyRemoved removes a property
    initial = apply_event(empty, PropertySet({ key: "x", value: PropertyValue.from_value(Integer(1)) }))
    after_remove = apply_event(initial, PropertyRemoved({ key: "x", previous_value: PropertyValue.from_value(Integer(1)) }))
    Dict.is_empty(after_remove.properties)

expect
    # PropertyRemoved on missing key is a no-op
    state = apply_event(empty, PropertyRemoved({ key: "missing", previous_value: PropertyValue.from_value(Null) }))
    Dict.is_empty(state.properties)

expect
    # PropertySet overwrites existing property
    s1 = apply_event(empty, PropertySet({ key: "k", value: PropertyValue.from_value(Integer(1)) }))
    s2 = apply_event(s1, PropertySet({ key: "k", value: PropertyValue.from_value(Integer(2)) }))
    Dict.len(s2.properties) == 1

expect
    # EdgeAdded adds an edge
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    state = apply_event(empty, EdgeAdded(edge))
    List.len(state.edges) == 1

expect
    # EdgeAdded twice is idempotent
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    s1 = apply_event(empty, EdgeAdded(edge))
    s2 = apply_event(s1, EdgeAdded(edge))
    List.len(s2.edges) == 1

expect
    # EdgeRemoved removes the edge
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    s1 = apply_event(empty, EdgeAdded(edge))
    s2 = apply_event(s1, EdgeRemoved(edge))
    List.is_empty(s2.edges)

expect
    # EdgeRemoved on missing edge is a no-op
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) }
    state = apply_event(empty, EdgeRemoved(edge))
    List.is_empty(state.edges)

expect
    # Snapshot round trip preserves state
    initial = empty
    e1 = PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })
    e2 = EdgeAdded({ edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1]) })
    final = empty |> apply_event(e1) |> apply_event(e2)
    t = EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    snap = to_snapshot(final, t)
    restored = from_snapshot(snap)
    restored == final
```

Note: this module needs `QuineId` imported for the tests. Add `import id.QuineId exposing [QuineId]` to the imports.

- [ ] **Step 2: Commit**

```bash
git add packages/core/model/NodeState.roc
git commit -m "phase-1: implement NodeState with apply_event and snapshot round-trip"
```

---

### Task 13: model Package Header

**Files:**
- Create: `packages/core/model/main.roc`

- [ ] **Step 1: Write the package header**

Write `packages/core/model/main.roc`:

```roc
package [
    EdgeDirection,
    HalfEdge,
    QuineValue,
    PropertyValue,
    NodeEvent,
    NodeSnapshot,
    NodeState,
] {
    id: "../id/main.roc",
}
```

- [ ] **Step 2: Run roc check on the package**

```bash
roc check packages/core/model/main.roc
```

Expected: All seven model modules and their dependencies on `id` resolve successfully. If errors mention missing imports, revisit the import statements in each module file (some modules may need `import id.QuineId exposing [QuineId]` added to make tests work standalone).

- [ ] **Step 3: Run all tests in the package**

```bash
roc test packages/core/model/main.roc
```

Expected: All `expect` blocks across all seven model modules pass.

- [ ] **Step 4: Commit**

```bash
git add packages/core/model/main.roc
git commit -m "phase-1: model package header with id dependency"
```

---

### Task 14: Integration Smoke Test App

**Files:**
- Create: `app/main.roc`

- [ ] **Step 1: Write the smoke test app**

Write `app/main.roc`:

```roc
app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/2.0.0/2.0.0.tar.br",
    id: "../packages/core/id/main.roc",
    model: "../packages/core/model/main.roc",
}

import cli.Stdout
import id.QuineId
import id.EventTime
import model.QuineValue exposing [QuineValue]
import model.PropertyValue
import model.HalfEdge
import model.NodeState
import model.NodeEvent

main! : List Str => Result {} _
main! = |_args|
    # Create a node
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

    final = initial
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
        Err(SmokeTestFailed)
```

Note: The exact basic-cli URL/version may need adjustment. Check the latest release at https://github.com/roc-lang/basic-cli/releases and update.

- [ ] **Step 2: Run the app**

```bash
roc run app/main.roc
```

Expected: Prints `Phase 1 smoke test PASSED`. If the basic-cli URL is wrong, the build will report a download error — fix and retry.

- [ ] **Step 3: Run tests on the app**

```bash
roc test app/main.roc
```

Expected: All tests across both packages pass (since the app transitively imports both).

- [ ] **Step 4: Commit**

```bash
git add app/main.roc
git commit -m "phase-1: integration smoke test exercising id and model packages"
```

---

### Task 15: ADRs and Final Documentation

**Files:**
- Create: `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0001-package-split.md`
- Create: `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0002-model-depends-on-id.md`
- Create: `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0003-property-value-lazy.md`
- Create: `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0004-temporal-types-deferred.md`
- Create: `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0005-standing-query-state-deferred.md`
- Create: `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0006-apply-event-validation.md`

- [ ] **Step 1: Write ADR-001**

Write `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0001-package-split.md`:

```markdown
# ADR-001: Two-package split (id, model)

**Status:** Accepted

**Date:** 2026-04-10

## Context

Phase 1 of the Quine-to-Roc port introduces foundational types from the Scala
quine-core module. We had three options for organizing them:

- **A:** Single package containing all types
- **B:** Two packages: id (identity) and model (data + events)
- **C:** Fine-grained per-type packages

## Decision

Use option B: two packages, `packages/core/id/` and `packages/core/model/`.

The `id` package contains pure identity types: QuineId, EventTime, QuineIdProvider.
The `model` package contains data types (QuineValue, PropertyValue), edge types
(HalfEdge, EdgeDirection), and event/state types (NodeEvent, NodeSnapshot, NodeState).

`model` declares `id` as a dependency in its package header.

## Consequences

- Mirrors the Scala reality where QuineId was an external library
- Forces a clean dependency direction (model depends on id, never the reverse)
- Adds some boilerplate (two main.roc headers, two READMEs)
- Splitting later (per-type packages) is easier than merging
- Future packages (persistence, standing queries) can depend on `id` without
  pulling in all of `model`

## Watch For

If `id` and `model` always evolve together and the boundary feels artificial,
consider merging into one package. Phase 2/3 work will reveal whether the split
pulls its weight.
```

- [ ] **Step 2: Write ADR-002**

Write `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0002-model-depends-on-id.md`:

```markdown
# ADR-002: model depends on id directly (not parametric)

**Status:** Accepted

**Date:** 2026-04-10

## Context

`QuineValue` includes an `Id QuineId` variant — values can reference node
identities. This creates a real type-level dependency: `model` needs to know
what a `QuineId` is.

Two options:
- **A:** `model` directly imports `id`, `QuineValue.Id` holds a concrete `QuineId`
- **B:** `QuineValue` becomes generic over the ID type: `QuineValue idType`

## Decision

Use option A. `QuineValue` directly references `QuineId` from the `id` package.

## Consequences

- Simpler types throughout the codebase (no type parameter to thread)
- `id` and `model` are always coupled at the type level
- Cannot have multiple ID schemes coexisting in the same graph

## Watch For

If we ever need multiple ID providers active simultaneously (e.g., a graph with
both UUID-keyed and integer-keyed nodes), refactor `QuineValue.Id` to be
parametric. Until then, the simplicity wins.
```

- [ ] **Step 3: Write ADR-003**

Write `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0003-property-value-lazy.md`:

```markdown
# ADR-003: PropertyValue lazy serialization preserved as tagged union

**Status:** Accepted

**Date:** 2026-04-10

## Context

The Scala `PropertyValue` uses a lazy serialization optimization: it can hold
either a deserialized `QuineValue` or serialized bytes (or both), and defers
the conversion until needed. This optimization matters in Scala because nodes
often hold many properties that are never read during a query.

In Roc, immutable values are cheap to pass around, and the cost-benefit may
differ. We had two options:

- **A:** Preserve the three-state tagged union model
- **B:** Make `PropertyValue` always-eager — just hold a `QuineValue`, serialize on demand

## Decision

Preserve the lazy model in Phase 1, but with stub serialization functions. The
type is `[Deserialized QuineValue, Serialized (List U8), Both { bytes, value }]`.
Real serialization is deferred to Phase 2.

## Consequences

- API shape mirrors the Scala original
- Phase 2 can plug in real serialization (likely MessagePack) without changing
  callers
- Some unnecessary complexity in Phase 1 — every consumer must pattern-match
  on three states

## Watch For

In Phase 2, benchmark the lazy model against the always-eager alternative. If
eager is fast enough and simpler, simplify the type. Roc's value semantics may
make the optimization unnecessary.
```

- [ ] **Step 4: Write ADR-004**

Write `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0004-temporal-types-deferred.md`:

```markdown
# ADR-004: Temporal types deferred from QuineValue

**Status:** Accepted

**Date:** 2026-04-10

## Context

The Scala `QuineValue` includes 6 temporal variants: `DateTime`, `Duration`,
`Date`, `LocalTime`, `Time`, `LocalDateTime`. Roc's standard library does not
have a comprehensive datetime library, and Phase 1 needs to focus on the core
node model rather than building out a temporal type system.

## Decision

Defer all temporal types from Phase 1's `QuineValue`. The Phase 1 type has 10
variants instead of the Scala original's 16: `Str`, `Integer`, `Floating`,
`True`, `False`, `Null`, `Bytes`, `List`, `Map`, `Id`.

## Consequences

- Phase 1 cannot represent Cypher datetime literals
- Phase 5 (Cypher query language) is the natural place to add them, since
  that's where temporal functions like `datetime()` and `duration()` get used
- A migration step is required when temporal types are added: existing
  serialized data must remain readable

## Watch For

When Phase 5 begins, evaluate whether to write temporal types from scratch in
Roc, depend on a community time library, or use FFI to a C/Rust time library.
```

- [ ] **Step 5: Write ADR-005**

Write `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0005-standing-query-state-deferred.md`:

```markdown
# ADR-005: DomainIndexEvent and standing query state deferred

**Status:** Accepted

**Date:** 2026-04-10

## Context

The Scala `NodeEvent` hierarchy includes `DomainIndexEvent` — events that track
standing query subscription bookkeeping (subscribe, unsubscribe, propagate
results). Similarly, `NodeSnapshot` in Scala includes `subscribersToThisNode`
and `domainNodeIndex` fields that track standing query state.

Phase 1 focuses purely on the data model (properties, edges, mutation events).
Standing queries are Phase 4.

## Decision

Phase 1's `NodeChangeEvent` only includes data mutation variants:
`PropertySet`, `PropertyRemoved`, `EdgeAdded`, `EdgeRemoved`. Phase 1's
`NodeSnapshot` and `NodeState` only include `properties` and `edges` (plus
`time` on the snapshot).

## Consequences

- The Phase 1 types are simpler and faster to implement
- Phase 4 will need to extend `NodeChangeEvent` (or introduce a separate
  `NodeEvent` super-type) and add fields to `NodeSnapshot` and `NodeState`
- The extension must be backward-compatible with persistence formats from
  Phase 2 — careful design needed there

## Watch For

When Phase 4 begins, decide whether to expand the existing `NodeChangeEvent`
union or introduce a parent `NodeEvent` type that contains both
`NodeChangeEvent` and `DomainIndexEvent`. The Scala original used the latter.
```

- [ ] **Step 6: Write ADR-006**

Write `.claude/plans/quine-roc-port/docs/src/adrs/phase-1/0006-apply-event-validation.md`:

```markdown
# ADR-006: apply_event included in Phase 1 as the type-validation function

**Status:** Accepted

**Date:** 2026-04-10

## Context

Phase 1 is primarily a type-definition phase — no concurrency, no IO, no
persistence. But pure type definitions in isolation are easy to get wrong: the
real test is whether they compose into actual behavior.

The Scala `AbstractNodeActor.processNodeEvent` method is the central point
where `NodeChangeEvent`s mutate node state. This logic is pure (no actor
mechanics, no IO) and can be ported as a standalone function.

## Decision

Include one behavioral function in Phase 1: `apply_event : NodeState,
NodeChangeEvent -> NodeState`. This pure function pattern-matches on the event
type and returns the updated state. Plus snapshot round-trip helpers
(`to_snapshot`, `from_snapshot`).

## Consequences

- Phase 1 ships with a working "apply event to node" capability — small but real
- The type design gets validated by actually being used
- Idempotency invariants (e.g., re-adding the same edge is a no-op) get tested
- Phase 3 (graph structure) can build on this without redesigning the mutation API

## Watch For

If `apply_event` grows beyond a simple pattern-match (e.g., needs to dispatch
to subsystems, emit derived events, or interact with standing queries), revisit
the boundary. Phase 4 will likely need a richer version.
```

- [ ] **Step 7: Run final acceptance check**

```bash
roc test packages/core/id/main.roc
roc test packages/core/model/main.roc
roc run app/main.roc
```

Expected output:
- All `id` package tests pass
- All `model` package tests pass
- Smoke test prints `Phase 1 smoke test PASSED`

- [ ] **Step 8: Verify acceptance criteria checklist**

Manually verify each item from the spec's acceptance criteria:
- [ ] All 9 type modules exist and compile
- [ ] All inline `expect` tests pass
- [ ] Integration smoke test passes
- [ ] All four READMEs (packages/, core/, id/, model/) exist
- [ ] All 6 ADRs exist
- [ ] `apply_event` handles all 4 `NodeChangeEvent` variants
- [ ] `NodeSnapshot` round-trip preserves state (verified by smoke test and inline test)
- [ ] `HalfEdge.reflect` produces a valid reciprocal (verified by inline test)

- [ ] **Step 9: Commit**

```bash
git add .claude/plans/quine-roc-port/docs/src/adrs/phase-1/
git commit -m "phase-1: ADRs documenting key design decisions"
```

- [ ] **Step 10: Update Phase 1 status in ROADMAP**

Update `.claude/plans/quine-roc-port/ROADMAP.md` to mark Phase 1 as complete:

```markdown
- [x] Phase 1: Graph Node Model — foundational types (QuineId, QuineValue, HalfEdge, NodeChangeEvent, EventTime, NodeSnapshot, QuineIdProvider)
```

```bash
git add .claude/plans/quine-roc-port/ROADMAP.md
git commit -m "phase-1: mark Phase 1 complete in roadmap"
```
