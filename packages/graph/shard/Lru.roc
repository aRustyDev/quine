module [
    LruEntry,
    touch,
    evict_candidates,
]

import id.QuineId exposing [QuineId]

## Metadata tracked per awake node for sleep-eviction decisions.
##
## `last_access` is a monotonic timestamp (milliseconds since epoch) updated on
## every message dispatch. `cost_to_sleep` is a signed measure of how expensive
## it is to put this node to sleep — higher means more costly. Nodes with lower
## cost are preferred eviction candidates when access times are equal.
LruEntry : { last_access : U64, cost_to_sleep : I64 }

## Update a node's LRU metadata. Called on every message dispatch.
##
## Inserts or replaces the entry for `qid` with the given `now` timestamp and
## `cost`. Overwrites any previous entry unconditionally — the caller always
## provides fresh values.
touch : Dict QuineId LruEntry, QuineId, U64, I64 -> Dict QuineId LruEntry
touch = |entries, qid, now, cost|
    Dict.insert(entries, qid, { last_access: now, cost_to_sleep: cost })

## Return node IDs to evict, sorted by evictability (oldest + cheapest first).
##
## Candidates are ranked by `last_access` ascending, with `cost_to_sleep`
## ascending as the tiebreaker. Returns up to `count` candidates. If
## `count` exceeds the number of entries, all entries are returned.
evict_candidates : Dict QuineId LruEntry, U64 -> List QuineId
evict_candidates = |entries, count|
    pairs = Dict.to_list(entries)
    sorted = List.sort_with(
        pairs,
        |a, b|
            time_cmp = Num.compare(a.1.last_access, b.1.last_access)
            when time_cmp is
                EQ -> Num.compare(a.1.cost_to_sleep, b.1.cost_to_sleep)
                _ -> time_cmp,
    )
    sorted
    |> List.take_first(count)
    |> List.map(|pair| pair.0)

# ===== Tests =====

expect
    # touch inserts a new entry (Dict.len goes to 1)
    entries = Dict.empty {}
    qid = QuineId.from_bytes([1u8])
    updated = touch(entries, qid, 1000u64, 10i64)
    Dict.len(updated) == 1

expect
    # touch updates existing entry (last_access and cost change)
    qid = QuineId.from_bytes([2u8])
    first = touch(Dict.empty {}, qid, 500u64, 5i64)
    second = touch(first, qid, 999u64, 99i64)
    Dict.len(second) == 1
    and
    (
        when Dict.get(second, qid) is
            Ok(entry) -> entry.last_access == 999u64 and entry.cost_to_sleep == 99i64
            Err(_) -> Bool.false
    )

expect
    # evict_candidates returns oldest first
    qid_old = QuineId.from_bytes([10u8])
    qid_new = QuineId.from_bytes([20u8])
    entries =
        Dict.empty {}
        |> Dict.insert(qid_old, { last_access: 100u64, cost_to_sleep: 0i64 })
        |> Dict.insert(qid_new, { last_access: 200u64, cost_to_sleep: 0i64 })
    candidates = evict_candidates(entries, 2u64)
    when List.first(candidates) is
        Ok(first) -> first == qid_old
        Err(_) -> Bool.false

expect
    # evict_candidates uses cost_to_sleep as tiebreaker (lower cost evicted first)
    qid_cheap = QuineId.from_bytes([30u8])
    qid_costly = QuineId.from_bytes([40u8])
    same_time = 500u64
    entries =
        Dict.empty {}
        |> Dict.insert(qid_costly, { last_access: same_time, cost_to_sleep: 100i64 })
        |> Dict.insert(qid_cheap, { last_access: same_time, cost_to_sleep: 1i64 })
    candidates = evict_candidates(entries, 2u64)
    when List.first(candidates) is
        Ok(first) -> first == qid_cheap
        Err(_) -> Bool.false

expect
    # evict_candidates with count > entries returns all
    qid_a = QuineId.from_bytes([50u8])
    qid_b = QuineId.from_bytes([60u8])
    entries =
        Dict.empty {}
        |> Dict.insert(qid_a, { last_access: 10u64, cost_to_sleep: 0i64 })
        |> Dict.insert(qid_b, { last_access: 20u64, cost_to_sleep: 0i64 })
    candidates = evict_candidates(entries, 100u64)
    List.len(candidates) == 2

expect
    # evict_candidates on empty returns empty
    candidates = evict_candidates(Dict.empty {}, 5u64)
    List.is_empty(candidates)
