# Quine-to-Roc Port

Rewriting [Quine](https://quine.io) — a streaming graph interpreter — from Scala to [Roc](https://roc-lang.org).

## Approach

1. **Analysis-first:** Comprehensive survey of the Quine Scala codebase following the data lifecycle
2. **Interleaved by layer:** Analyze a stage → design Roc equivalent → build → move to next stage

## Key Documents

- [SPEC.md](SPEC.md) — Codebase analysis specification
- [PLAN.md](PLAN.md) — Implementation plan (created after analysis)
- [ROADMAP.md](ROADMAP.md) — High-level timeline and milestones
- [docs/](docs/) — mdbook documentation with per-stage analysis

## Structure

```
quine-roc-port/
├── docs/src/          — Analysis documentation (mdbook)
│   ├── core/          — Graph node, structure, concurrency, persistence, standing queries
│   ├── interface/     — Query languages, ingest, API, outputs
│   ├── cross-cutting/ — Serialization, config, error handling, metrics
│   └── adrs/          — Architecture Decision Records
├── analysis/          — Raw analysis findings and experiments
├── research/          — Research notes and results
├── phase/             — Phase tracking documents
├── logs/              — Bug and feature request logs
└── refs/              — Reference materials, specs, strategies
```
