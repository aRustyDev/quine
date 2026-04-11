# Feature Request 001: Explore Roc Abilities for Persistence Interface

**Status:** Open (deferred)
**Filed:** 2026-04-10 (during Phase 2 brainstorming)
**Owner:** TBD
**Target:** Post-Phase 2 exploration, potential upstream contribution to Roc

## Context

During Phase 2 (Persistence Interfaces) brainstorming, we evaluated three approaches
for the `PersistenceAgent` abstraction:

- **A. Record of functions** (chosen for Phase 2)
- **B. Module-based interface**
- **C. Ability-based (Roc type classes)**

We chose **A** because it provides first-class persistor values, supports runtime
polymorphism, and enables decorator chains (BloomFilter wrapping RocksDB, etc.) —
all of which Quine's architecture needs.

**C** was rejected primarily because:
1. Roc abilities are pre-1.0 and less mature for complex use cases beyond stdlib abilities (Eq, Hash)
2. Abilities are type constraints, not first-class values — awkward for decorator chains and collection-based composition
3. Cannot easily store a persistor in a config struct or list

## The Feature Request

Explore whether Roc's ability system could be extended to support Quine's persistence
interface needs. Specifically:

1. **Prototype**: Write a `PersistenceAgent` ability and a simple `InMemoryPersistor`
   that implements it. Verify basic dispatch works.

2. **Stress-test decorator patterns**: Try to implement one decorator (e.g., a logging
   wrapper or a bloom-filter-style wrapper) using only abilities. Document the
   friction points.

3. **Test first-class uses**: Try to store persistors in a list, pass them to a
   function that returns a new persistor, build a config struct holding a persistor.
   Document what works, what doesn't.

4. **Identify gaps**: For each pattern that's awkward or impossible with current
   Roc abilities, write a minimal reproduction and file it upstream (roc-lang/roc
   issues). Potential contribution opportunities:
   - Existential abilities (`exists a. (a : PersistenceAgent, a)`)
   - Ability-bounded records / stored abilities
   - Decorator-friendly inheritance or delegation
   - Whatever primitive is missing for the decorator pattern

5. **Write up findings**: Produce a document comparing the two approaches with concrete
   code examples. Could become a blog post, RFC, or direct upstream issue/PR.

## Success Criteria

- [ ] Prototype compiles and passes basic persistence tests
- [ ] Decorator pattern attempt is documented (succeeded or failed, with reasons)
- [ ] At least one upstream issue/discussion opened if gaps are found
- [ ] Written comparison between record-of-functions and abilities approaches

## Why This Matters

- **Learning**: Deepens FP / type system understanding
- **Contribution**: Exactly the "young ecosystem contribution" opportunity the project
  was chosen to explore
- **Future-proofing**: If abilities become the idiomatic Roc pattern post-1.0, we want
  to know what migration would look like

## Related

- Phase 2 chose Option A (record of functions) — see Phase 2 spec and ADRs
- Cross-reference: `feedback_plan_structure.md` notes these logs are for identified
  feature requests
