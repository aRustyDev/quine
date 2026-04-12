# ADR-014: Persistor package layout — sub-packages from day one

**Status:** Accepted

**Date:** 2026-04-11

## Context

Phase 2 introduces the first persistor. Future phases will add more backends
(RocksDB via FFI, Cassandra via FFI, file-based, etc.). The question is
whether to start with a single package that we split later, or structure
for multiple backends from day one.

Two options:

- **A. Single package for Phase 2** — `packages/persistor/` with one `main.roc`
  exposing an interface module and the in-memory implementation. Refactor
  to sub-packages when a second backend lands.
- **B. Sub-packages from day one** — `packages/persistor/common/` and
  `packages/persistor/memory/` with separate `main.roc` headers. Matches
  Phase 1's `core/id` + `core/model` pattern.

## Decision

Use **Option B: sub-packages from day one**.

```
packages/
  persistor/
    common/
      README.md
      main.roc               # package [PersistorError, ...] { id, model }
      PersistorError.roc     # Shared error variants (if any)
    memory/
      README.md
      main.roc               # package [Persistor] { common, id, model }
      Persistor.roc          # Opaque Persistor type + all 12 operations
```

Future backends land as siblings under `packages/persistor/`:

```
packages/
  persistor/
    common/
    memory/
    rocksdb/                 # Future
    cassandra/               # Further future
```

## Consequences

- **Consistent with Phase 1 pattern** — `packages/core/id` and `packages/core/model`
  use the same sub-package structure.
- **No future refactor** — when a second backend lands, it's a new sibling
  directory, not a file reshuffling.
- **Dependency isolation** — each backend is an independent package. A
  consumer that only wants the in-memory backend doesn't drag in RocksDB
  FFI setup, Cassandra drivers, etc.
- **Minimal upfront cost** — one extra `main.roc` file (the `common/` header)
  compared to a single-package approach. About 10 minutes of setup.
- **Common types go in `common/`** — shared error tag unions, shared type
  aliases, anything multiple backends need. The `common` package has no
  implementation code, only types.

## Rejected: Single package (Option A)

Would save ~10 minutes of setup today at the cost of a refactor when
backend #2 lands. The refactor would split one `main.roc` into three,
rewire imports in every module, and update consumers. Not catastrophic
but clearly more work than starting sub-packaged.

## Watch For

- If `packages/persistor/common/` stays empty or near-empty for a long time
  (e.g., Phase 2 doesn't actually discover shared types beyond what's
  already in `core/model`), consider whether `common/` is pulling its
  weight or if it's just ceremony.
- If backends end up having very different interfaces (e.g., RocksDB
  requires an async init that in-memory doesn't), we may want a more
  sophisticated abstraction than "same opaque Persistor type across all
  backends." That's a problem for the day a second backend lands.

## Related

- ADR-013 — the opaque `Persistor` handle + module-based interface this
  layout implements
- Phase 1's `core/id` + `core/model` structure — this ADR matches that pattern
