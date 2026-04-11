# Feature Request 003: Roc Machine-Readable Type Info Export

**Status:** In progress — investigation plan scaffolded
**Filed:** 2026-04-11 (during Phase 2 brainstorming)
**Owner:** TBD
**Location:** `~/code/oss/roc/.claude/plans/type-info-export/`
**GitHub:** [aRustyDev/roc @ investigate-type-info-export](https://github.com/aRustyDev/roc/tree/investigate-type-info-export)
**Target:** Upstream Roc contribution (roc-lang/roc)

## Context

During Phase 2 brainstorming, we chose the hybrid approach for error types:
- **Public API:** Explicit signatures (stable contracts, documented errors)
- **Private implementation:** Wildcard `_` (open tag union inference)

This works well for the Quine port itself, but surfaces a wider Roc ecosystem gap:
**the compiler can infer rich type information but has no machine-readable output
mode for external tooling.**

Rust has `cargo check --message-format=json` which every Rust dev tool depends on.
Roc has `roc docs` (HTML only, unclear how it handles wildcards) and no equivalent
for machine consumption.

## What This Enables

- Doc generators that list all possible errors an API can return
- IDE tooling that shows inferred types without re-running the compiler
- CI validators that check public signatures match expected contracts
- Code generators driven by Roc type information

## Investigation Plan

A full investigation plan is scaffolded in the Roc fork at
`~/code/oss/roc/.claude/plans/type-info-export/` with 5 phases:

- **R-1: Baseline Exploration** — What does Roc do today? Test `roc docs`, `roc check` flags, LSP hover, hidden subcommands
- **R-2: Compiler Internals Mapping** — Where does inferred type data live? Locate the type environment, find serialization seams
- **R-3: Gap Analysis** — Combine findings, decide contribution shape (new subcommand, new flag, extended docs, library API)
- **R-4: Prototype (optional)** — Minimum viable implementation on a feature branch
- **R-5: Upstream Engagement** — File issue / RFC / PR depending on findings

## Non-Blocking

This investigation is explicitly non-blocking for the Quine-to-Roc port. The
hybrid approach works regardless of whether this contribution lands. If the
investigation stalls or concludes without a contribution, Quine proceeds
unchanged.

## Why This Matters

- **Fills a real ecosystem gap** that affects every Roc project with a public API
- **High-leverage contribution** — one subcommand benefits many projects
- **Teaches compiler internals** — a valuable learning path for the user
- **Aligns with the project philosophy** of contributing to young ecosystems

## Related

- Origin: Quine Phase 2 brainstorming, error-type design question
- Companion: FR 001 (Roc abilities exploration for persistence)
- Companion: FR 002 (Roc UUID library)
