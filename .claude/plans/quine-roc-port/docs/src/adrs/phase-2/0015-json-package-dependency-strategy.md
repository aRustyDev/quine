# ADR-015: JSON package dependency strategy — try roc-json, cascade to custom fixes

**Status:** Accepted

**Date:** 2026-04-11

## Context

ADR-008 committed to JSON serialization for Phase 2 (for correctness and
debugging clarity, deferring binary optimization). The implementation
question is where the JSON codec comes from:

- **[`lukewilliamboswell/roc-json`](https://github.com/lukewilliamboswell/roc-json)** is the canonical community JSON package
- Last release: **0.13.0 (April 8, 2025)** — 12 months stale as of this decision
- Supports primitives, records, tagged unions, Lists, Dicts via Roc's built-in `Encoding`/`Decoding` abilities
- 3 open bugs (#38 segfault on `List (Str, Dec)`, #41 panic on empty list, #24 OOM on tests)
- **All 3 open bugs are actually upstream Roc compiler bugs, not roc-json bugs**
- Bug #38's upstream root cause ([roc-lang/roc #6813](https://github.com/roc-lang/roc/issues/6813)) is already CLOSED

## Decision

**Cascading fallback strategy**, starting with `roc-json` and escalating
only if it actually breaks:

### Step 1: Smoke test roc-json as-is

Before committing to roc-json in Phase 2, write a minimal app
(`app/json-smoke.roc`) that:
- Imports `roc-json` at its latest release tarball URL
- Exercises JSON encoding and decoding for every Phase 1 type: `QuineId`,
  `EventTime`, `QuineValue` (every variant), `PropertyValue`, `HalfEdge`,
  `NodeChangeEvent`, `NodeSnapshot`
- Round-trips each type (encode → decode → verify equality)
- Exercises edge cases known to have upstream bugs: empty lists, maps,
  nested tagged unions

Run `roc check` and `roc test` against this app with our current Roc
nightly. If everything passes, use roc-json directly.

### Step 2: If smoke test fails — fork roc-json

If the smoke test fails, clone `roc-json` to `~/code/oss/roc-json` and
investigate. Classify the failure:

- **Failure in roc-json code itself** — patch the fork, run smoke test
  again, open an upstream PR to `lukewilliamboswell/roc-json`. Consume
  via path reference to the fork until the PR is merged (or indefinitely
  if the package is truly dormant).
- **Failure in Roc compiler** — escalate to Step 3.

### Step 3: If root cause is in the Roc compiler — patch local Roc fork

If the failure is a Roc compiler bug rather than a roc-json bug:

1. Switch our local Roc fork at `~/code/oss/roc` to a working branch.
2. Develop a fix for the compiler bug. File an upstream issue/PR against
   `roc-lang/roc`.
3. Build Roc locally from our fork (`cargo build --release` or the Zig
   equivalent depending on compiler version).
4. Point Quine development at the patched local Roc binary (e.g., update
   `/usr/local/bin/roc` symlink, or use an environment variable to
   override, or add a project-local Roc wrapper script).
5. Document the compiler dependency in the Phase 2 spec and
   `reference_roc_fork.md` memory so future sessions know why Quine
   development is using a non-standard Roc build.

### Step 4: Last-resort fallback — roll our own JSON

If Step 3 is untenable (compiler fix is too large, upstream review is
slow, etc.), roll our own minimal JSON encoder/decoder for the ~10 Phase
1 types. Estimated scope: 200-300 lines of Roc. Drop the `roc-json`
dependency entirely.

## Consequences

- **Phase 2 is not blocked by an external package's maintenance cadence.**
  We have a clear escalation ladder if roc-json breaks, and Step 3 means
  we can keep moving even if the bug is upstream.
- **Potential upstream contribution at every step.** This aligns with
  the project's ecosystem-contribution goals:
  - Step 2: PR to `roc-json`
  - Step 3: PR to Roc compiler
  - Step 4: possible standalone Roc JSON package (could replace or
    compete with `roc-json`)
- **Dev environment complexity at Step 3 and beyond.** If we end up
  building Roc from source, every contributor (just you for now) needs
  to rebuild on Roc repo changes and keep the local binary fresh. This
  is acceptable since we already have a Roc fork for other reasons
  (type-info-export investigation).
- **Smoke test is cheap.** The whole Step 1 exercise is roughly one hour
  of work. No commitment lost if it fails — we just escalate.

## Rejected: Roll our own from day one

Skipping directly to Step 4 would avoid all external dependencies but:
- Burns 1-2 days of implementation time on a codec rather than on
  Phase 2's actual purpose (persistence interface and in-memory backend)
- Produces no upstream contribution
- The smoke test is a cheap gate that rules out the "just use roc-json"
  happy path in an hour

## Rejected: Use roc-json without a smoke test

Trusting that roc-json works against our Roc nightly without verification
is how we'd hit a segfault or compiler panic deep in Phase 2 implementation,
wasting days debugging before realizing the issue is in our JSON codec.
The smoke test makes that failure visible upfront.

## Related

- ADR-008 — the commitment to JSON serialization itself
- FR 001 (Roc abilities exploration), FR 002 (Roc UUID library),
  FR 003 (Roc type info export), FR 004 (Roc distributed primitives) —
  all in the same ecosystem-contribution spirit
- `reference_roc_fork.md` memory — documents the local Roc fork
- Phase 2 plan will include a `Task 1b: roc-json smoke test` before
  the first real persistor implementation task
