module [
    encode_node_msg,
    decode_node_msg,
    encode_shard_envelope,
    decode_shard_envelope,
    encode_u32,
    decode_u32,
    encode_node_snapshot,
    decode_node_snapshot,
    encode_property_value,
    encode_half_edge,
]

import id.QuineId exposing [QuineId]
import id.EventTime exposing [EventTime]
import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]
import model.EdgeDirection exposing [EdgeDirection]
import model.QuineValue exposing [QuineValue]
import model.NodeSnapshot exposing [NodeSnapshot, SqStateSnapshot]
import types.Messages exposing [NodeMessage, LiteralCommand]
import standing_messages.SqMessages exposing [SqCommand]
import standing_state.SqPartState exposing [SqMsgSubscriber, SubscriptionResult]
import standing_result.StandingQueryResult exposing [QueryContext]

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

## Encode a U32 in little-endian byte order.
encode_u32 : U32 -> List U8
encode_u32 = |n|
    List.range({ start: At(0), end: Before(4) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))

## Decode a U32 from little-endian bytes at the given offset.
decode_u32 : List U8, U64 -> Result { val : U32, next : U64 } [OutOfBounds]
decode_u32 = |buf, offset|
    if offset + 4 > List.len(buf) then
        Err(OutOfBounds)
    else
        val = List.walk(
            List.range({ start: At(0u64), end: Before(4u64) }),
            0u32,
            |acc, i|
                when List.get(buf, offset + i) is
                    Ok(b) ->
                        shifted : U32
                        shifted = Num.shift_left_by(Num.int_cast(b), Num.int_cast(i) * 8)
                        Num.bitwise_or(acc, shifted)
                    Err(_) -> acc,
        )
        Ok({ val, next: offset + 4 })

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

## Encode a U128 in little-endian byte order (16 bytes).
encode_u128 : U128 -> List U8
encode_u128 = |n|
    List.range({ start: At(0), end: Before(16) })
    |> List.map(
        |i|
            Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)),
    )

## Decode a U128 from little-endian bytes at the given offset.
decode_u128 : List U8, U64 -> Result { val : U128, next : U64 } [OutOfBounds]
decode_u128 = |buf, offset|
    result = List.walk_until(
        List.range({ start: At(0u64), end: Before(16u64) }),
        Ok(0u128),
        |acc, i|
            when acc is
                Err(_) -> Break(acc)
                Ok(so_far) ->
                    when List.get(buf, offset + i) is
                        Err(_) -> Break(Err(OutOfBounds))
                        Ok(b) ->
                            shifted : U128
                            shifted = Num.shift_left_by(Num.int_cast(b), Num.int_cast(i) * 8)
                            Continue(Ok(Num.bitwise_or(so_far, shifted))),
    )
    when result is
        Ok(val) -> Ok({ val, next: offset + 16 })
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

# ===== QuineValue Decoding (standalone) =====

## Decode a QuineValue from the buffer at the given offset.
decode_quine_value_standalone : List U8, U64 -> Result { val : QuineValue, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_quine_value_standalone = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            data_start = offset + 1
            when tag is
                0x01 ->
                    when decode_str(buf, data_start) is
                        Ok({ val: s, next }) -> Ok({ val: Str(s), next })
                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8)

                0x02 ->
                    when decode_u64(buf, data_start) is
                        Ok({ val: bits, next }) ->
                            i : I64
                            i = Num.int_cast(bits)
                            Ok({ val: Integer(i), next })

                        Err(e) -> Err(e)

                0x04 -> Ok({ val: True, next: data_start })
                0x05 -> Ok({ val: False, next: data_start })
                0x06 -> Ok({ val: Null, next: data_start })
                0x07 ->
                    when decode_bytes(buf, data_start) is
                        Ok({ val: bytes, next }) -> Ok({ val: Bytes(bytes), next })
                        Err(e) -> Err(e)

                0x08 ->
                    when decode_bytes(buf, data_start) is
                        Ok({ val: bytes, next }) ->
                            Ok({ val: Id(QuineId.from_bytes(bytes)), next })

                        Err(e) -> Err(e)

                _ -> Err(InvalidTag)

# ===== QueryContext Encoding =====

## Encode a QueryContext (Dict Str QuineValue): [count:U16] [key:str value:qv]...
encode_query_context : QueryContext -> List U8
encode_query_context = |ctx|
    entries = Dict.to_list(ctx)
    count : U16
    count = Num.int_cast(List.len(entries))
    List.walk(
        entries,
        encode_u16(count),
        |acc, (k, v)|
            acc
            |> List.concat(encode_str(k))
            |> List.concat(encode_quine_value(v)),
    )

## Decode a QueryContext from the buffer at the given offset.
decode_query_context : List U8, U64 -> Result { val : QueryContext, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_query_context = |buf, offset|
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: count_u16, next: entries_start }) ->
            count = Num.int_cast(count_u16)
            decode_context_entries(buf, entries_start, count, Dict.empty({}))

decode_context_entries : List U8, U64, U64, QueryContext -> Result { val : QueryContext, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_context_entries = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_str(buf, offset) is
            Err(OutOfBounds) -> Err(OutOfBounds)
            Err(BadUtf8) -> Err(BadUtf8)
            Ok({ val: key, next: val_offset }) ->
                when decode_quine_value_standalone(buf, val_offset) is
                    Err(e) -> Err(e)
                    Ok({ val: qv, next: next_offset }) ->
                        new_acc = Dict.insert(acc, key, qv)
                        decode_context_entries(buf, next_offset, remaining - 1, new_acc)

# ===== SqMsgSubscriber Encoding =====

## Encode an SqMsgSubscriber.
## NodeSubscriber: [0x00] [subscribing_node_bytes] [global_id:U128] [query_part_id:U64]
## GlobalSubscriber: [0x01] [global_id:U128]
encode_sq_subscriber : SqMsgSubscriber -> List U8
encode_sq_subscriber = |sub|
    when sub is
        NodeSubscriber({ subscribing_node, global_id, query_part_id }) ->
            [0x00]
            |> List.concat(encode_bytes(QuineId.to_bytes(subscribing_node)))
            |> List.concat(encode_u128(global_id))
            |> List.concat(encode_u64(query_part_id))

        GlobalSubscriber({ global_id }) ->
            [0x01]
            |> List.concat(encode_u128(global_id))

## Decode an SqMsgSubscriber from the buffer at the given offset.
decode_sq_subscriber : List U8, U64 -> Result { val : SqMsgSubscriber, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_sq_subscriber = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            data_start = offset + 1
            when tag is
                0x00 ->
                    when decode_bytes(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: node_bytes, next: gid_start }) ->
                            when decode_u128(buf, gid_start) is
                                Err(e) -> Err(e)
                                Ok({ val: global_id, next: pid_start }) ->
                                    when decode_u64(buf, pid_start) is
                                        Err(e) -> Err(e)
                                        Ok({ val: query_part_id, next }) ->
                                            Ok({
                                                val: NodeSubscriber({
                                                    subscribing_node: QuineId.from_bytes(node_bytes),
                                                    global_id,
                                                    query_part_id,
                                                }),
                                                next,
                                            })

                0x01 ->
                    when decode_u128(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: global_id, next }) ->
                            Ok({ val: GlobalSubscriber({ global_id }), next })

                _ -> Err(InvalidTag)

# ===== SubscriptionResult Encoding =====

## Encode a SubscriptionResult.
## [from_qid_bytes] [query_part_id:U64] [global_id:U128] [for_query_part_id:U64]
## [result_count:U16] [contexts...]
encode_subscription_result : SubscriptionResult -> List U8
encode_subscription_result = |sr|
    result_count : U16
    result_count = Num.int_cast(List.len(sr.result_group))
    encode_bytes(QuineId.to_bytes(sr.from))
    |> List.concat(encode_u64(sr.query_part_id))
    |> List.concat(encode_u128(sr.global_id))
    |> List.concat(encode_u64(sr.for_query_part_id))
    |> List.concat(encode_u16(result_count))
    |> |acc| List.walk(sr.result_group, acc, |a, ctx| List.concat(a, encode_query_context(ctx)))

## Decode a SubscriptionResult from the buffer at the given offset.
decode_subscription_result : List U8, U64 -> Result { val : SubscriptionResult, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_subscription_result = |buf, offset|
    when decode_bytes(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: from_bytes, next: qpid_start }) ->
            when decode_u64(buf, qpid_start) is
                Err(e) -> Err(e)
                Ok({ val: query_part_id, next: gid_start }) ->
                    when decode_u128(buf, gid_start) is
                        Err(e) -> Err(e)
                        Ok({ val: global_id, next: fqpid_start }) ->
                            when decode_u64(buf, fqpid_start) is
                                Err(e) -> Err(e)
                                Ok({ val: for_query_part_id, next: count_start }) ->
                                    when decode_u16(buf, count_start) is
                                        Err(e) -> Err(e)
                                        Ok({ val: count_u16, next: contexts_start }) ->
                                            count = Num.int_cast(count_u16)
                                            when decode_contexts(buf, contexts_start, count, []) is
                                                Err(e) -> Err(e)
                                                Ok({ val: result_group, next }) ->
                                                    Ok({
                                                        val: {
                                                            from: QuineId.from_bytes(from_bytes),
                                                            query_part_id,
                                                            global_id,
                                                            for_query_part_id,
                                                            result_group,
                                                        },
                                                        next,
                                                    })

decode_contexts : List U8, U64, U64, List QueryContext -> Result { val : List QueryContext, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_contexts = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_query_context(buf, offset) is
            Err(e) -> Err(e)
            Ok({ val: ctx, next }) ->
                decode_contexts(buf, next, remaining - 1, List.append(acc, ctx))

# ===== SqCommand Encoding =====

## Tag bytes for SQ commands (0x10-0x13, no collision with existing 0x01-0x07).
## 0x10 = CreateSqSubscription
## 0x11 = CancelSqSubscription
## 0x12 = NewSqResult
## 0x13 = UpdateStandingQueries

## Encode an SqCommand to a List U8.
encode_sq_command : SqCommand -> List U8
encode_sq_command = |cmd|
    when cmd is
        CreateSqSubscription({ subscriber, global_id }) ->
            # query_part_id is NOT encoded (query AST not serialized).
            # On decode, UnitSq is used as placeholder; actual query looked
            # up from shard part_index at dispatch time (Phase 4d concern).
            [0x10]
            |> List.concat(encode_u128(global_id))
            |> List.concat(encode_sq_subscriber(subscriber))

        CancelSqSubscription({ subscriber, query_part_id, global_id }) ->
            [0x11]
            |> List.concat(encode_u128(global_id))
            |> List.concat(encode_u64(query_part_id))
            |> List.concat(encode_sq_subscriber(subscriber))

        NewSqResult(sr) ->
            [0x12]
            |> List.concat(encode_subscription_result(sr))

        UpdateStandingQueries ->
            [0x13]

## Decode an SqCommand from the buffer at the given offset.
decode_sq_command : List U8, U64 -> Result { val : SqCommand, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_sq_command = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            data_start = offset + 1
            when tag is
                0x10 ->
                    # CreateSqSubscription: decode global_id + subscriber.
                    # query is placeholder UnitSq (looked up at dispatch time).
                    when decode_u128(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: global_id, next: sub_start }) ->
                            when decode_sq_subscriber(buf, sub_start) is
                                Err(e) -> Err(e)
                                Ok({ val: subscriber, next }) ->
                                    Ok({
                                        val: CreateSqSubscription({
                                            subscriber,
                                            query: UnitSq,
                                            global_id,
                                        }),
                                        next,
                                    })

                0x11 ->
                    when decode_u128(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: global_id, next: pid_start }) ->
                            when decode_u64(buf, pid_start) is
                                Err(e) -> Err(e)
                                Ok({ val: query_part_id, next: sub_start }) ->
                                    when decode_sq_subscriber(buf, sub_start) is
                                        Err(e) -> Err(e)
                                        Ok({ val: subscriber, next }) ->
                                            Ok({
                                                val: CancelSqSubscription({
                                                    subscriber,
                                                    query_part_id,
                                                    global_id,
                                                }),
                                                next,
                                            })

                0x12 ->
                    when decode_subscription_result(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: sr, next }) ->
                            Ok({ val: NewSqResult(sr), next })

                0x13 ->
                    Ok({ val: UpdateStandingQueries, next: data_start })

                _ -> Err(InvalidTag)

# ===== NodeMessage Encoding =====

## Encode a NodeMessage to a List U8.
encode_node_msg : NodeMessage -> List U8
encode_node_msg = |msg|
    when msg is
        LiteralCmd(cmd) -> encode_literal_cmd(cmd)
        SleepCheck({ now }) ->
            List.concat([0x07], encode_u64(now))
        SqCmd(sq_cmd) -> encode_sq_command(sq_cmd)

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

                0x10 | 0x11 | 0x12 | 0x13 ->
                    when decode_sq_command(buf, offset) is
                        Err(e) -> Err(e)
                        Ok({ val: sq_cmd, next }) ->
                            Ok({ val: SqCmd(sq_cmd), next })

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

# ===== NodeSnapshot Encoding =====

## Encode a NodeSnapshot to bytes.
## Format: [props...][edges...][time...][sq_snapshot...]
encode_node_snapshot : NodeSnapshot -> List U8
encode_node_snapshot = |snap|
    # Properties: [count:U32LE] then [key:str value:PropertyValue]...
    props_list = Dict.to_list(snap.properties)
    prop_count : U32
    prop_count = Num.int_cast(List.len(props_list))
    props_bytes = List.walk(props_list, encode_u32(prop_count), |acc, (key, val)|
        acc
        |> List.concat(encode_str(key))
        |> List.concat(encode_property_value(val)))

    # Edges: [count:U32LE] then [half_edge_bytes]...
    edge_count : U32
    edge_count = Num.int_cast(List.len(snap.edges))
    edges_bytes = List.walk(snap.edges, encode_u32(edge_count), |acc, edge|
        List.concat(acc, encode_half_edge(edge)))

    # Time: [tag:U8][value:U64LE] — 0x01=AtTime always for snapshots
    time_raw = EventTime.to_u64(snap.time)
    time_bytes = [0x01] |> List.concat(encode_u64(time_raw))

    # SQ snapshot: [count:U32LE] then [global_id:U128][part_id:U64][state_len:U32][state_bytes]...
    sq_count : U32
    sq_count = Num.int_cast(List.len(snap.sq_snapshot))
    sq_bytes = List.walk(snap.sq_snapshot, encode_u32(sq_count), |acc, entry|
        state_len : U32
        state_len = Num.int_cast(List.len(entry.state_bytes))
        acc
        |> List.concat(encode_u128(entry.global_id))
        |> List.concat(encode_u64(entry.part_id))
        |> List.concat(encode_u32(state_len))
        |> List.concat(entry.state_bytes))

    props_bytes
    |> List.concat(edges_bytes)
    |> List.concat(time_bytes)
    |> List.concat(sq_bytes)

## Decode a NodeSnapshot from the buffer at the given offset.
decode_node_snapshot : List U8, U64 -> Result { snapshot : NodeSnapshot, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_node_snapshot = |buf, offset|
    when decode_u32(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok({ val: prop_count_u32, next: props_start }) ->
            prop_count = Num.int_cast(prop_count_u32)
            when decode_properties(buf, props_start, prop_count, Dict.empty({})) is
                Err(e) -> Err(e)
                Ok({ val: properties, next: edges_count_start }) ->
                    when decode_u32(buf, edges_count_start) is
                        Err(_) -> Err(OutOfBounds)
                        Ok({ val: edge_count_u32, next: edges_start }) ->
                            edge_count = Num.int_cast(edge_count_u32)
                            when decode_edges(buf, edges_start, edge_count, []) is
                                Err(e) -> Err(e)
                                Ok({ val: edges, next: time_start }) ->
                                    when decode_event_time(buf, time_start) is
                                        Err(e) -> Err(e)
                                        Ok({ val: time, next: sq_count_start }) ->
                                            when decode_u32(buf, sq_count_start) is
                                                Err(_) -> Err(OutOfBounds)
                                                Ok({ val: sq_count_u32, next: sq_start }) ->
                                                    sq_count = Num.int_cast(sq_count_u32)
                                                    when decode_sq_snapshots(buf, sq_start, sq_count, []) is
                                                        Err(e) -> Err(e)
                                                        Ok({ val: sq_snapshot, next: final_next }) ->
                                                            Ok({
                                                                snapshot: { properties, edges, time, sq_snapshot },
                                                                next: final_next,
                                                            })

## Decode N properties from the buffer.
decode_properties : List U8, U64, U64, Dict Str PropertyValue -> Result { val : Dict Str PropertyValue, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_properties = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_str(buf, offset) is
            Err(OutOfBounds) -> Err(OutOfBounds)
            Err(BadUtf8) -> Err(BadUtf8)
            Ok({ val: key, next: val_start }) ->
                when decode_property_value(buf, val_start) is
                    Err(e) -> Err(e)
                    Ok({ val: pv, next: next_offset }) ->
                        decode_properties(buf, next_offset, remaining - 1, Dict.insert(acc, key, pv))

## Decode N HalfEdges from the buffer.
decode_edges : List U8, U64, U64, List HalfEdge -> Result { val : List HalfEdge, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_edges = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_half_edge(buf, offset) is
            Err(OutOfBounds) -> Err(OutOfBounds)
            Err(BadUtf8) -> Err(BadUtf8)
            Err(InvalidDirection) -> Err(InvalidDirection)
            Ok({ val: edge, next: next_offset }) ->
                decode_edges(buf, next_offset, remaining - 1, List.append(acc, edge))

## Decode an EventTime from the buffer (tag + optional U64).
decode_event_time : List U8, U64 -> Result { val : EventTime, next : U64 } [OutOfBounds, InvalidTag, BadUtf8, InvalidDirection]
decode_event_time = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            if tag == 0x00 then
                Ok({ val: EventTime.min_value, next: offset + 1 })
            else if tag == 0x01 then
                when decode_u64(buf, offset + 1) is
                    Ok({ val: raw, next }) -> Ok({ val: EventTime.from_u64(raw), next })
                    Err(e) -> Err(e)
            else
                Err(InvalidTag)

## Decode N SqStateSnapshot entries from the buffer.
decode_sq_snapshots : List U8, U64, U64, List SqStateSnapshot -> Result { val : List SqStateSnapshot, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_sq_snapshots = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_u128(buf, offset) is
            Err(e) -> Err(e)
            Ok({ val: global_id, next: pid_start }) ->
                when decode_u64(buf, pid_start) is
                    Err(e) -> Err(e)
                    Ok({ val: part_id, next: slen_start }) ->
                        when decode_u32(buf, slen_start) is
                            Err(_) -> Err(OutOfBounds)
                            Ok({ val: state_len_u32, next: state_start }) ->
                                state_len = Num.int_cast(state_len_u32)
                                state_bytes = List.sublist(buf, { start: state_start, len: state_len })
                                if List.len(state_bytes) == state_len then
                                    entry : SqStateSnapshot
                                    entry = { global_id, part_id, state_bytes }
                                    decode_sq_snapshots(buf, state_start + state_len, remaining - 1, List.append(acc, entry))
                                else
                                    Err(OutOfBounds)

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

# ===== U128 Tests =====

# -- U128 roundtrip: zero --
expect
    encoded = encode_u128(0u128)
    when decode_u128(encoded, 0) is
        Ok({ val: 0u128, next: 16 }) -> Bool.true
        _ -> Bool.false

# -- U128 roundtrip: large value --
expect
    encoded = encode_u128(0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0)
    when decode_u128(encoded, 0) is
        Ok({ val, next: 16 }) -> val == 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0
        _ -> Bool.false

# -- U128 truncated --
expect
    when decode_u128([0x01, 0x02], 0) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false

# ===== QueryContext Tests =====

# -- QueryContext roundtrip: empty --
expect
    ctx : QueryContext
    ctx = Dict.empty({})
    encoded = encode_query_context(ctx)
    when decode_query_context(encoded, 0) is
        Ok({ val }) -> Dict.len(val) == 0
        _ -> Bool.false

# -- QueryContext roundtrip: single entry --
expect
    ctx : QueryContext
    ctx = Dict.insert(Dict.empty({}), "x", Integer(42))
    encoded = encode_query_context(ctx)
    when decode_query_context(encoded, 0) is
        Ok({ val }) ->
            when Dict.get(val, "x") is
                Ok(Integer(42)) -> Bool.true
                _ -> Bool.false

        _ -> Bool.false

# ===== SqMsgSubscriber Tests =====

# -- GlobalSubscriber roundtrip --
expect
    sub : SqMsgSubscriber
    sub = GlobalSubscriber({ global_id: 0xABCDEF01_23456789_ABCDEF01_23456789 })
    encoded = encode_sq_subscriber(sub)
    when decode_sq_subscriber(encoded, 0) is
        Ok({ val: GlobalSubscriber({ global_id }) }) ->
            global_id == 0xABCDEF01_23456789_ABCDEF01_23456789

        _ -> Bool.false

# -- NodeSubscriber roundtrip --
expect
    sub : SqMsgSubscriber
    sub = NodeSubscriber({
        subscribing_node: QuineId.from_bytes([0x01, 0x02]),
        global_id: 99u128,
        query_part_id: 42u64,
    })
    encoded = encode_sq_subscriber(sub)
    when decode_sq_subscriber(encoded, 0) is
        Ok({ val: NodeSubscriber({ global_id, query_part_id }) }) ->
            global_id == 99u128 and query_part_id == 42u64

        _ -> Bool.false

# ===== SqCommand Tests =====

# -- UpdateStandingQueries roundtrip --
expect
    msg = SqCmd(UpdateStandingQueries)
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: SqCmd(UpdateStandingQueries) }) -> Bool.true
        _ -> Bool.false

# -- CancelSqSubscription roundtrip --
expect
    sub : SqMsgSubscriber
    sub = GlobalSubscriber({ global_id: 7u128 })
    cmd : SqCommand
    cmd = CancelSqSubscription({
        subscriber: sub,
        query_part_id: 123u64,
        global_id: 7u128,
    })
    msg = SqCmd(cmd)
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: SqCmd(CancelSqSubscription({ query_part_id, global_id })) }) ->
            query_part_id == 123u64 and global_id == 7u128

        _ -> Bool.false

# -- CreateSqSubscription roundtrip (query decoded as UnitSq placeholder) --
expect
    sub : SqMsgSubscriber
    sub = GlobalSubscriber({ global_id: 5u128 })
    cmd : SqCommand
    cmd = CreateSqSubscription({
        subscriber: sub,
        query: UnitSq,
        global_id: 5u128,
    })
    msg = SqCmd(cmd)
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: SqCmd(CreateSqSubscription({ global_id, query: UnitSq })) }) ->
            global_id == 5u128

        _ -> Bool.false

# -- NewSqResult roundtrip with empty result group --
expect
    sr : SubscriptionResult
    sr = {
        from: QuineId.from_bytes([0xAA]),
        query_part_id: 10u64,
        global_id: 200u128,
        for_query_part_id: 20u64,
        result_group: [],
    }
    msg = SqCmd(NewSqResult(sr))
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: SqCmd(NewSqResult(decoded_sr)) }) ->
            decoded_sr.query_part_id == 10u64
            and decoded_sr.global_id == 200u128
            and decoded_sr.for_query_part_id == 20u64
            and List.len(decoded_sr.result_group) == 0

        _ -> Bool.false

# -- NewSqResult roundtrip with one non-empty context --
expect
    ctx : QueryContext
    ctx = Dict.insert(Dict.empty({}), "name", Str("Alice"))
    sr : SubscriptionResult
    sr = {
        from: QuineId.from_bytes([0x01]),
        query_part_id: 1u64,
        global_id: 1u128,
        for_query_part_id: 2u64,
        result_group: [ctx],
    }
    msg = SqCmd(NewSqResult(sr))
    encoded = encode_node_msg(msg)
    when decode_node_msg(encoded, 0) is
        Ok({ val: SqCmd(NewSqResult(decoded_sr)) }) ->
            List.len(decoded_sr.result_group) == 1

        _ -> Bool.false

# -- U32 roundtrip --
expect
    encoded = encode_u32(0)
    when decode_u32(encoded, 0) is
        Ok({ val: 0, next: 4 }) -> Bool.true
        _ -> Bool.false

expect
    encoded = encode_u32(0xDEADBEEF)
    when decode_u32(encoded, 0) is
        Ok({ val, next: 4 }) -> val == 0xDEADBEEF
        _ -> Bool.false

expect
    when decode_u32([0x01], 0) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false

# ===== NodeSnapshot Tests =====

# -- Empty snapshot roundtrip --
expect
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}),
        edges: [],
        time: EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 }),
        sq_snapshot: [],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            Dict.is_empty(snapshot.properties)
            and List.is_empty(snapshot.edges)
            and snapshot.time == EventTime.from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
            and List.is_empty(snapshot.sq_snapshot)
        _ -> Bool.false

# -- Snapshot with properties --
expect
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}) |> Dict.insert("name", Deserialized(Str("Alice"))) |> Dict.insert("age", Deserialized(Integer(30))),
        edges: [],
        time: EventTime.from_parts({ millis: 2000, message_seq: 1, event_seq: 0 }),
        sq_snapshot: [],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            Dict.len(snapshot.properties) == 2
        _ -> Bool.false

# -- Snapshot with edges --
expect
    edge1 = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x01]) }
    edge2 = { edge_type: "FOLLOWS", direction: Incoming, other: QuineId.from_bytes([0x02]) }
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}),
        edges: [edge1, edge2],
        time: EventTime.from_parts({ millis: 3000, message_seq: 0, event_seq: 0 }),
        sq_snapshot: [],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            List.len(snapshot.edges) == 2
        _ -> Bool.false

# -- Snapshot with SQ state entries --
expect
    sq_entry : SqStateSnapshot
    sq_entry = { global_id: 42u128, part_id: 7u64, state_bytes: [0x20] }
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}),
        edges: [],
        time: EventTime.from_parts({ millis: 4000, message_seq: 0, event_seq: 0 }),
        sq_snapshot: [sq_entry],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            List.len(snapshot.sq_snapshot) == 1
            and (
                when List.get(snapshot.sq_snapshot, 0) is
                    Ok(entry) -> entry.global_id == 42u128 and entry.part_id == 7u64 and entry.state_bytes == [0x20]
                    _ -> Bool.false
            )
        _ -> Bool.false

# -- Full snapshot roundtrip --
expect
    edge = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0xAB]) }
    sq_entry : SqStateSnapshot
    sq_entry = { global_id: 100u128, part_id: 50u64, state_bytes: [0x22, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] }
    snap : NodeSnapshot
    snap = {
        properties: Dict.empty({}) |> Dict.insert("x", Deserialized(Integer(99))),
        edges: [edge],
        time: EventTime.from_parts({ millis: 5000, message_seq: 2, event_seq: 1 }),
        sq_snapshot: [sq_entry],
    }
    encoded = encode_node_snapshot(snap)
    when decode_node_snapshot(encoded, 0) is
        Ok({ snapshot }) ->
            Dict.len(snapshot.properties) == 1
            and List.len(snapshot.edges) == 1
            and snapshot.time == EventTime.from_parts({ millis: 5000, message_seq: 2, event_seq: 1 })
            and List.len(snapshot.sq_snapshot) == 1
        _ -> Bool.false
