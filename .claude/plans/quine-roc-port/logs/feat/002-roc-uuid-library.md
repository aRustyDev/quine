# Feature Request 002: Create a Roc UUID Library

**Status:** Open (deferred — separate side project)
**Filed:** 2026-04-11 (during Phase 2 brainstorming)
**Owner:** TBD
**Target:** Community library, potential Roc ecosystem contribution

## Context

During Phase 1, `QuineIdProvider.uuid_provider` was stubbed because Roc has no UUID
library and `new_id` requires random-byte generation that needs platform support.
Phase 2 will build a real in-memory persistor, and while that doesn't strictly need
random UUIDs, many graph use cases do.

More broadly, UUIDs are a fundamental identity primitive used across countless
domains (databases, distributed systems, APIs, content addressing). Roc's ecosystem
would benefit from a first-class UUID library.

## The Feature Request

Build a general-purpose UUID library for Roc supporting RFC 4122 / RFC 9562 UUID
versions 1 through 8.

### Scope

**Version coverage:**
- **v1** — time-based (MAC + timestamp). Historical, still used.
- **v2** — DCE security (rare, but sometimes required)
- **v3** — name-based with MD5
- **v4** — random (most common)
- **v5** — name-based with SHA-1
- **v6** — reordered time-based (sortable v1)
- **v7** — time-based with random (modern sortable, recommended default for new systems)
- **v8** — custom / free-form

**Core API (minimum):**
- `UUID` opaque type with `implements [Eq, Hash, Inspect]`
- `parse : Str -> Result UUID [InvalidFormat]` — parse canonical hyphenated form
- `to_str : UUID -> Str` — canonical lowercase form
- `to_bytes : UUID -> List U8` — 16-byte array
- `from_bytes : List U8 -> Result UUID [InvalidLength]` — from 16 bytes
- `version : UUID -> U8` — extract version bits
- `variant : UUID -> [NCS, RFC4122, Microsoft, Reserved]` — extract variant bits
- `nil : UUID` — all-zero UUID
- `max : UUID` — all-ones UUID (RFC 9562)

**Per-version generators:**
- `v1 : {} -> Task UUID _` — requires platform time + MAC/random
- `v3 : { namespace : UUID, name : Str } -> UUID` — pure, MD5-based
- `v4 : {} -> Task UUID _` — requires platform random bytes
- `v5 : { namespace : UUID, name : Str } -> UUID` — pure, SHA-1-based
- `v6 : {} -> Task UUID _` — requires platform time
- `v7 : {} -> Task UUID _` — requires platform time + random (the recommended default)
- `v8 : { custom : List U8 } -> UUID` — pure, caller-controlled

**Namespace constants** (from RFC 4122):
- `namespace_dns`, `namespace_url`, `namespace_oid`, `namespace_x500`

## Challenges

1. **Random bytes require platform support.** Pure Roc can't generate randomness.
   Either take `random_bytes : {} -> Task (List U8) _` as a parameter, or design
   the library to work with any platform that provides random generation.

2. **Time requires platform support.** v1/v6/v7 need monotonic timestamps. Same
   solution pattern as random bytes — parameterize on a time source.

3. **Hash functions for v3/v5.** MD5 (v3) and SHA-1 (v5) either need to be
   implemented in pure Roc or imported from another library. Both are non-trivial
   but well-documented algorithms. Pure Roc implementations would be educational
   and useful for other projects.

4. **Pure vs effectful API split.** The v3/v5/v8 generators are pure (no
   randomness, no time). The v1/v4/v6/v7 generators need effects. The API should
   reflect this cleanly — pure generators return `UUID` directly, effectful ones
   return `Task UUID _`.

## Deliverables

- [ ] `uuid/main.roc` package with all 8 version generators
- [ ] Pure MD5 implementation (as internal module or separate lib)
- [ ] Pure SHA-1 implementation (as internal module or separate lib)
- [ ] Comprehensive inline `expect` tests — must cover all RFC test vectors
- [ ] README with examples and comparison to other-language UUID libs
- [ ] Bundle as `.tar.br` for distribution via URL

## Why This Matters

- **Fills a real gap** in the Roc ecosystem (no existing UUID library)
- **Teaches a lot**: bit manipulation, hash algorithms, platform effects, RFC implementation
- **Dependency for Quine itself**: replace the stubbed `uuid_provider` in
  `packages/core/id/QuineIdProvider.roc` with a real implementation
- **Community value**: usable by any Roc project

## Dependencies / Preliminary Work

- Phase 2 (persistence) doesn't strictly block this — the in-memory persistor
  doesn't need real UUIDs. This is a clean side project that can be done in
  parallel or after Phase 2.
- Needs a platform that exposes random bytes and current time. basic-cli covers both.

## Scope Boundary

This is **a separate Roc project, not part of the Quine port**. It lives in its own
repo (e.g., `github.com/aRustyDev/roc-uuid`), is published as a Roc package, and
Quine consumes it as a dependency.

## Related

- Phase 1: `QuineIdProvider.uuid_provider` stub that would be replaced
- `quine-roc-port/docs/src/adrs/phase-1/0002-model-depends-on-id.md`
- The Roc abilities exploration (FR 001) could benefit from a concrete UUID library as a test bed
