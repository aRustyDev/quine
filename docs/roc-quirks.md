# Roc Language Quirks & Workarounds

Discovered during Phase 3–4 implementation of the Quine-to-Roc port.

---

## 1. Recursive Type Equality Across Package Boundaries

**Problem:** `QuineValue` is a recursive tagged union (contains `List (List QuineValue)` and `Map (Dict Str QuineValue)`). When imported across package boundaries, the Roc compiler cannot auto-derive `Eq` for types containing `QuineValue`. This means `==` fails to compile on:
- `Result QuineValue [SomeErr]`
- `Dict Str QuineValue`
- Any record or tagged union containing `QuineValue`

**Workaround:** Create a local `quine_value_eq : QuineValue, QuineValue -> Bool` helper that pattern-matches each variant and compares recursively. For `QuineId` (opaque type), compare via `QuineId.to_bytes(a) == QuineId.to_bytes(b)`. For `F64`, use `Num.is_approx_eq` with zero tolerance (see quirk #3).

**Affected modules:** `ValueConstraint.roc`, `LocalPropertyState.roc`, `LabelsState.roc`, `ResultDiff.roc` — each carries its own copy.

**Future fix:** Could be centralized into a shared `QuineValueEq` utility module if the standing package grows further.

---

## 2. Compiler ICE with Record Destructuring

**Problem:** The Roc compiler panics (`inc_dec.rs:400:26: Expected symbol to be in the map`) when test code uses record destructuring syntax on return values from functions that return records containing complex types like `WatchableEventIndex` and `List NodeChangeEvent`.

Example that triggers ICE:
```roc
{ index, initial_events } = register_standing_query(empty, sub, PropertyChange("name"), props, edges)
```

**Workaround:** Use field access syntax instead:
```roc
result = register_standing_query(empty, sub, PropertyChange("name"), props, edges)
idx = result.index
events = result.initial_events
```

**Affected modules:** `WatchableEventIndex.roc` tests

**Roc version:** nightly pre-release, built from commit `d73ea109cc2`

---

## 3. F64 Does Not Implement Eq

**Problem:** Roc's `F64` type does not derive `Eq`, so `==` cannot be used directly on values containing `F64`. This affects `QuineValue.Floating F64` comparisons.

**Workaround:** Use `Num.is_approx_eq` with `{}` (default epsilon, which is effectively zero for exact comparison):
```roc
Num.is_approx_eq(f1, f2, {})
```

This gives bit-level equality for non-NaN values. NaN != NaN (IEEE 754 semantics).

---

## 4. Sub-Package main.roc Required for Subdirectory Imports

**Problem:** Within a Roc package that uses subdirectories (e.g., `standing/ast/`, `standing/state/`), modules in one subdirectory cannot import from another subdirectory using bare names. The compiler only resolves bare-name imports within the same directory.

**Workaround:** Each subdirectory needs its own `main.roc` declaring it as a sub-package, and the parent `main.roc` must declare shorthand dependencies:

```roc
# packages/graph/standing/main.roc
package [
    ValueConstraint,
    SqPartState,
    ...
] {
    id: "../../core/id/main.roc",
    model: "../../core/model/main.roc",
    ast: "./ast/main.roc",
    state: "./state/main.roc",
    result: "./result/main.roc",
    index: "./index/main.roc",
}
```

Then in `state/SqPartState.roc`:
```roc
import ast.MvStandingQuery exposing [MvStandingQuery]
import result.StandingQueryResult exposing [StandingQueryId]
```

**Affected packages:** `packages/graph/standing/` (`ast/`, `state/`, `result/`, `index/` subdirectories)

---

## 5. Opaque Type Abilities Require Explicit Implementation

**Problem:** When using `Box.box` on `ShardState` containing a `Dict` with opaque keys (e.g., `QuineId`), Roc requires explicit `Hash` and `Eq` implementations on the opaque type. Auto-derivation doesn't work across package boundaries.

**Workaround:** Add explicit `Hash` implementation in the platform's `main.roc`:
```roc
QuineId implements [Hash { hash: quine_id_hash }]
```

**Discovered in:** Phase 3c (graph-to-platform wiring)
