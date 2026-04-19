module [
    shard_for_node,
]

import id.QuineId exposing [QuineId]
import types.Ids exposing [ShardId]

## Route a QuineId to its owning shard.
##
## Uses FNV-1a to map the node's bytes to a shard index in [0, shard_count).
## The same QuineId always routes to the same shard for a given shard_count.
shard_for_node : QuineId, U32 -> ShardId
shard_for_node = |qid, shard_count|
    bytes = QuineId.to_bytes(qid)
    hash = hash_bytes(bytes)
    Num.rem(hash, shard_count)

## FNV-1a hash of a byte list, returning U32.
##
## Uses the standard FNV-1a offset basis (2166136261) and prime (16777619).
## Multiplication wraps on overflow.
hash_bytes : List U8 -> U32
hash_bytes = |bytes|
    List.walk(
        bytes,
        2166136261u32,
        |h, b|
            xored = Num.bitwise_xor(h, Num.to_u32(b))
            Num.mul_wrap(xored, 16777619u32),
    )

# ===== Tests =====

expect
    # Same ID always routes to same shard
    qid = QuineId.from_bytes([1u8, 2u8, 3u8, 4u8])
    shard_for_node(qid, 4u32) == shard_for_node(qid, 4u32)

expect
    # Result is always < shard_count
    qid = QuineId.from_bytes([0xdeu8, 0xadu8, 0xbeu8, 0xefu8])
    result = shard_for_node(qid, 4u32)
    result < 4u32

expect
    # Different IDs produce at least 2 distinct shards (16 IDs across 4 shards)
    ids =
        List.range({ start: At 0u8, end: Before 16u8 })
        |> List.map(|i| QuineId.from_bytes([i]))
    shards =
        List.map(ids, |qid| shard_for_node(qid, 4u32))
    distinct =
        List.walk(
            shards,
            Set.empty {},
            |acc, s| Set.insert(acc, s),
        )
    Set.len(distinct) >= 2

expect
    # shard_count=1 always returns 0
    qid = QuineId.from_bytes([42u8, 17u8])
    shard_for_node(qid, 1u32) == 0u32

expect
    # Empty ID routes deterministically (result < shard_count)
    qid = QuineId.empty
    result = shard_for_node(qid, 8u32)
    result < 8u32
