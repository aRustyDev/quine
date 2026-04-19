module [
    ShardId,
    RequestId,
    NamespaceId,
    StandingQueryPartId,
    next_request_id,
]

## Identifies a shard actor managing a partition of nodes.
ShardId : U32

## Uniquely identifies an in-flight request to a node.
##
## Monotonically increasing counter managed by the caller. The shard
## increments its local counter on each outgoing request and threads the
## resulting RequestId through to the corresponding reply so callers can
## correlate responses without shared mutable state.
RequestId : U64

## Identifies a namespace in the graph.
##
## Phase 3 supports only a single Default namespace. Multi-tenancy is deferred.
NamespaceId : [Default]

## Identifies one part of a compiled standing query.
##
## A standing query may be decomposed into multiple sub-patterns; each part
## has its own ID so partial matches can be correlated at the shard level.
StandingQueryPartId : U64

## Allocate the next RequestId from a monotonic counter.
##
## Takes the current counter value and returns the ID to use plus the
## next counter value. This functional idiom avoids shared mutable state —
## callers thread the counter through their logic.
##
## Example:
##   { id: req_id, next_counter: counter2 } = next_request_id(counter)
next_request_id : U64 -> { id : RequestId, next_counter : U64 }
next_request_id = |counter|
    { id: counter, next_counter: counter + 1 }

# ===== Tests =====

expect
    result = next_request_id(1)
    result.id == 1 and result.next_counter == 2

expect
    r1 = next_request_id(0)
    r2 = next_request_id(r1.next_counter)
    r3 = next_request_id(r2.next_counter)
    r1.id == 0 and r2.id == 1 and r3.id == 2

expect
    # next_counter is always id + 1
    result = next_request_id(100)
    result.next_counter == result.id + 1

expect
    # sequential calls produce incrementing ids
    r1 = next_request_id(42)
    r2 = next_request_id(r1.next_counter)
    r2.id == r1.id + 1
