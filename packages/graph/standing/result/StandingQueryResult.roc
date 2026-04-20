module [
    StandingQueryResult,
    StandingQueryId,
    StandingQueryPartId,
    QueryContext,
]

import model.QuineValue exposing [QuineValue]

## UUID identifying a top-level standing query.
StandingQueryId : U128

## Identifies one part of a compiled standing query.
## Computed by hashing the MVSQ AST subtree.
StandingQueryPartId : U64

## A row of named values — the result unit of an MVSQ.
QueryContext : Dict Str QuineValue

## A standing query result emitted to consumers.
StandingQueryResult : {
    is_positive_match : Bool,
    data : Dict Str QuineValue,
}

# ===== Tests =====

expect
    result : StandingQueryResult
    result = { is_positive_match: Bool.true, data: Dict.insert(Dict.empty({}), "name", Str("Alice")) }
    result.is_positive_match == Bool.true

expect
    result : StandingQueryResult
    result = { is_positive_match: Bool.false, data: Dict.empty({}) }
    result.is_positive_match == Bool.false

expect
    ctx : QueryContext
    ctx = Dict.insert(Dict.empty({}), "x", Integer(42))
    when Dict.get(ctx, "x") is
        Ok(Integer(n)) -> n == 42
        _ -> Bool.false

expect
    # StandingQueryId is a U128
    id : StandingQueryId
    id = 12345u128
    id == 12345u128

expect
    # StandingQueryPartId is a U64
    pid : StandingQueryPartId
    pid = 99u64
    pid == 99u64
