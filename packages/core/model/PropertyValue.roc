module [
    PropertyValue,
    from_value,
    from_bytes,
    get_value,
    get_bytes,
]

import QuineValue exposing [QuineValue]

## A property value with lazy serialization state.
##
## A PropertyValue exists in one of three states:
## - Deserialized: holds a QuineValue, no bytes computed yet
## - Serialized: holds raw bytes, value not yet decoded
## - Both: holds both, fully resolved
##
## Phase 1 does not implement real serialization. The transition functions
## (get_value on Serialized, get_bytes on Deserialized) are placeholder
## implementations that demonstrate the API shape. Real ser/deser lands in Phase 2.
PropertyValue : [
    Deserialized QuineValue,
    Serialized (List U8),
    Both { bytes : List U8, value : QuineValue },
]

## Construct a PropertyValue from a QuineValue (no serialization yet).
from_value : QuineValue -> PropertyValue
from_value = |v| Deserialized(v)

## Construct a PropertyValue from raw bytes (no deserialization yet).
##
## Always succeeds in Phase 1 — real validation lands in Phase 2.
from_bytes : List U8 -> Result PropertyValue [InvalidBytes]
from_bytes = |bytes| Ok(Serialized(bytes))

## Get the QuineValue, deserializing if needed.
##
## Phase 1 stub: Serialized variants return Err(DeserializeError) because
## no real serialization format is implemented. Both and Deserialized variants
## return their value.
get_value : PropertyValue -> Result QuineValue [DeserializeError]
get_value = |pv|
    when pv is
        Deserialized(v) -> Ok(v)
        Both({ value }) -> Ok(value)
        Serialized(_) -> Err(DeserializeError)

## Get the bytes, serializing if needed.
##
## Phase 1 stub: Deserialized variants return an empty byte list. Real
## serialization lands in Phase 2.
get_bytes : PropertyValue -> List U8
get_bytes = |pv|
    when pv is
        Serialized(bytes) -> bytes
        Both({ bytes }) -> bytes
        Deserialized(_) -> []

# ===== Tests =====

expect
    pv = from_value(Integer(42))
    when pv is
        Deserialized(Integer(42)) -> Bool.true
        _ -> Bool.false

expect
    when from_bytes([1, 2, 3]) is
        Ok(Serialized([1, 2, 3])) -> Bool.true
        _ -> Bool.false

expect
    pv = from_value(Str("hi"))
    when get_value(pv) is
        Ok(Str("hi")) -> Bool.true
        _ -> Bool.false

expect
    when from_bytes([1, 2, 3]) is
        Ok(pv) ->
            when get_value(pv) is
                Err(DeserializeError) -> Bool.true
                _ -> Bool.false
        Err(_) -> Bool.false

expect
    pv = Both({ bytes: [1, 2], value: Integer(99) })
    when get_value(pv) is
        Ok(Integer(99)) -> Bool.true
        _ -> Bool.false

expect
    when from_bytes([0xaa, 0xbb]) is
        Ok(pv) -> get_bytes(pv) == [0xaa, 0xbb]
        Err(_) -> Bool.false

expect
    pv = from_value(Integer(1))
    get_bytes(pv) == []

expect
    pv = Both({ bytes: [0xcc], value: Integer(1) })
    get_bytes(pv) == [0xcc]
