module [
    QuineValue,
    QuineType,
    quine_type,
]

import id.QuineId exposing [QuineId]

## The runtime value type of Quine.
##
## A tagged union of every value Quine can hold in a property or expression.
## Temporal types (DateTime, Date, Time, Duration, etc.) are deferred to
## a later phase when Cypher temporal functions are needed (see ADR-004).
QuineValue : [
    Str Str,
    Integer I64,
    Floating F64,
    True,
    False,
    Null,
    Bytes (List U8),
    List (List QuineValue),
    Map (Dict Str QuineValue),
    Id QuineId,
]

## A flat enum mirroring QuineValue variants without their data payloads.
## Used for type checking and dispatch.
QuineType : [
    StrType,
    IntegerType,
    FloatingType,
    TrueType,
    FalseType,
    NullType,
    BytesType,
    ListType,
    MapType,
    IdType,
]

## Get the type tag of a QuineValue without unwrapping its data.
quine_type : QuineValue -> QuineType
quine_type = |v|
    when v is
        Str(_) -> StrType
        Integer(_) -> IntegerType
        Floating(_) -> FloatingType
        True -> TrueType
        False -> FalseType
        Null -> NullType
        Bytes(_) -> BytesType
        List(_) -> ListType
        Map(_) -> MapType
        Id(_) -> IdType

# ===== Tests =====

expect quine_type(Str("hello")) == StrType
expect quine_type(Integer(42)) == IntegerType
expect quine_type(Floating(3.14)) == FloatingType
expect quine_type(True) == TrueType
expect quine_type(False) == FalseType
expect quine_type(Null) == NullType
expect quine_type(Bytes([1, 2, 3])) == BytesType
expect quine_type(List([Integer(1), Integer(2)])) == ListType
expect quine_type(Map(Dict.empty({}))) == MapType
expect quine_type(Id(QuineId.from_bytes([0xab]))) == IdType

expect
    Str("a") == Str("a")

expect
    Str("1") != Integer(1)

expect
    List([Integer(1), Str("two")]) == List([Integer(1), Str("two")])

expect
    m1 = Dict.empty({}) |> Dict.insert("k", Integer(1))
    m2 = Dict.empty({}) |> Dict.insert("k", Integer(1))
    Map(m1) == Map(m2)

expect
    Id(QuineId.from_bytes([1, 2])) == Id(QuineId.from_bytes([1, 2]))
