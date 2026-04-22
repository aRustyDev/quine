module [
    encode_expr,
    decode_expr,
    encode_comp_op,
    decode_comp_op,
    encode_bool_logic,
    decode_bool_logic,
    encode_quine_value,
    decode_quine_value,
]

import expr.Expr exposing [Expr, CompOp, BoolLogic]
import model.QuineValue exposing [QuineValue]

# ===== Primitive Encoders =====
# Duplicated from graph/codec/Codec.roc since this is a separate package.

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

# ===== CompOp Codec =====

## Encode a CompOp as a single byte.
encode_comp_op : CompOp -> U8
encode_comp_op = |op|
    when op is
        Eq -> 0x00
        Neq -> 0x01
        Lt -> 0x02
        Gt -> 0x03
        Lte -> 0x04
        Gte -> 0x05

## Decode a CompOp from a single byte.
decode_comp_op : U8 -> Result CompOp [InvalidTag]
decode_comp_op = |b|
    when b is
        0x00 -> Ok(Eq)
        0x01 -> Ok(Neq)
        0x02 -> Ok(Lt)
        0x03 -> Ok(Gt)
        0x04 -> Ok(Lte)
        0x05 -> Ok(Gte)
        _ -> Err(InvalidTag)

# ===== BoolLogic Codec =====

## Encode a BoolLogic as a single byte.
encode_bool_logic : BoolLogic -> U8
encode_bool_logic = |op|
    when op is
        And -> 0x00
        Or -> 0x01

## Decode a BoolLogic from a single byte.
decode_bool_logic : U8 -> Result BoolLogic [InvalidTag]
decode_bool_logic = |b|
    when b is
        0x00 -> Ok(And)
        0x01 -> Ok(Or)
        _ -> Err(InvalidTag)

# ===== QuineValue Codec =====
# Tags: 0x01=Str, 0x02=Integer, 0x03=Floating, 0x04=True, 0x05=False,
#        0x06=Null, 0x07=Bytes
# List/Map/Id/Floating encoded as Null (deferred).

## Encode a QuineValue with a leading tag byte.
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

        Id(_) ->
            # Id encoding deferred in cypher codec; encode as Null
            [0x06]

## Decode a QuineValue from the buffer at the given offset.
decode_quine_value : List U8, U64 -> Result { val : QuineValue, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_quine_value = |buf, offset|
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

                _ -> Err(InvalidTag)

# ===== Expr Codec =====
#
# Tag bytes for Expr variants (0x40 range):
#   0x40 = Literal
#   0x41 = Variable
#   0x42 = Property
#   0x43 = Comparison
#   0x44 = BoolOp
#   0x45 = Not
#   0x46 = IsNull
#   0x47 = InList
#   0x48 = FnCall

## Encode an Expr tree to a byte list.
encode_expr : Expr -> List U8
encode_expr = |expr|
    when expr is
        Literal(qv) ->
            List.concat([0x40], encode_quine_value(qv))

        Variable(name) ->
            List.concat([0x41], encode_str(name))

        Property({ expr: inner, key }) ->
            [0x42]
            |> List.concat(encode_expr(inner))
            |> List.concat(encode_str(key))

        Comparison({ left, op, right }) ->
            [0x43]
            |> List.concat(encode_expr(left))
            |> List.append(encode_comp_op(op))
            |> List.concat(encode_expr(right))

        BoolOp({ left, op, right }) ->
            [0x44]
            |> List.concat(encode_expr(left))
            |> List.append(encode_bool_logic(op))
            |> List.concat(encode_expr(right))

        Not(inner) ->
            List.concat([0x45], encode_expr(inner))

        IsNull(inner) ->
            List.concat([0x46], encode_expr(inner))

        InList({ elem, list }) ->
            [0x47]
            |> List.concat(encode_expr(elem))
            |> List.concat(encode_expr(list))

        FnCall({ name, args }) ->
            arg_count : U16
            arg_count = Num.int_cast(List.len(args))
            List.walk(
                args,
                [0x48]
                |> List.concat(encode_str(name))
                |> List.concat(encode_u16(arg_count)),
                |acc, arg|
                    List.concat(acc, encode_expr(arg)),
            )

## Decode an Expr tree from the buffer at the given offset.
decode_expr : List U8, U64 -> Result { val : Expr, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_expr = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            data_start = offset + 1
            when tag is
                0x40 ->
                    # Literal
                    when decode_quine_value(buf, data_start) is
                        Ok({ val: qv, next }) -> Ok({ val: Literal(qv), next })
                        Err(e) -> Err(e)

                0x41 ->
                    # Variable
                    when decode_str(buf, data_start) is
                        Ok({ val: name, next }) -> Ok({ val: Variable(name), next })
                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8)

                0x42 ->
                    # Property { expr, key }
                    when decode_expr(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: inner, next: key_start }) ->
                            when decode_str(buf, key_start) is
                                Ok({ val: key, next }) ->
                                    Ok({ val: Property({ expr: inner, key }), next })
                                Err(OutOfBounds) -> Err(OutOfBounds)
                                Err(BadUtf8) -> Err(BadUtf8)

                0x43 ->
                    # Comparison { left, op, right }
                    when decode_expr(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: left, next: op_start }) ->
                            when List.get(buf, op_start) is
                                Err(_) -> Err(OutOfBounds)
                                Ok(op_byte) ->
                                    when decode_comp_op(op_byte) is
                                        Err(e) -> Err(e)
                                        Ok(op) ->
                                            when decode_expr(buf, op_start + 1) is
                                                Err(e) -> Err(e)
                                                Ok({ val: right, next }) ->
                                                    Ok({ val: Comparison({ left, op, right }), next })

                0x44 ->
                    # BoolOp { left, op, right }
                    when decode_expr(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: left, next: op_start }) ->
                            when List.get(buf, op_start) is
                                Err(_) -> Err(OutOfBounds)
                                Ok(op_byte) ->
                                    when decode_bool_logic(op_byte) is
                                        Err(e) -> Err(e)
                                        Ok(op) ->
                                            when decode_expr(buf, op_start + 1) is
                                                Err(e) -> Err(e)
                                                Ok({ val: right, next }) ->
                                                    Ok({ val: BoolOp({ left, op, right }), next })

                0x45 ->
                    # Not
                    when decode_expr(buf, data_start) is
                        Ok({ val: inner, next }) -> Ok({ val: Not(inner), next })
                        Err(e) -> Err(e)

                0x46 ->
                    # IsNull
                    when decode_expr(buf, data_start) is
                        Ok({ val: inner, next }) -> Ok({ val: IsNull(inner), next })
                        Err(e) -> Err(e)

                0x47 ->
                    # InList { elem, list }
                    when decode_expr(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: elem, next: list_start }) ->
                            when decode_expr(buf, list_start) is
                                Err(e) -> Err(e)
                                Ok({ val: list, next }) ->
                                    Ok({ val: InList({ elem, list }), next })

                0x48 ->
                    # FnCall { name, args }
                    when decode_str(buf, data_start) is
                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8)
                        Ok({ val: name, next: count_start }) ->
                            when decode_u16(buf, count_start) is
                                Err(e) -> Err(e)
                                Ok({ val: count_u16, next: args_start }) ->
                                    count = Num.int_cast(count_u16)
                                    when decode_expr_list(buf, args_start, count, []) is
                                        Err(e) -> Err(e)
                                        Ok({ val: args, next }) ->
                                            Ok({ val: FnCall({ name, args }), next })

                _ -> Err(InvalidTag)

## Decode a list of N Expr values from the buffer.
decode_expr_list : List U8, U64, U64, List Expr -> Result { val : List Expr, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_expr_list = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_expr(buf, offset) is
            Err(e) -> Err(e)
            Ok({ val: expr, next }) ->
                decode_expr_list(buf, next, remaining - 1, List.append(acc, expr))

# ===== Tests =====

# Test 1: Literal Str round-trips
expect
    expr = Literal(Str("hello"))
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Literal(Str("hello")), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test 2: Literal Integer round-trips
expect
    expr = Literal(Integer(42))
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Literal(Integer(42)), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test 3: Literal True round-trips
expect
    expr = Literal(True)
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Literal(True), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test 4: Literal Null round-trips
expect
    expr = Literal(Null)
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Literal(Null), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test 5: Variable round-trips
expect
    expr = Variable("n")
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Variable("n"), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test 6: Property round-trips
expect
    expr = Property({ expr: Variable("n"), key: "name" })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Property({ expr: Variable("n"), key: "name" }), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test 7: Comparison round-trips
expect
    expr = Comparison({ left: Literal(Integer(1)), op: Lt, right: Literal(Integer(2)) })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Comparison({ left: Literal(Integer(1)), op: Lt, right: Literal(Integer(2)) }), next }) ->
            next == List.len(bytes)
        _ -> Bool.false

# Test 8: BoolOp round-trips
expect
    expr = BoolOp({ left: Literal(True), op: And, right: Literal(False) })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: BoolOp({ left: Literal(True), op: And, right: Literal(False) }), next }) ->
            next == List.len(bytes)
        _ -> Bool.false

# Test 9: Not round-trips
expect
    expr = Not(Literal(True))
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Not(Literal(True)), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test 10: IsNull round-trips
expect
    expr = IsNull(Variable("x"))
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: IsNull(Variable("x")), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test 11: Nested expr: n.age > 25 AND n.active = true round-trips
expect
    # Represents: n.age > 25 AND n.active = true
    age_check = Comparison({
        left: Property({ expr: Variable("n"), key: "age" }),
        op: Gt,
        right: Literal(Integer(25)),
    })
    active_check = Comparison({
        left: Property({ expr: Variable("n"), key: "active" }),
        op: Eq,
        right: Literal(True),
    })
    expr = BoolOp({ left: age_check, op: And, right: active_check })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: BoolOp({ left: Comparison({ left: Property({ expr: Variable("n"), key: "age" }), op: Gt, right: Literal(Integer(25)) }), op: And, right: Comparison({ left: Property({ expr: Variable("n"), key: "active" }), op: Eq, right: Literal(True) }) }), next }) ->
            next == List.len(bytes)
        _ -> Bool.false

# Test 12: FnCall with no args round-trips
expect
    expr = FnCall({ name: "id", args: [] })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: FnCall({ name: "id", args }), next }) ->
            List.is_empty(args) and next == List.len(bytes)
        _ -> Bool.false

# Test 13: Empty buffer -> OutOfBounds
expect
    when decode_expr([], 0) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false

# Test 14: Unknown tag -> InvalidTag
expect
    when decode_expr([0xFF], 0) is
        Err(InvalidTag) -> Bool.true
        _ -> Bool.false

# Test 15: CompOp all variants round-trip
expect
    ops = [Eq, Neq, Lt, Gt, Lte, Gte]
    List.all(ops, |op|
        encoded = encode_comp_op(op)
        when decode_comp_op(encoded) is
            Ok(decoded) ->
                encode_comp_op(decoded) == encoded
            Err(_) -> Bool.false)

# Test 16: BoolLogic all variants round-trip
expect
    ops = [And, Or]
    List.all(ops, |op|
        encoded = encode_bool_logic(op)
        when decode_bool_logic(encoded) is
            Ok(decoded) ->
                encode_bool_logic(decoded) == encoded
            Err(_) -> Bool.false)
