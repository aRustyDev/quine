module [
    QuineId,
    from_bytes,
    to_bytes,
    from_hex_str,
    to_hex_str,
    empty,
]

## An opaque, byte-based identifier for graph nodes.
##
## QuineIds are arbitrary byte arrays. Different ID schemes (UUIDs, longs, strings)
## are wrapped in this opaque type via QuineIdProvider implementations.
QuineId := List U8 implements [Eq { is_eq: is_eq }, Hash]

is_eq : QuineId, QuineId -> Bool
is_eq = |@QuineId(a), @QuineId(b)| a == b

## Construct a QuineId from a list of bytes.
from_bytes : List U8 -> QuineId
from_bytes = |bytes| @QuineId(bytes)

## Extract the underlying bytes from a QuineId.
to_bytes : QuineId -> List U8
to_bytes = |@QuineId(bytes)| bytes

## The empty (zero-length) QuineId. Useful for testing.
empty : QuineId
empty = @QuineId([])

## Parse a QuineId from a lowercase hexadecimal string.
##
## Each pair of hex characters becomes one byte. Returns InvalidHex if the
## string has an odd length or contains non-hex characters.
from_hex_str : Str -> Result QuineId [InvalidHex]
from_hex_str = |s|
    chars = Str.to_utf8(s)
    if List.len(chars) % 2 != 0 then
        Err(InvalidHex)
    else
        result = List.walk(
            chars,
            { bytes: [], pending: None },
            |state, c|
                when hex_digit_value(c) is
                    Err(_) -> { bytes: [], pending: Err(InvalidHex) }
                    Ok(v) ->
                        when state.pending is
                            Err(_) -> state
                            None -> { bytes: state.bytes, pending: Some(v) }
                            Some(hi) ->
                                byte = Num.shift_left_by(hi, 4) |> Num.bitwise_or(v)
                                { bytes: List.append(state.bytes, byte), pending: None },
        )
        when result.pending is
            Err(InvalidHex) -> Err(InvalidHex)
            _ -> Ok(@QuineId(result.bytes))

hex_digit_value : U8 -> Result U8 [InvalidHex]
hex_digit_value = |c|
    if c >= '0' and c <= '9' then
        Ok(c - '0')
    else if c >= 'a' and c <= 'f' then
        Ok(c - 'a' + 10)
    else if c >= 'A' and c <= 'F' then
        Ok(c - 'A' + 10)
    else
        Err(InvalidHex)

## Convert a QuineId to a lowercase hexadecimal string.
to_hex_str : QuineId -> Str
to_hex_str = |@QuineId(bytes)|
    chars = List.walk(
        bytes,
        [],
        |acc, b|
            hi = Num.shift_right_zf_by(b, 4)
            lo = Num.bitwise_and(b, 0x0F)
            acc
            |> List.append(hex_char(hi))
            |> List.append(hex_char(lo)),
    )
    Str.from_utf8(chars) |> Result.with_default("")

hex_char : U8 -> U8
hex_char = |n|
    if n < 10 then
        n + '0'
    else
        n - 10 + 'a'

# ===== Tests =====

expect
    qid = from_bytes([1, 2, 3, 4])
    to_bytes(qid) == [1, 2, 3, 4]

expect
    to_bytes(empty) == []

expect
    qid_a = from_bytes([1, 2, 3])
    qid_b = from_bytes([1, 2, 3])
    qid_a == qid_b

expect
    qid_a = from_bytes([1, 2, 3])
    qid_b = from_bytes([1, 2, 4])
    qid_a != qid_b

expect
    bytes = [0xde, 0xad, 0xbe, 0xef]
    qid = from_bytes(bytes)
    hex = to_hex_str(qid)
    hex == "deadbeef"

expect
    when from_hex_str("deadbeef") is
        Ok(qid) -> to_hex_str(qid) == "deadbeef"
        Err(_) -> Bool.false

expect
    when from_hex_str("") is
        Ok(qid) -> to_bytes(qid) == []
        Err(_) -> Bool.false

expect
    when from_hex_str("abc") is
        Err(InvalidHex) -> Bool.true
        _ -> Bool.false

expect
    when from_hex_str("zz") is
        Err(InvalidHex) -> Bool.true
        _ -> Bool.false

expect
    when from_hex_str("DEADBEEF") is
        Ok(qid) -> to_hex_str(qid) == "deadbeef"
        Err(_) -> Bool.false
