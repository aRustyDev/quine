module [
    encode_node_msg,
    decode_node_msg,
    encode_shard_envelope,
    decode_shard_envelope,
]

import id.QuineId exposing [QuineId]
import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]
import model.EdgeDirection exposing [EdgeDirection]
import model.QuineValue exposing [QuineValue]
import types.Messages exposing [NodeMessage, LiteralCommand]

# ===== Primitive Encoders =====

## Encode a U16 in little-endian byte order.
encode_u16 : U16 -> List U8
encode_u16 = |n|
    lo = Num.int_cast(Num.bitwise_and(n, 0xFF))
    hi = Num.int_cast(Num.shift_right_zf_by(n, 8))
    [lo, hi]

## Decode a U16 from little-endian bytes at the given offset.
decode_u16 : List U8, U64 -> Result { val : U16, next : U64 } [OutOfBounds]
decode_u16 = |buf, offset|
    lo_result = List.get(buf, offset)
    hi_result = List.get(buf, offset + 1)
    when (lo_result, hi_result) is
        (Ok(lo), Ok(hi)) ->
            val : U16
            val =
                Num.int_cast(lo)
                |> Num.bitwise_or(Num.shift_left_by(Num.int_cast(hi), 8))
            Ok({ val, next: offset + 2 })

        _ -> Err(OutOfBounds)

## Encode a U64 in little-endian byte order.
encode_u64 : U64 -> List U8
encode_u64 = |n|
    List.range({ start: At(0), end: Before(8) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))

## Decode a U64 from little-endian bytes at the given offset.
decode_u64 : List U8, U64 -> Result { val : U64, next : U64 } [OutOfBounds]
decode_u64 = |buf, offset|
    result = List.walk_until(
        List.range({ start: At(0u64), end: Before(8u64) }),
        Ok(0u64),
        |acc, i|
            when acc is
                Err(_) -> Break(acc)
                Ok(so_far) ->
                    when List.get(buf, offset + i) is
                        Err(_) -> Break(Err(OutOfBounds))
                        Ok(b) ->
                            shifted : U64
                            shifted = Num.shift_left_by(Num.int_cast(b), Num.int_cast(i) * 8)
                            Continue(Ok(Num.bitwise_or(so_far, shifted))),
    )
    when result is
        Ok(val) -> Ok({ val, next: offset + 8 })
        Err(e) -> Err(e)

# ===== Length-Prefixed Encoders =====

## Encode a byte list with a U16LE length prefix.
encode_bytes : List U8 -> List U8
encode_bytes = |bytes|
    len : U16
    len = Num.int_cast(List.len(bytes))
    encode_u16(len) |> List.concat(bytes)

## Decode a length-prefixed byte list at the given offset.
decode_bytes : List U8, U64 -> Result { val : List U8, next : U64 } [OutOfBounds]
decode_bytes = |buf, offset|
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: len_u16, next: data_start }) ->
            len = Num.int_cast(len_u16)
            extracted = List.sublist(buf, { start: data_start, len })
            if List.len(extracted) == len then
                Ok({ val: extracted, next: data_start + len })
            else
                Err(OutOfBounds)

## Encode a UTF-8 string with a U16LE length prefix.
encode_str : Str -> List U8
encode_str = |s|
    encode_bytes(Str.to_utf8(s))

## Decode a length-prefixed UTF-8 string at the given offset.
decode_str : List U8, U64 -> Result { val : Str, next : U64 } [OutOfBounds, BadUtf8]
decode_str = |buf, offset|
    when decode_bytes(buf, offset) is
        Err(OutOfBounds) -> Err(OutOfBounds)
        Ok({ val: bytes, next }) ->
            when Str.from_utf8(bytes) is
                Ok(s) -> Ok({ val: s, next })
                Err(_) -> Err(BadUtf8)

# ===== EdgeDirection =====

## Encode an EdgeDirection as a single byte.
encode_direction : EdgeDirection -> U8
encode_direction = |dir|
    when dir is
        Outgoing -> 0x01
        Incoming -> 0x02
        Undirected -> 0x03

## Decode an EdgeDirection from a single byte.
decode_direction : U8 -> Result EdgeDirection [InvalidDirection]
decode_direction = |b|
    when b is
        0x01 -> Ok(Outgoing)
        0x02 -> Ok(Incoming)
        0x03 -> Ok(Undirected)
        _ -> Err(InvalidDirection)

# ===== PropertyValue =====

## Encode a PropertyValue with a leading tag byte.
encode_property_value : PropertyValue -> List U8
encode_property_value = |pv|
    when pv is
        Deserialized(qv) -> encode_quine_value(qv)
        Serialized(bytes) -> List.concat([0x07], encode_bytes(bytes))
        Both({ bytes }) -> List.concat([0x07], encode_bytes(bytes))

encode_quine_value : QuineValue -> List U8
encode_quine_value = |qv|
    when qv is
        Str(s) -> List.concat([0x01], encode_str(s))
        Integer(i) ->
            bits : U64
            bits = Num.int_cast(i)
            List.concat([0x02], encode_u64(bits))

        Floating(_) ->
            # F64 encoding deferred; encode as Null
            [0x06]

        True -> [0x04]
        False -> [0x05]
        Null -> [0x06]
        Bytes(b) -> List.concat([0x07], encode_bytes(b))
        List(_) ->
            # List encoding deferred; encode as Null
            [0x06]

        Map(_) ->
            # Map encoding deferred; encode as Null
            [0x06]

        Id(qid) -> List.concat([0x08], encode_bytes(QuineId.to_bytes(qid)))

## Decode a PropertyValue from the buffer at the given offset.
decode_property_value : List U8, U64 -> Result { val : PropertyValue, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_property_value = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            data_start = offset + 1
            when tag is
                0x01 ->
                    when decode_str(buf, data_start) is
                        Ok({ val: s, next }) -> Ok({ val: Deserialized(Str(s)), next })
                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8)

                0x02 ->
                    when decode_u64(buf, data_start) is
                        Ok({ val: bits, next }) ->
                            i : I64
                            i = Num.int_cast(bits)
                            Ok({ val: Deserialized(Integer(i)), next })

                        Err(e) -> Err(e)

                0x04 -> Ok({ val: Deserialized(True), next: data_start })
                0x05 -> Ok({ val: Deserialized(False), next: data_start })
                0x06 -> Ok({ val: Deserialized(Null), next: data_start })
                0x07 ->
                    when decode_bytes(buf, data_start) is
                        Ok({ val: bytes, next }) -> Ok({ val: Serialized(bytes), next })
                        Err(e) -> Err(e)

                0x08 ->
                    when decode_bytes(buf, data_start) is
                        Ok({ val: bytes, next }) ->
                            Ok({ val: Deserialized(Id(QuineId.from_bytes(bytes))), next })

                        Err(e) -> Err(e)

                _ -> Err(InvalidTag)

# ===== HalfEdge =====

## Encode a HalfEdge: [edge_type as str] [direction:U8] [other_qid as bytes]
encode_half_edge : HalfEdge -> List U8
encode_half_edge = |edge|
    encode_str(edge.edge_type)
    |> List.append(encode_direction(edge.direction))
    |> List.concat(encode_bytes(QuineId.to_bytes(edge.other)))

## Decode a HalfEdge from the buffer at the given offset.
decode_half_edge : List U8, U64 -> Result { val : HalfEdge, next : U64 } [OutOfBounds, BadUtf8, InvalidDirection]
decode_half_edge = |buf, offset|
    when decode_str(buf, offset) is
        Ok({ val: edge_type, next: dir_offset }) ->
            when List.get(buf, dir_offset) is
                Err(_) -> Err(OutOfBounds)
                Ok(dir_byte) ->
                    when decode_direction(dir_byte) is
                        Err(e) -> Err(e)
                        Ok(direction) ->
                            when decode_bytes(buf, dir_offset + 1) is
                                Ok({ val: qid_bytes, next }) ->
                                    Ok({
                                        val: {
                                            edge_type,
                                            direction,
                                            other: QuineId.from_bytes(qid_bytes),
                                        },
                                        next,
                                    })

                                Err(e) -> Err(e)

        Err(OutOfBounds) -> Err(OutOfBounds)
        Err(BadUtf8) -> Err(BadUtf8)

# ===== NodeMessage Encoding =====

## Encode a NodeMessage to a List U8.
encode_node_msg : NodeMessage -> List U8
encode_node_msg = |msg|
    when msg is
        LiteralCmd(cmd) -> encode_literal_cmd(cmd)
        SleepCheck({ now }) ->
            List.concat([0x07], encode_u64(now))

encode_literal_cmd : LiteralCommand -> List U8
encode_literal_cmd = |cmd|
    when cmd is
        GetProps({ reply_to }) ->
            List.concat([0x01], encode_u64(reply_to))

        SetProp({ key, value, reply_to }) ->
            [0x02]
            |> List.concat(encode_u64(reply_to))
            |> List.concat(encode_str(key))
            |> List.concat(encode_property_value(value))

        RemoveProp({ key, reply_to }) ->
            [0x03]
            |> List.concat(encode_u64(reply_to))
            |> List.concat(encode_str(key))

        AddEdge({ edge, reply_to }) ->
            [0x04]
            |> List.concat(encode_u64(reply_to))
            |> List.concat(encode_half_edge(edge))

        RemoveEdge({ edge, reply_to }) ->
            [0x05]
            |> List.concat(encode_u64(reply_to))
            |> List.concat(encode_half_edge(edge))

        GetEdges({ reply_to }) ->
            List.concat([0x06], encode_u64(reply_to))

## Decode a NodeMessage from a List U8 at the given offset.
decode_node_msg : List U8, U64 -> Result { val : NodeMessage, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_node_msg = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            data_start = offset + 1
            when tag is
                0x01 ->
                    when decode_u64(buf, data_start) is
                        Ok({ val: reply_to, next }) ->
                            Ok({ val: LiteralCmd(GetProps({ reply_to })), next })

                        Err(e) -> Err(e)

                0x02 ->
                    decode_set_prop(buf, data_start)

                0x03 ->
                    decode_remove_prop(buf, data_start)

                0x04 ->
                    decode_add_edge(buf, data_start)

                0x05 ->
                    decode_remove_edge(buf, data_start)

                0x06 ->
                    when decode_u64(buf, data_start) is
                        Ok({ val: reply_to, next }) ->
                            Ok({ val: LiteralCmd(GetEdges({ reply_to })), next })

                        Err(e) -> Err(e)

                0x07 ->
                    when decode_u64(buf, data_start) is
                        Ok({ val: now, next }) ->
                            Ok({ val: SleepCheck({ now }), next })

                        Err(e) -> Err(e)

                _ -> Err(InvalidTag)

decode_set_prop : List U8, U64 -> Result { val : NodeMessage, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_set_prop = |buf, start|
    when decode_u64(buf, start) is
        Err(e) -> Err(e)
        Ok({ val: reply_to, next: key_start }) ->
            when decode_str(buf, key_start) is
                Err(OutOfBounds) -> Err(OutOfBounds)
                Err(BadUtf8) -> Err(BadUtf8)
                Ok({ val: key, next: val_start }) ->
                    when decode_property_value(buf, val_start) is
                        Ok({ val: value, next }) ->
                            Ok({ val: LiteralCmd(SetProp({ key, value, reply_to })), next })

                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8)
                        Err(InvalidTag) -> Err(InvalidTag)

decode_remove_prop : List U8, U64 -> Result { val : NodeMessage, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_remove_prop = |buf, start|
    when decode_u64(buf, start) is
        Err(e) -> Err(e)
        Ok({ val: reply_to, next: key_start }) ->
            when decode_str(buf, key_start) is
                Err(OutOfBounds) -> Err(OutOfBounds)
                Err(BadUtf8) -> Err(BadUtf8)
                Ok({ val: key, next }) ->
                    Ok({ val: LiteralCmd(RemoveProp({ key, reply_to })), next })

decode_add_edge : List U8, U64 -> Result { val : NodeMessage, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_add_edge = |buf, start|
    when decode_u64(buf, start) is
        Err(e) -> Err(e)
        Ok({ val: reply_to, next: edge_start }) ->
            when decode_half_edge(buf, edge_start) is
                Ok({ val: edge, next }) ->
                    Ok({ val: LiteralCmd(AddEdge({ edge, reply_to })), next })

                Err(OutOfBounds) -> Err(OutOfBounds)
                Err(BadUtf8) -> Err(BadUtf8)
                Err(InvalidDirection) -> Err(InvalidDirection)

decode_remove_edge : List U8, U64 -> Result { val : NodeMessage, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_remove_edge = |buf, start|
    when decode_u64(buf, start) is
        Err(e) -> Err(e)
        Ok({ val: reply_to, next: edge_start }) ->
            when decode_half_edge(buf, edge_start) is
                Ok({ val: edge, next }) ->
                    Ok({ val: LiteralCmd(RemoveEdge({ edge, reply_to })), next })

                Err(OutOfBounds) -> Err(OutOfBounds)
                Err(BadUtf8) -> Err(BadUtf8)
                Err(InvalidDirection) -> Err(InvalidDirection)

# ===== Shard Envelope =====

## Encode a shard envelope: [qid_len:U16LE] [qid_bytes...] [msg_tag:U8] [msg_fields...]
encode_shard_envelope : QuineId, NodeMessage -> List U8
encode_shard_envelope = |qid, msg|
    encode_bytes(QuineId.to_bytes(qid))
    |> List.concat(encode_node_msg(msg))

## Decode a shard envelope from the buffer at the given offset.
decode_shard_envelope : List U8, U64 -> Result { target : QuineId, msg : NodeMessage, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_shard_envelope = |buf, offset|
    when decode_bytes(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: qid_bytes, next: msg_start }) ->
            when decode_node_msg(buf, msg_start) is
                Ok({ val: msg, next }) ->
                    Ok({ target: QuineId.from_bytes(qid_bytes), msg, next })

                Err(OutOfBounds) -> Err(OutOfBounds)
                Err(BadUtf8) -> Err(BadUtf8)
                Err(InvalidTag) -> Err(InvalidTag)
                Err(InvalidDirection) -> Err(InvalidDirection)

# ===== Tests =====

# -- U16 roundtrip --
expect
    encoded = encode_u16(0)
    when decode_u16(encoded, 0) is
        Ok({ val: 0, next: 2 }) -> Bool.true
        _ -> Bool.false

expect
    encoded = encode_u16(0xABCD)
    when decode_u16(encoded, 0) is
        Ok({ val, next: 2 }) -> val == 0xABCD
        _ -> Bool.false

# -- U64 roundtrip --
expect
    encoded = encode_u64(0)
    when decode_u64(encoded, 0) is
        Ok({ val: 0, next: 8 }) -> Bool.true
        _ -> Bool.false

expect
    encoded = encode_u64(0xDEADBEEF_CAFEBABE)
    when decode_u64(encoded, 0) is
        Ok({ val, next: 8 }) -> val == 0xDEADBEEF_CAFEBABE
        _ -> Bool.false

# -- Bytes roundtrip --
expect
    encoded = encode_bytes([1, 2, 3])
    when decode_bytes(encoded, 0) is
        Ok({ val, next: 5 }) -> val == [1, 2, 3]
        _ -> Bool.false

expect
    encoded = encode_bytes([])
    when decode_bytes(encoded, 0) is
        Ok({ val, next: 2 }) -> val == []
        _ -> Bool.false

# -- Str roundtrip --
expect
    encoded = encode_str("hello")
    when decode_str(encoded, 0) is
        Ok({ val, next: 7 }) -> val == "hello"
        _ -> Bool.false

expect
    encoded = encode_str("")
    when decode_str(encoded, 0) is
        Ok({ val, next: 2 }) -> val == ""
        _ -> Bool.false

# -- Direction roundtrip --
expect
    encode_direction(Outgoing) == 0x01
    and encode_direction(Incoming) == 0x02
    and encode_direction(Undirected) == 0x03

expect
    decode_direction(0x01) == Ok(Outgoing)
    and decode_direction(0x02) == Ok(Incoming)
    and decode_direction(0x03) == Ok(Undirected)
    and decode_direction(0x00) == Err(InvalidDirection)

# -- PropertyValue roundtrips --
expect
    encoded = encode_property_value(Deserialized(Str("test")))
    when decode_property_value(encoded, 0) is
        Ok({ val: Deserialized(Str(s)) }) -> s == "test"
        _ -> Bool.false

expect
    encoded = encode_property_value(Deserialized(Integer(42)))
    when decode_property_value(encoded, 0) is
        Ok({ val: Deserialized(Integer(i)) }) -> i == 42
        _ -> Bool.false

expect
    encoded = encode_property_value(Deserialized(Integer(-1)))
    when decode_property_value(encoded, 0) is
        Ok({ val: Deserialized(Integer(i)) }) -> i == -1
        _ -> Bool.false

expect
    encoded = encode_property_value(Deserialized(True))
    when decode_property_value(encoded, 0) is
        Ok({ val: Deserialized(True) }) -> Bool.true
        _ -> Bool.false

expect
    encoded = encode_property_value(Deserialized(False))
    when decode_property_value(encoded, 0) is
        Ok({ val: Deserialized(False) }) -> Bool.true
        _ -> Bool.false

expect
    encoded = encode_property_value(Deserialized(Null))
    when decode_property_value(encoded, 0) is
        Ok({ val: Deserialized(Null) }) -> Bool.true
        _ -> Bool.false

expect
    encoded = encode_property_value(Serialized([0xAA, 0xBB]))
    when decode_property_value(encoded, 0) is
        Ok({ val: Serialized(bytes) }) -> bytes == [0xAA, 0xBB]
        _ -> Bool.false

expect
    qid = QuineId.from_bytes([0xDE, 0xAD])
    encoded = encode_property_value(Deserialized(Id(qid)))
    when decode_property_value(encoded, 0) is
        Ok({ val: Deserialized(Id(decoded_qid)) }) ->
            QuineId.to_bytes(decoded_qid) == [0xDE, 0xAD]

        _ -> Bool.false

# -- HalfEdge roundtrip --
expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([1, 2]) }
    encoded = encode_half_edge(edge)
    when decode_half_edge(encoded, 0) is
        Ok({ val: decoded }) ->
            decoded.edge_type == "KNOWS"
            and decoded.direction == Outgoing
            and QuineId.to_bytes(decoded.other) == [1, 2]

        _ -> Bool.false

# -- NodeMessage roundtrips --
expect
    msg = LiteralCmd(GetProps({ reply_to: 99 }))
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: LiteralCmd(GetProps({ reply_to: 99 })) }) -> Bool.true
        _ -> Bool.false

expect
    pv = PropertyValue.from_value(Str("hello"))
    msg = LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 7 }))
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: LiteralCmd(SetProp({ key, reply_to })) }) ->
            key == "name" and reply_to == 7

        _ -> Bool.false

expect
    msg = LiteralCmd(RemoveProp({ key: "x", reply_to: 3 }))
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: LiteralCmd(RemoveProp({ key: "x", reply_to: 3 })) }) -> Bool.true
        _ -> Bool.false

expect
    edge = { edge_type: "FOLLOWS", direction: Incoming, other: QuineId.from_bytes([5]) }
    msg = LiteralCmd(AddEdge({ edge, reply_to: 10 }))
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: LiteralCmd(AddEdge({ edge: decoded_edge, reply_to: 10 })) }) ->
            decoded_edge.edge_type == "FOLLOWS"
            and decoded_edge.direction == Incoming
            and QuineId.to_bytes(decoded_edge.other) == [5]

        _ -> Bool.false

expect
    edge = { edge_type: "PEER", direction: Undirected, other: QuineId.from_bytes([8]) }
    msg = LiteralCmd(RemoveEdge({ edge, reply_to: 20 }))
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: LiteralCmd(RemoveEdge({ edge: decoded_edge, reply_to: 20 })) }) ->
            decoded_edge.edge_type == "PEER"
            and decoded_edge.direction == Undirected
            and QuineId.to_bytes(decoded_edge.other) == [8]

        _ -> Bool.false

expect
    msg = LiteralCmd(GetEdges({ reply_to: 50 }))
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: LiteralCmd(GetEdges({ reply_to: 50 })) }) -> Bool.true
        _ -> Bool.false

expect
    msg = SleepCheck({ now: 123456789 })
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: SleepCheck({ now: 123456789 }) }) -> Bool.true
        _ -> Bool.false

# -- Shard envelope roundtrip --
expect
    qid = QuineId.from_bytes([0xAB, 0xCD])
    msg = LiteralCmd(GetProps({ reply_to: 1 }))
    encoded = encode_shard_envelope(qid, msg)
    when decode_shard_envelope(encoded, 0) is
        Ok({ target, msg: LiteralCmd(GetProps({ reply_to: 1 })) }) ->
            QuineId.to_bytes(target) == [0xAB, 0xCD]

        _ -> Bool.false

expect
    qid = QuineId.from_bytes([1])
    pv = PropertyValue.from_value(Integer(42))
    msg = LiteralCmd(SetProp({ key: "age", value: pv, reply_to: 2 }))
    encoded = encode_shard_envelope(qid, msg)
    when decode_shard_envelope(encoded, 0) is
        Ok({ target, msg: LiteralCmd(SetProp({ key: "age", reply_to: 2 })) }) ->
            QuineId.to_bytes(target) == [1]

        _ -> Bool.false

# -- Edge cases --
expect
    # Decode from empty buffer
    when decode_node_msg([], 0) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false

expect
    # Invalid tag
    when decode_node_msg([0xFF], 0) is
        Err(InvalidTag) -> Bool.true
        _ -> Bool.false

expect
    # Truncated GetProps (tag but no reply_to)
    when decode_node_msg([0x01], 0) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false
