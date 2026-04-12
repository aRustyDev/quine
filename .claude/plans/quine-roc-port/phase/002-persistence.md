# Phase 2: Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an in-memory `Persistor` backend with 12 operations (journal append, snapshot put, metadata put/get, etc.), validated via unit + component + integration tests, using `roc-json` for serialization with a documented fallback cascade.

**Architecture:** Two Roc sub-packages under `packages/persistor/` — `common/` for shared error types (if any) and `memory/` for the in-memory implementation. The implementation exposes an opaque `Persistor` handle with module-level functions that thread state (per ADR-013). Events are append-only; snapshots and metadata use last-write-wins semantics (per ADR-012).

**Tech Stack:** Roc (nightly d73ea109cc2 or later), `lukewilliamboswell/roc-json` 0.13.0 as the serialization dependency (with fallback cascade per ADR-015), `basic-cli` for the integration smoke test app.

**Spec:** `.claude/plans/quine-roc-port/refs/specs/phase-2-persistence.md`

---

## File Map

| File | Purpose |
|------|---------|
| `packages/core/id/QuineId.roc` | **Modify:** add `Hash` to abilities list |
| `packages/core/id/EventTime.roc` | **Modify:** add `Hash` to abilities list |
| `packages/persistor/README.md` | Overview of persistor concept and backend layout |
| `packages/persistor/common/README.md` | Common types package overview |
| `packages/persistor/common/main.roc` | Package header for `common` sub-package |
| `packages/persistor/common/PersistorError.roc` | Shared error tag variants (network-looking forward variants) |
| `packages/persistor/memory/README.md` | In-memory backend overview |
| `packages/persistor/memory/main.roc` | Package header for `memory` sub-package |
| `packages/persistor/memory/Persistor.roc` | Opaque `Persistor` type + all 12 operations with inline unit tests |
| `packages/persistor/memory/PersistorTest.roc` | Component tests (multi-step scenarios, not exposed from main.roc) |
| `app/json-smoke.roc` | roc-json compatibility smoke test |
| `app/phase-2-smoke.roc` | Integration test exercising Phase 1 + Phase 2 together |
| `.claude/plans/quine-roc-port/ROADMAP.md` | **Modify:** mark Phase 2 complete |

---

## Roc Conventions Recap

- **Inline tests:** `expect` blocks at the top level of a module. Run with `roc test path/to/file.roc`.
- **Opaque types:** `Persistor := { ... }` with internal access via `@Persistor(state)` pattern. Public functions take/return the opaque type; internals never leak.
- **Module exposure:** `module [func1, Type1]` lists public API.
- **Package headers:** `package [Module1, Module2] { depname: "../path/to/main.roc" }`.
- **Snake case** for functions/variables, **PascalCase** for types/tags.
- **State threading:** mutating operations take `Persistor` as first argument and return a new `Persistor` in `Result`. Roc's refcount-1 optimization makes this efficient.
- **Dict requires Hash + Eq on the key type.** Opaque wrappers auto-derive `Hash` if the underlying type has it.

---

## Task Dependencies

```
Task 0 (add Hash to Phase 1 types)
  → Task 1 (scaffolding)
    → Task 2 (roc-json smoke test)
      → Task 3 (common package header)
        → Task 4 (memory package: Persistor type + `new`)
          → Task 5-16 (one operation per task, in order)
            → Task 17 (memory package header)
              → Task 18 (component tests)
                → Task 19 (integration smoke test)
                  → Task 20 (READMEs and roadmap)
```

All tasks are sequential except that **Tasks 5-16 must be done in the listed order** because each task's tests may depend on earlier operations being present (e.g., `get_events` tests call `append_events`).

---

### Task 0: Add Hash ability to Phase 1 opaque types

**Files:**
- Modify: `packages/core/id/QuineId.roc`
- Modify: `packages/core/id/EventTime.roc`

- [ ] **Step 1: Add Hash to QuineId's implements list**

Edit `packages/core/id/QuineId.roc`. Find the line:

```roc
QuineId := List U8 implements [Eq { is_eq: is_eq }]
```

Change it to:

```roc
QuineId := List U8 implements [Eq { is_eq: is_eq }, Hash]
```

- [ ] **Step 2: Run roc check on QuineId**

```bash
roc check packages/core/id/QuineId.roc
```

Expected: Exit 0, no errors. If Hash auto-derivation fails, you'll get a specific error — fall back to the manual-Hash implementation below.

**Manual Hash fallback** (only if auto-derivation fails):

Add at the top, after the existing `is_eq`:

```roc
QuineId := List U8 implements [Eq { is_eq: is_eq }, Hash { hash: hash_impl }]

hash_impl : hasher, QuineId -> hasher where hasher implements Hasher
hash_impl = |hasher, @QuineId(bytes)| Hash.hash(hasher, bytes)
```

Add `import` of `Hash` at the top if needed.

- [ ] **Step 3: Run QuineId tests**

```bash
roc test packages/core/id/QuineId.roc
```

Expected: All 10 existing tests still pass.

- [ ] **Step 4: Add Hash to EventTime's implements list**

Edit `packages/core/id/EventTime.roc`. Find the line:

```roc
EventTime := U64 implements [Eq { is_eq: is_eq }]
```

Change it to:

```roc
EventTime := U64 implements [Eq { is_eq: is_eq }, Hash]
```

- [ ] **Step 5: Run checks and tests on EventTime**

```bash
roc check packages/core/id/EventTime.roc
roc test packages/core/id/EventTime.roc
```

Expected: Both exit 0 with no errors. All 11 existing tests pass. If auto-derivation fails, apply the manual fallback pattern from Step 2.

- [ ] **Step 6: Run tests on the full id package**

```bash
roc test packages/core/id/main.roc
```

Expected: All 26 tests pass.

- [ ] **Step 7: Commit**

```bash
git add packages/core/id/QuineId.roc packages/core/id/EventTime.roc
git commit -m "phase-2: add Hash ability to QuineId and EventTime"
```

---

### Task 1: Scaffold the persistor package directories

**Files:**
- Create: `packages/persistor/README.md`
- Create: `packages/persistor/common/README.md`
- Create: `packages/persistor/memory/README.md`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p packages/persistor/common packages/persistor/memory
```

- [ ] **Step 2: Write packages/persistor/README.md**

Create `packages/persistor/README.md`:

```markdown
# Quine-Roc Persistor

Persistence backends for the Quine-Roc port. Each subdirectory is an
independent Roc package implementing (or contributing to) the persistor
interface.

## Layout

- `common/` — Shared types used by all backends (error variants)
- `memory/` — In-memory backend. No durability; used for tests,
  development, and small graphs. Depends on `common` and `core/{id,model}`.

Future backends will land as siblings (e.g., `rocksdb/`, `cassandra/`).

## Interface

The public API of each backend module is an opaque `Persistor` type and
twelve operations covering append-only journals, snapshots, and metadata.
See ADR-013 for the interface design and ADR-012 for the operation naming
convention (append vs put vs get vs delete).

## Status

Phase 2 of the [Quine-to-Roc port](../../.claude/plans/quine-roc-port/README.md).
See the [Phase 2 spec](../../.claude/plans/quine-roc-port/refs/specs/phase-2-persistence.md).
```

- [ ] **Step 3: Write packages/persistor/common/README.md**

Create `packages/persistor/common/README.md`:

```markdown
# persistor/common

Shared types used across persistor backends.

## Modules

- `PersistorError` — Forward-looking error variants including network-ish
  errors (`Unavailable`, `Timeout`) that appear in public signatures but
  are never produced by in-memory backends.

## Dependencies

- `core/id` — for `QuineId` and `EventTime` references in error variants
- `core/model` — for any model types referenced in errors

## Scala Counterpart

Scala Quine's persistor error types are scattered across
`quine-core/src/main/scala/com/thatdot/quine/persistor/`. This package
consolidates the subset relevant to Phase 2.

## Analysis

See [`docs/src/core/persistence/README.md`](../../../.claude/plans/quine-roc-port/docs/src/core/persistence/README.md).
```

- [ ] **Step 4: Write packages/persistor/memory/README.md**

Create `packages/persistor/memory/README.md`:

```markdown
# persistor/memory

In-memory `Persistor` backend for the Quine-Roc port.

## Purpose

- Test backend for Phase 3+ code (standing queries, query languages, etc.)
- Reference implementation for the `Persistor` interface shape
- Development backend for small graphs or short-lived processes
- NOT production storage — data is lost when the process exits

## Modules

- `Persistor` — Opaque `Persistor` type with 12 operations: append_events,
  get_events, put_snapshot, get_latest_snapshot, put_metadata, get_metadata,
  get_all_metadata, delete_events_for_node, delete_snapshots_for_node,
  delete_metadata, empty_of_quine_data, shutdown.

## Dependencies

- `common` — for error types
- `core/id` — for `QuineId`, `EventTime`
- `core/model` — for `NodeSnapshot`, `TimestampedEvent`, `PropertyValue`
- External: `lukewilliamboswell/roc-json` for JSON serialization (see ADR-015)

## Scala Counterpart

- `quine-core/src/main/scala/com/thatdot/quine/persistor/InMemoryPersistor.scala`

## Analysis

See [`docs/src/core/persistence/README.md`](../../../.claude/plans/quine-roc-port/docs/src/core/persistence/README.md).
```

- [ ] **Step 5: Verify directory and files**

```bash
ls -la packages/persistor/common packages/persistor/memory
```

Expected: Both directories exist, each with a README.md.

- [ ] **Step 6: Commit**

```bash
git add packages/persistor/README.md packages/persistor/common/README.md packages/persistor/memory/README.md
git commit -m "phase-2: scaffold persistor package directories with READMEs"
```

---

### Task 2: roc-json smoke test

**Files:**
- Create: `app/json-smoke.roc`

This task implements the ADR-015 smoke test: before committing Phase 2 to roc-json, verify it works with all Phase 1 types against our current Roc nightly. If the smoke test fails, escalate per ADR-015 (fork roc-json → patch local Roc → roll our own).

- [ ] **Step 1: Find the current roc-json release URL**

Get the latest release tarball URL from GitHub:

```bash
gh api repos/lukewilliamboswell/roc-json/releases/latest --jq '.assets[0].browser_download_url' 2>&1
```

As of this plan's writing, the latest release is 0.13.0 and the URL is:
`https://github.com/lukewilliamboswell/roc-json/releases/download/0.13.0/[hash].tar.br`

Replace `[hash]` with the actual asset hash from the command output. Update Step 2 below with this exact URL.

- [ ] **Step 2: Write app/json-smoke.roc**

Create `app/json-smoke.roc` with the URL from Step 1:

```roc
app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.13.0/[UPDATE-WITH-ACTUAL-HASH].tar.br",
    id: "../packages/core/id/main.roc",
    model: "../packages/core/model/main.roc",
}

import cli.Stdout
import cli.Arg exposing [Arg]
import json.Json
import id.QuineId
import id.EventTime
import model.QuineValue
import model.PropertyValue
import model.HalfEdge
import model.NodeEvent
import model.NodeSnapshot

main! : List Arg => Result {} _
main! = |_args|
    # Test: round-trip a simple QuineValue through JSON
    qv = Integer(42)
    qv_bytes = Encode.to_bytes(qv, Json.utf8)
    qv_decoded : Result QuineValue _
    qv_decoded = Decode.from_bytes(qv_bytes, Json.utf8)

    when qv_decoded is
        Ok(Integer(42)) -> Stdout.line!("QuineValue round-trip: PASSED")
        _ -> Stdout.line!("QuineValue round-trip: FAILED")?

    # Test: round-trip a QuineValue with a nested List
    qv2 = List([Integer(1), Str("hello"), True])
    qv2_bytes = Encode.to_bytes(qv2, Json.utf8)
    qv2_decoded : Result QuineValue _
    qv2_decoded = Decode.from_bytes(qv2_bytes, Json.utf8)

    when qv2_decoded is
        Ok(_) -> Stdout.line!("QuineValue List round-trip: PASSED")
        _ -> Stdout.line!("QuineValue List round-trip: FAILED")?

    # Test: round-trip an empty list (known Roc compiler bug hazard)
    empty : List I64
    empty = []
    empty_bytes = Encode.to_bytes(empty, Json.utf8)
    empty_decoded : Result (List I64) _
    empty_decoded = Decode.from_bytes(empty_bytes, Json.utf8)

    when empty_decoded is
        Ok([]) -> Stdout.line!("Empty list round-trip: PASSED")
        _ -> Stdout.line!("Empty list round-trip: FAILED")?

    # Test: round-trip a HalfEdge record
    qid = QuineId.from_bytes([0xAA, 0xBB])
    edge = { edge_type: "KNOWS", direction: Outgoing, other: qid }
    edge_bytes = Encode.to_bytes(edge, Json.utf8)
    edge_decoded : Result HalfEdge _
    edge_decoded = Decode.from_bytes(edge_bytes, Json.utf8)

    when edge_decoded is
        Ok(_) -> Stdout.line!("HalfEdge round-trip: PASSED")
        _ -> Stdout.line!("HalfEdge round-trip: FAILED")?

    Stdout.line!("All smoke tests PASSED — roc-json works with our types")
```

**Note:** If Roc's `Encoding`/`Decoding` ability can't derive for `QuineValue` because it's a tagged union with variants carrying `Dict` values, you'll see a compile error at the `Encode.to_bytes(qv, ...)` call. If that happens, escalate to ADR-015 Step 2 (fork roc-json).

- [ ] **Step 3: Run roc check on the smoke test**

```bash
roc check app/json-smoke.roc
```

Expected: Exit 0, no errors.

**If it fails:**
- If the error is "type X does not implement ability Y" — this is a roc-json limitation. Escalate per ADR-015 Step 2.
- If the error is a compiler panic or segfault — this is a Roc compiler bug. Escalate per ADR-015 Step 3 (patch local Roc fork).
- If the error is something else — investigate case-by-case.

- [ ] **Step 4: Run the smoke test**

```bash
roc app/json-smoke.roc
```

Expected output:
```
QuineValue round-trip: PASSED
QuineValue List round-trip: PASSED
Empty list round-trip: PASSED
HalfEdge round-trip: PASSED
All smoke tests PASSED — roc-json works with our types
```

**If any round-trip fails:** the type's Roc-derived JSON codec is producing output that can't be decoded back to an equal value. Investigate which type is failing and decide whether to:
- Adjust the type definition (e.g., add missing ability)
- File an issue upstream on roc-json
- Fall back to the cascade in ADR-015

- [ ] **Step 5: Commit**

```bash
git add app/json-smoke.roc
git commit -m "phase-2: roc-json smoke test validates all Phase 1 types round-trip"
```

---

### Task 3: Common package header and PersistorError module

**Files:**
- Create: `packages/persistor/common/PersistorError.roc`
- Create: `packages/persistor/common/main.roc`

- [ ] **Step 1: Write PersistorError.roc**

Create `packages/persistor/common/PersistorError.roc`:

```roc
module [
    NetworkError,
    SerializationError,
]

## Forward-looking network-ish error variants.
##
## These errors appear in every public Persistor operation's error tag union
## but are never produced by the in-memory backend. Including them from day
## one forces callers to handle them, so future distributed backends can slot
## in without breaking the API. See ADR-013.
NetworkError : [
    Unavailable,
    Timeout,
    NotLeader,
]

## Errors that arise when encoding or decoding values.
##
## `Str` field carries a human-readable description of the failure.
SerializationError : [
    SerializeError Str,
    DeserializeError Str,
]

# ===== Tests =====

expect
    # NetworkError variants are constructible
    e : NetworkError
    e = Unavailable
    when e is
        Unavailable -> Bool.true
        _ -> Bool.false

expect
    # SerializationError variants are constructible
    e : SerializationError
    e = DeserializeError("bad utf-8")
    when e is
        DeserializeError(_) -> Bool.true
        _ -> Bool.false
```

- [ ] **Step 2: Write common/main.roc**

Create `packages/persistor/common/main.roc`:

```roc
package [
    PersistorError,
] {}
```

- [ ] **Step 3: Run roc check and tests**

```bash
roc check packages/persistor/common/main.roc
roc test packages/persistor/common/main.roc
```

Expected: Both exit 0. Both expect blocks pass.

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/common/PersistorError.roc packages/persistor/common/main.roc
git commit -m "phase-2: common package with forward-looking error types"
```

---

### Task 4: Memory package — Persistor opaque type and `new`

**Files:**
- Create: `packages/persistor/memory/Persistor.roc`

This task establishes the module shape with the empty-persistor case only. All 12 operations are added in subsequent tasks.

- [ ] **Step 1: Write Persistor.roc with opaque type and `new`**

Create `packages/persistor/memory/Persistor.roc`:

```roc
module [
    Persistor,
    Config,
    new,
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

# ===== Tests =====

expect
    # new produces an opaque Persistor
    p = new({})
    when p is
        @Persistor(_) -> Bool.true
```

- [ ] **Step 2: Run roc check**

At this point the module imports from `common`, `id`, and `model`, but the memory package header (Task 17) doesn't exist yet. `roc check` on the file directly will probably fail with unknown-package errors. That's expected — we'll verify it compiles after Task 17.

Run:
```bash
roc check packages/persistor/memory/Persistor.roc 2>&1 | tail -5
```

Expected: either clean (if imports auto-resolve) or package-shorthand errors. Package-shorthand errors are OK at this stage — defer compilation to Task 17.

- [ ] **Step 3: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor opaque type and empty constructor"
```

---

### Task 5: `put_metadata` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add put_metadata to the module header**

Edit `packages/persistor/memory/Persistor.roc`. Change the `module` declaration:

```roc
module [
    Persistor,
    Config,
    new,
    put_metadata,
]
```

- [ ] **Step 2: Add the put_metadata function**

Append this function definition after `new` in `packages/persistor/memory/Persistor.roc` (and before the `# ===== Tests =====` section):

```roc
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
```

- [ ] **Step 3: Add a unit test for put_metadata**

Append this expect block to the `# ===== Tests =====` section:

```roc
expect
    # put_metadata stores a value at a key
    p = new({})
    when put_metadata(p, "version", [0x01, 0x02]) is
        Ok(@Persistor(state)) ->
            Dict.get(state.metadata, "version") == Ok([0x01, 0x02])
        Err(_) -> Bool.false
```

- [ ] **Step 4: Commit (tests will run in Task 17 when the package header exists)**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.put_metadata"
```

---

### Task 6: `get_metadata` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add get_metadata to the module header**

Edit the `module` block to include `get_metadata`:

```roc
module [
    Persistor,
    Config,
    new,
    put_metadata,
    get_metadata,
]
```

- [ ] **Step 2: Add the get_metadata function**

Append after `put_metadata`:

```roc
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
```

- [ ] **Step 3: Add unit tests**

Append to the tests section:

```roc
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.get_metadata"
```

---

### Task 7: `delete_metadata` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add delete_metadata to the module header**

```roc
module [
    Persistor,
    Config,
    new,
    put_metadata,
    get_metadata,
    delete_metadata,
]
```

- [ ] **Step 2: Add the delete_metadata function**

Append after `get_metadata`:

```roc
## Remove a metadata key. No-op if the key does not exist.
delete_metadata :
    Persistor,
    Str
    -> Result Persistor [Unavailable, Timeout]
delete_metadata = |@Persistor(state), key|
    new_metadata = Dict.remove(state.metadata, key)
    Ok(@Persistor({ state & metadata: new_metadata }))
```

- [ ] **Step 3: Add unit tests**

```roc
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.delete_metadata"
```

---

### Task 8: `get_all_metadata` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add get_all_metadata to the module header**

```roc
module [
    Persistor,
    Config,
    new,
    put_metadata,
    get_metadata,
    delete_metadata,
    get_all_metadata,
]
```

- [ ] **Step 2: Add the get_all_metadata function**

```roc
## Retrieve all metadata as a Dict. Returns an empty Dict if no metadata
## has been stored.
get_all_metadata :
    Persistor
    -> Result (Dict Str (List U8)) [Unavailable, Timeout]
get_all_metadata = |@Persistor(state)|
    Ok(state.metadata)
```

- [ ] **Step 3: Add unit tests**

```roc
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.get_all_metadata"
```

---

### Task 9: `append_events` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

This is the first append-only operation. Enforces that duplicate `(QuineId, EventTime)` pairs cannot be inserted — an overwrite attempt returns `Err (DuplicateEventTime t)`.

- [ ] **Step 1: Add append_events to the module header**

```roc
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
```

- [ ] **Step 2: Add the append_events function**

Append:

```roc
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
```

**Note on the implementation:** The `List.walk_until` is a short-circuit fold. We build up the updated node-event dict one event at a time, and if any event's time already exists, we bail out with `DuplicateEventTime`. All events are rejected atomically — if event 3 is a duplicate, events 1 and 2 are NOT written.

- [ ] **Step 3: Add unit tests**

```roc
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.append_events with duplicate rejection"
```

---

### Task 10: `get_events` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add get_events to the module header**

```roc
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
]
```

- [ ] **Step 2: Add the get_events function**

```roc
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
```

**Note:** The `event_time_to_u64` helper reconstructs the packed U64 by decomposing and re-packing. If this feels ugly, the alternative is to add a `to_u64` export to Phase 1's EventTime module, but that's a Phase 1 modification we'd rather avoid. Revisit if this becomes a hot path.

- [ ] **Step 3: Add unit tests**

```roc
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.get_events with time range filtering"
```

---

### Task 11: `delete_events_for_node` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add to module header**

```roc
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
]
```

- [ ] **Step 2: Add the function**

```roc
## Delete all journal events for a node. No-op if the node has no events.
delete_events_for_node :
    Persistor,
    QuineId
    -> Result Persistor [Unavailable, Timeout]
delete_events_for_node = |@Persistor(state), qid|
    new_events = Dict.remove(state.events, qid)
    Ok(@Persistor({ state & events: new_events }))
```

- [ ] **Step 3: Add unit tests**

```roc
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.delete_events_for_node"
```

---

### Task 12: `put_snapshot` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add to module header**

```roc
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
]
```

- [ ] **Step 2: Add the function**

```roc
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
```

- [ ] **Step 3: Add unit tests**

```roc
expect
    # put_snapshot stores a snapshot
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    snap : NodeSnapshot
    snap = { properties: Dict.empty({}), edges: [], time: t }
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
    snap1 = { properties: Dict.empty({}), edges: [], time: t }
    props = Dict.empty({}) |> Dict.insert("k", PropertyValue.from_value(Integer(1)))
    snap2 : NodeSnapshot
    snap2 = { properties: props, edges: [], time: t }
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.put_snapshot with last-write-wins"
```

---

### Task 13: `get_latest_snapshot` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add to module header**

```roc
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
]
```

- [ ] **Step 2: Add the function**

```roc
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
```

- [ ] **Step 3: Add unit tests**

```roc
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
    snap1 = { properties: Dict.empty({}), edges: [], time: t1 }
    snap2 : NodeSnapshot
    snap2 = { properties: Dict.empty({}), edges: [], time: t2 }
    snap3 : NodeSnapshot
    snap3 = { properties: Dict.empty({}), edges: [], time: t3 }
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.get_latest_snapshot"
```

---

### Task 14: `delete_snapshots_for_node` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add to module header**

```roc
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
]
```

- [ ] **Step 2: Add the function**

```roc
## Delete all snapshots for a node. No-op if the node has no snapshots.
delete_snapshots_for_node :
    Persistor,
    QuineId
    -> Result Persistor [Unavailable, Timeout]
delete_snapshots_for_node = |@Persistor(state), qid|
    new_snapshots = Dict.remove(state.snapshots, qid)
    Ok(@Persistor({ state & snapshots: new_snapshots }))
```

- [ ] **Step 3: Add unit tests**

```roc
expect
    # delete_snapshots_for_node removes all snapshots for a node
    p = new({})
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    snap : NodeSnapshot
    snap = { properties: Dict.empty({}), edges: [], time: t }
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.delete_snapshots_for_node"
```

---

### Task 15: `empty_of_quine_data` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add to module header**

```roc
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
]
```

- [ ] **Step 2: Add the function**

```roc
## Returns true if the persistor holds no node data (events or snapshots).
##
## Metadata is not considered "quine data" — a persistor with only metadata
## entries is still considered empty for node purposes.
empty_of_quine_data :
    Persistor
    -> Result Bool [Unavailable, Timeout]
empty_of_quine_data = |@Persistor(state)|
    Ok(Dict.is_empty(state.events) and Dict.is_empty(state.snapshots))
```

- [ ] **Step 3: Add unit tests**

```roc
expect
    # empty_of_quine_data returns true on a fresh persistor
    p = new({})
    when empty_of_quine_data(p) is
        Ok(Bool.true) -> Bool.true
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
                Ok(Bool.false) -> Bool.true
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
                        Ok(Bool.true) -> Bool.true
                        _ -> Bool.false
                _ -> Bool.false
        _ -> Bool.false

expect
    # empty_of_quine_data ignores metadata — metadata-only persistor is empty
    p = new({})
    when put_metadata(p, "version", [0x01]) is
        Ok(p1) ->
            when empty_of_quine_data(p1) is
                Ok(Bool.true) -> Bool.true
                _ -> Bool.false
        _ -> Bool.false
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.empty_of_quine_data"
```

---

### Task 16: `shutdown` operation

**Files:**
- Modify: `packages/persistor/memory/Persistor.roc`

- [ ] **Step 1: Add to module header**

```roc
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
```

- [ ] **Step 2: Add the function**

```roc
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
```

- [ ] **Step 3: Add unit test**

```roc
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
```

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/Persistor.roc
git commit -m "phase-2: Persistor.shutdown (no-op for in-memory)"
```

---

### Task 17: Memory package header and full test run

**Files:**
- Create: `packages/persistor/memory/main.roc`

- [ ] **Step 1: Write the package header**

Create `packages/persistor/memory/main.roc`:

```roc
package [
    Persistor,
] {
    common: "../common/main.roc",
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
}
```

- [ ] **Step 2: Run roc check on the package**

```bash
roc check packages/persistor/memory/main.roc
```

Expected: Exit 0, no errors. All imports in `Persistor.roc` resolve now that the package header exists.

**If errors appear:** they'll be the first time `Persistor.roc` is type-checked in context. Fix them one at a time. Common issues:
- Missing import for a type you referenced — add to `import` block
- Function signature mismatch — double-check against the task it was defined in
- Unused import warnings — remove them

- [ ] **Step 3: Run all unit tests**

```bash
roc test packages/persistor/memory/main.roc
```

Expected: All ~30 unit tests from Tasks 5-16 pass. Tests accumulated across tasks should now all run together.

- [ ] **Step 4: Commit**

```bash
git add packages/persistor/memory/main.roc
git commit -m "phase-2: memory package header; all unit tests passing"
```

---

### Task 18: Component tests (multi-step scenarios)

**Files:**
- Create: `packages/persistor/memory/PersistorTest.roc`

- [ ] **Step 1: Write the component test module**

Create `packages/persistor/memory/PersistorTest.roc`:

```roc
module []

import id.QuineId exposing [QuineId]
import id.EventTime exposing [EventTime]
import model.PropertyValue
import model.NodeEvent exposing [TimestampedEvent]
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
    snap = { properties: props_at_t1, edges: [], time: t1 }

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
    snap = { properties: Dict.empty({}), edges: [], time: t }
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
            Ok(Bool.true) -> Bool.true
            _ -> Bool.false

    # After an event: not empty
    qid = QuineId.from_bytes([0x01])
    t = EventTime.from_parts({ millis: 100, message_seq: 0, event_seq: 0 })
    e = { event: PropertySet({ key: "k", value: PropertyValue.from_value(Integer(1)) }), at_time: t }

    after_append =
        when Persistor.append_events(p, qid, [e]) is
            Ok(p1) ->
                when Persistor.empty_of_quine_data(p1) is
                    Ok(Bool.false) -> Bool.true
                    _ -> Bool.false
            _ -> Bool.false

    # After delete: empty again
    full_cycle =
        when Persistor.append_events(p, qid, [e]) is
            Ok(p1) ->
                when Persistor.delete_events_for_node(p1, qid) is
                    Ok(p2) ->
                        when Persistor.empty_of_quine_data(p2) is
                            Ok(Bool.true) -> Bool.true
                            _ -> Bool.false
                    _ -> Bool.false
            _ -> Bool.false

    init_empty and after_append and full_cycle
```

**Note:** `PersistorTest.roc` is NOT listed in `memory/main.roc`'s package exports — it's a test-only module that Roc still runs expect blocks for via `roc test packages/persistor/memory/main.roc`. If Roc requires test modules to be exposed from the package header to be found, add `PersistorTest` to the `package [...]` list in `memory/main.roc`.

- [ ] **Step 2: Run all tests including component tests**

```bash
roc test packages/persistor/memory/main.roc
```

Expected: All unit tests from previous tasks plus the 4 component test scenarios pass.

**If component tests aren't being picked up:** Roc may require them to be exposed from the package header. Edit `memory/main.roc` to add `PersistorTest` to the `package [...]` list, rerun the test command.

- [ ] **Step 3: Commit**

```bash
git add packages/persistor/memory/PersistorTest.roc packages/persistor/memory/main.roc
git commit -m "phase-2: component tests for multi-step Persistor scenarios"
```

---

### Task 19: Integration smoke test

**Files:**
- Create: `app/phase-2-smoke.roc`

- [ ] **Step 1: Write the smoke test app**

Create `app/phase-2-smoke.roc`:

```roc
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
import model.NodeEvent
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
    # Find the latest snapshot at or before t2
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
```

**Note:** The test uses `crash` for the error path to fail fast with a visible message. Real production code would handle errors more gracefully.

- [ ] **Step 2: Run the smoke test**

```bash
roc app/phase-2-smoke.roc
```

Expected output:
```
Phase 2 smoke test PASSED
```

- [ ] **Step 3: Commit**

```bash
git add app/phase-2-smoke.roc
git commit -m "phase-2: integration smoke test — full write/crash/restore cycle"
```

---

### Task 20: Final acceptance and roadmap update

**Files:**
- Modify: `.claude/plans/quine-roc-port/ROADMAP.md`

- [ ] **Step 1: Run the full test suite one last time**

```bash
roc test packages/core/id/main.roc
roc test packages/core/model/main.roc
roc test packages/persistor/common/main.roc
roc test packages/persistor/memory/main.roc
roc app/main.roc
roc app/json-smoke.roc
roc app/phase-2-smoke.roc
```

Expected:
- Phase 1 `id` package: 26 tests pass
- Phase 1 `model` package: 49 tests pass
- `persistor/common`: 2 tests pass
- `persistor/memory`: ~30 unit tests + 4 component tests pass
- Phase 1 smoke test: "Phase 1 smoke test PASSED"
- roc-json smoke test: "All smoke tests PASSED"
- Phase 2 smoke test: "Phase 2 smoke test PASSED"

- [ ] **Step 2: Verify every acceptance criterion**

From the spec's Acceptance Criteria section, manually verify each:

- [ ] `packages/persistor/common/` and `packages/persistor/memory/` exist with all listed files
- [ ] `roc check` passes on both sub-packages
- [ ] `roc test` passes on both sub-packages
- [ ] `app/phase-2-smoke.roc` compiles and runs, prints "Phase 2 smoke test PASSED"
- [ ] `app/json-smoke.roc` compiles and runs
- [ ] `append_events` rejects duplicate `(QuineId, EventTime)` pairs
- [ ] Snapshot round-trip via serialize → bytes → deserialize produces an equal `NodeSnapshot`
- [ ] The integration smoke test's reconstructed `NodeState` matches the pre-"crash" state exactly
- [ ] All 9 Phase 2 ADRs exist (ADR-007 through ADR-015)
- [ ] Each package has a README
- [ ] Phase 1 test suite still passes

- [ ] **Step 3: Update ROADMAP.md**

Edit `.claude/plans/quine-roc-port/ROADMAP.md`. Find the line:

```markdown
- [ ] Phase 2: Persistence Interfaces — PersistenceAgent interface, PersistenceConfig, BinaryFormat, InMemoryPersistor; defer RocksDB FFI and Cassandra
```

Change to:

```markdown
- [x] Phase 2: Persistence Interfaces — PersistenceAgent interface, PersistenceConfig, BinaryFormat, InMemoryPersistor; defer RocksDB FFI and Cassandra
```

- [ ] **Step 4: Commit**

```bash
git add .claude/plans/quine-roc-port/ROADMAP.md
git commit -m "phase-2: mark Phase 2 complete in roadmap"
```

- [ ] **Step 5: Final summary**

Write a brief summary of what was built, files created, and test counts as the final commit message body, ready for merging into main.

```bash
echo "Phase 2 complete:"
echo "- Created packages/persistor/common/ (2 tests)"
echo "- Created packages/persistor/memory/ (~30 unit + 4 component tests)"
echo "- Created app/json-smoke.roc (roc-json validation)"
echo "- Created app/phase-2-smoke.roc (integration test)"
echo "- Modified Phase 1 to add Hash ability to QuineId and EventTime"
echo "- All 9 Phase 2 ADRs (007-015) committed during brainstorming"
```
