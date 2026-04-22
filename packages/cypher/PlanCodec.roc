module [
    encode_plan,
    decode_plan,
]

import Planner exposing [QueryPlan, PlanStep, ProjectItem]
import ExprCodec exposing [encode_expr, decode_expr, encode_quine_value, decode_quine_value]
import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import expr.Expr exposing [Expr]

# ===== Primitive Encoders =====
# Duplicated from ExprCodec since they are module-private there.

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
    result = List.walk_until(
        List.range({ start: At(0u64), end: Before(4u64) }),
        Ok(0u32),
        |acc, i|
            when acc is
                Err(_) -> Break(acc)
                Ok(so_far) ->
                    when List.get(buf, offset + i) is
                        Err(_) -> Break(Err(OutOfBounds))
                        Ok(b) ->
                            shifted : U32
                            shifted = Num.shift_left_by(Num.int_cast(b), Num.int_cast(i) * 8)
                            Continue(Ok(Num.bitwise_or(so_far, shifted))),
    )
    when result is
        Ok(val) -> Ok({ val, next: offset + 4 })
        Err(e) -> Err(e)

## Encode a UTF-8 string with a U16LE length prefix.
encode_str : Str -> List U8
encode_str = |s|
    bytes = Str.to_utf8(s)
    len : U16
    len = Num.int_cast(List.len(bytes))
    encode_u16(len) |> List.concat(bytes)

## Decode a length-prefixed UTF-8 string at the given offset.
decode_str : List U8, U64 -> Result { val : Str, next : U64 } [OutOfBounds, BadUtf8]
decode_str = |buf, offset|
    when decode_u16(buf, offset) is
        Err(OutOfBounds) -> Err(OutOfBounds)
        Ok({ val: len_u16, next: data_start }) ->
            len = Num.int_cast(len_u16)
            extracted = List.sublist(buf, { start: data_start, len })
            if List.len(extracted) == len then
                when Str.from_utf8(extracted) is
                    Ok(s) -> Ok({ val: s, next: data_start + len })
                    Err(_) -> Err(BadUtf8)
            else
                Err(OutOfBounds)

# ===== Step Tags =====

scan_seeds_tag : U8
scan_seeds_tag = 0x30

traverse_tag : U8
traverse_tag = 0x31

filter_tag : U8
filter_tag = 0x32

project_tag : U8
project_tag = 0x33

# ===== Project Item Tags =====

whole_node_tag : U8
whole_node_tag = 0x00

node_property_tag : U8
node_property_tag = 0x01

# ===== Alias Helpers =====

## Find an alias's index in the alias list.
alias_index : List Str, Str -> U16
alias_index = |aliases, target|
    result = List.walk_until(aliases, 0u16, |idx, alias|
        if alias == target then
            Break(idx)
        else
            Continue(idx + 1))
    result

## Get an alias string from an index.
lookup_alias : List Str, U16 -> Result Str [OutOfBounds]
lookup_alias = |aliases, idx|
    List.get(aliases, Num.int_cast(idx))

# ===== Encode =====

## Encode a QueryPlan to a byte list.
##
## Wire format:
## [step_count : U16LE]
## [alias_count : U16LE]
## [aliases... : (len:U16LE, utf8)*]
## [steps... : (tag:U8, payload)*]
encode_plan : QueryPlan -> List U8
encode_plan = |plan|
    step_count : U16
    step_count = Num.int_cast(List.len(plan.steps))
    alias_count : U16
    alias_count = Num.int_cast(List.len(plan.aliases))

    # Header
    buf = encode_u16(step_count) |> List.concat(encode_u16(alias_count))

    # Aliases
    buf_with_aliases = List.walk(plan.aliases, buf, |acc, alias|
        List.concat(acc, encode_str(alias)))

    # Steps
    List.walk(plan.steps, buf_with_aliases, |acc, step|
        List.concat(acc, encode_step(plan.aliases, step)))

## Encode a single PlanStep.
encode_step : List Str, PlanStep -> List U8
encode_step = |aliases, step|
    when step is
        ScanSeeds({ alias, node_ids, label, inline_props }) ->
            buf = [scan_seeds_tag]
                |> List.concat(encode_u16(alias_index(aliases, alias)))
            # Label
            buf_with_label =
                when label is
                    Unlabeled -> List.append(buf, 0x00)
                    Labeled(lbl) ->
                        buf
                        |> List.append(0x01)
                        |> List.concat(encode_str(lbl))
            # Inline props
            prop_count : U16
            prop_count = Num.int_cast(List.len(inline_props))
            buf_with_props = List.walk(inline_props, buf_with_label |> List.concat(encode_u16(prop_count)), |acc, { key, value }|
                acc
                |> List.concat(encode_str(key))
                |> List.concat(encode_quine_value(value)))
            # Node IDs
            id_count : U16
            id_count = Num.int_cast(List.len(node_ids))
            List.walk(node_ids, buf_with_props |> List.concat(encode_u16(id_count)), |acc, nid|
                bytes = QuineId.to_bytes(nid)
                # Pad or truncate to exactly 16 bytes
                padded = pad_to_16(bytes)
                List.concat(acc, padded))

        Traverse({ from_alias, to_alias, direction, edge_type, to_label }) ->
            buf = [traverse_tag]
                |> List.concat(encode_u16(alias_index(aliases, from_alias)))
                |> List.concat(encode_u16(alias_index(aliases, to_alias)))
            # Direction
            dir_byte =
                when direction is
                    Outgoing -> 0x00
                    Incoming -> 0x01
                    Undirected -> 0x02
            buf_with_dir = List.append(buf, dir_byte)
            # Edge type
            buf_with_type =
                when edge_type is
                    Untyped -> List.append(buf_with_dir, 0x00)
                    Typed(t) ->
                        buf_with_dir
                        |> List.append(0x01)
                        |> List.concat(encode_str(t))
            # To label
            when to_label is
                Unlabeled -> List.append(buf_with_type, 0x00)
                Labeled(lbl) ->
                    buf_with_type
                    |> List.append(0x01)
                    |> List.concat(encode_str(lbl))

        Filter({ predicate }) ->
            expr_bytes = encode_expr(predicate)
            expr_len : U32
            expr_len = Num.int_cast(List.len(expr_bytes))
            [filter_tag]
            |> List.concat(encode_u32(expr_len))
            |> List.concat(expr_bytes)

        Project({ items }) ->
            item_count : U16
            item_count = Num.int_cast(List.len(items))
            List.walk(items, [project_tag] |> List.concat(encode_u16(item_count)), |acc, item|
                List.concat(acc, encode_project_item(aliases, item)))

## Encode a single ProjectItem.
encode_project_item : List Str, ProjectItem -> List U8
encode_project_item = |aliases, item|
    when item is
        WholeNode(alias) ->
            [whole_node_tag]
            |> List.concat(encode_u16(alias_index(aliases, alias)))

        NodeProperty({ alias, prop, output_name }) ->
            [node_property_tag]
            |> List.concat(encode_u16(alias_index(aliases, alias)))
            |> List.concat(encode_str(prop))
            |> List.concat(encode_str(output_name))

## Pad or truncate bytes to exactly 16 bytes.
pad_to_16 : List U8 -> List U8
pad_to_16 = |bytes|
    len = List.len(bytes)
    if len >= 16 then
        List.sublist(bytes, { start: 0, len: 16 })
    else
        padding = List.repeat(0u8, 16 - len)
        List.concat(bytes, padding)

# ===== Decode =====

## Decode a QueryPlan from a byte list.
decode_plan : List U8 -> Result QueryPlan [OutOfBounds, BadUtf8, InvalidTag]
decode_plan = |buf|
    if List.is_empty(buf) then
        Err(OutOfBounds)
    else
        # Step count
        when decode_u16(buf, 0) is
            Err(e) -> Err(e)
            Ok({ val: step_count_u16, next: ac_offset }) ->
                # Alias count
                when decode_u16(buf, ac_offset) is
                    Err(e) -> Err(e)
                    Ok({ val: alias_count_u16, next: aliases_start }) ->
                        step_count = Num.int_cast(step_count_u16)
                        alias_count = Num.int_cast(alias_count_u16)
                        # Decode aliases
                        when decode_str_list(buf, aliases_start, alias_count, []) is
                            Err(e) -> Err(e)
                            Ok({ val: aliases, next: steps_start }) ->
                                # Decode steps
                                when decode_step_list(buf, steps_start, step_count, aliases, []) is
                                    Err(e) -> Err(e)
                                    Ok({ val: steps }) ->
                                        Ok({ steps, aliases })

## Decode a list of N UTF-8 strings.
decode_str_list : List U8, U64, U64, List Str -> Result { val : List Str, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_str_list = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_str(buf, offset) is
            Err(OutOfBounds) -> Err(OutOfBounds)
            Err(BadUtf8) -> Err(BadUtf8)
            Ok({ val: s, next }) ->
                decode_str_list(buf, next, remaining - 1, List.append(acc, s))

## Decode a list of N PlanSteps.
decode_step_list : List U8, U64, U64, List Str, List PlanStep -> Result { val : List PlanStep } [OutOfBounds, BadUtf8, InvalidTag]
decode_step_list = |buf, offset, remaining, aliases, acc|
    if remaining == 0 then
        Ok({ val: acc })
    else
        when decode_step(buf, offset, aliases) is
            Err(e) -> Err(e)
            Ok({ val: step, next }) ->
                decode_step_list(buf, next, remaining - 1, aliases, List.append(acc, step))

## Decode a single PlanStep from the buffer.
decode_step : List U8, U64, List Str -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_step = |buf, offset, aliases|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            data_start = offset + 1
            when tag is
                0x30 -> decode_scan_seeds(buf, data_start, aliases)
                0x31 -> decode_traverse(buf, data_start, aliases)
                0x32 -> decode_filter(buf, data_start)
                0x33 -> decode_project(buf, data_start, aliases)
                _ -> Err(InvalidTag)

## Decode a ScanSeeds step.
decode_scan_seeds : List U8, U64, List Str -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_scan_seeds = |buf, offset, aliases|
    # alias_idx
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: alias_idx, next: label_tag_offset }) ->
            when lookup_alias(aliases, alias_idx) is
                Err(_) -> Err(OutOfBounds)
                Ok(alias) ->
                    # label_tag
                    when List.get(buf, label_tag_offset) is
                        Err(_) -> Err(OutOfBounds)
                        Ok(label_tag) ->
                            when decode_label(buf, label_tag_offset, label_tag) is
                                Err(e) -> Err(e)
                                Ok({ val: label, next: props_count_offset }) ->
                                    # inline_prop_count
                                    when decode_u16(buf, props_count_offset) is
                                        Err(e) -> Err(e)
                                        Ok({ val: prop_count_u16, next: props_start }) ->
                                            prop_count = Num.int_cast(prop_count_u16)
                                            when decode_inline_props(buf, props_start, prop_count, []) is
                                                Err(e) -> Err(e)
                                                Ok({ val: inline_props, next: ids_count_offset }) ->
                                                    # node_id_count
                                                    when decode_u16(buf, ids_count_offset) is
                                                        Err(e) -> Err(e)
                                                        Ok({ val: id_count_u16, next: ids_start }) ->
                                                            id_count = Num.int_cast(id_count_u16)
                                                            when decode_node_ids(buf, ids_start, id_count, []) is
                                                                Err(e) -> Err(e)
                                                                Ok({ val: node_ids, next: final_offset }) ->
                                                                    Ok({
                                                                        val: ScanSeeds({ alias, node_ids, label, inline_props }),
                                                                        next: final_offset,
                                                                    })

## Decode a label tag+value.
decode_label : List U8, U64, U8 -> Result { val : [Labeled Str, Unlabeled], next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_label = |buf, offset, tag|
    when tag is
        0x00 -> Ok({ val: Unlabeled, next: offset + 1 })
        0x01 ->
            when decode_str(buf, offset + 1) is
                Err(OutOfBounds) -> Err(OutOfBounds)
                Err(BadUtf8) -> Err(BadUtf8)
                Ok({ val: lbl, next }) -> Ok({ val: Labeled(lbl), next })
        _ -> Err(InvalidTag)

## Decode inline property key-value pairs.
decode_inline_props : List U8, U64, U64, List { key : Str, value : QuineValue } -> Result { val : List { key : Str, value : QuineValue }, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_inline_props = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when decode_str(buf, offset) is
            Err(OutOfBounds) -> Err(OutOfBounds)
            Err(BadUtf8) -> Err(BadUtf8)
            Ok({ val: key, next: val_offset }) ->
                when decode_quine_value(buf, val_offset) is
                    Err(e) -> Err(e)
                    Ok({ val: value, next: next_offset }) ->
                        decode_inline_props(buf, next_offset, remaining - 1, List.append(acc, { key, value }))

## Decode node IDs (16 bytes each).
decode_node_ids : List U8, U64, U64, List QuineId -> Result { val : List QuineId, next : U64 } [OutOfBounds]
decode_node_ids = |buf, offset, remaining, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        id_bytes = List.sublist(buf, { start: offset, len: 16 })
        if List.len(id_bytes) == 16 then
            nid = QuineId.from_bytes(id_bytes)
            decode_node_ids(buf, offset + 16, remaining - 1, List.append(acc, nid))
        else
            Err(OutOfBounds)

## Decode a Traverse step.
decode_traverse : List U8, U64, List Str -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_traverse = |buf, offset, aliases|
    # from_alias_idx
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: from_idx, next: to_offset }) ->
            # to_alias_idx
            when decode_u16(buf, to_offset) is
                Err(e) -> Err(e)
                Ok({ val: to_idx, next: dir_offset }) ->
                    when (lookup_alias(aliases, from_idx), lookup_alias(aliases, to_idx)) is
                        (Ok(from_alias), Ok(to_alias)) ->
                            # direction
                            when List.get(buf, dir_offset) is
                                Err(_) -> Err(OutOfBounds)
                                Ok(dir_byte) ->
                                    when decode_direction(dir_byte) is
                                        Err(e) -> Err(e)
                                        Ok(direction) ->
                                            # edge type
                                            when List.get(buf, dir_offset + 1) is
                                                Err(_) -> Err(OutOfBounds)
                                                Ok(type_tag) ->
                                                    when decode_edge_type(buf, dir_offset + 1, type_tag) is
                                                        Err(e) -> Err(e)
                                                        Ok({ val: edge_type, next: to_label_offset }) ->
                                                            # to_label
                                                            when List.get(buf, to_label_offset) is
                                                                Err(_) -> Err(OutOfBounds)
                                                                Ok(label_tag) ->
                                                                    when decode_label(buf, to_label_offset, label_tag) is
                                                                        Err(e) -> Err(e)
                                                                        Ok({ val: to_label, next: final_offset }) ->
                                                                            Ok({
                                                                                val: Traverse({ from_alias, to_alias, direction, edge_type, to_label }),
                                                                                next: final_offset,
                                                                            })
                        _ -> Err(OutOfBounds)

## Decode a direction byte.
decode_direction : U8 -> Result [Outgoing, Incoming, Undirected] [InvalidTag]
decode_direction = |b|
    when b is
        0x00 -> Ok(Outgoing)
        0x01 -> Ok(Incoming)
        0x02 -> Ok(Undirected)
        _ -> Err(InvalidTag)

## Decode an edge type tag+value.
decode_edge_type : List U8, U64, U8 -> Result { val : [Typed Str, Untyped], next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_edge_type = |buf, offset, tag|
    when tag is
        0x00 -> Ok({ val: Untyped, next: offset + 1 })
        0x01 ->
            when decode_str(buf, offset + 1) is
                Err(OutOfBounds) -> Err(OutOfBounds)
                Err(BadUtf8) -> Err(BadUtf8)
                Ok({ val: t, next }) -> Ok({ val: Typed(t), next })
        _ -> Err(InvalidTag)

## Decode a Filter step.
decode_filter : List U8, U64 -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_filter = |buf, offset|
    when decode_u32(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: expr_len_u32, next: expr_start }) ->
            expr_len = Num.int_cast(expr_len_u32)
            expr_bytes = List.sublist(buf, { start: expr_start, len: expr_len })
            if List.len(expr_bytes) == expr_len then
                when decode_expr(expr_bytes, 0) is
                    Err(e) -> Err(e)
                    Ok({ val: predicate }) ->
                        Ok({
                            val: Filter({ predicate }),
                            next: expr_start + expr_len,
                        })
            else
                Err(OutOfBounds)

## Decode a Project step.
decode_project : List U8, U64, List Str -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_project = |buf, offset, aliases|
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: item_count_u16, next: items_start }) ->
            item_count = Num.int_cast(item_count_u16)
            when decode_project_items(buf, items_start, item_count, aliases, []) is
                Err(e) -> Err(e)
                Ok({ val: items, next: final_offset }) ->
                    Ok({
                        val: Project({ items }),
                        next: final_offset,
                    })

## Decode a list of N ProjectItems.
decode_project_items : List U8, U64, U64, List Str, List ProjectItem -> Result { val : List ProjectItem, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_project_items = |buf, offset, remaining, aliases, acc|
    if remaining == 0 then
        Ok({ val: acc, next: offset })
    else
        when List.get(buf, offset) is
            Err(_) -> Err(OutOfBounds)
            Ok(tag) ->
                data_start = offset + 1
                when tag is
                    0x00 ->
                        # WholeNode
                        when decode_u16(buf, data_start) is
                            Err(e) -> Err(e)
                            Ok({ val: idx, next }) ->
                                when lookup_alias(aliases, idx) is
                                    Err(_) -> Err(OutOfBounds)
                                    Ok(alias) ->
                                        decode_project_items(buf, next, remaining - 1, aliases, List.append(acc, WholeNode(alias)))

                    0x01 ->
                        # NodeProperty
                        when decode_u16(buf, data_start) is
                            Err(e) -> Err(e)
                            Ok({ val: idx, next: prop_offset }) ->
                                when lookup_alias(aliases, idx) is
                                    Err(_) -> Err(OutOfBounds)
                                    Ok(alias) ->
                                        when decode_str(buf, prop_offset) is
                                            Err(OutOfBounds) -> Err(OutOfBounds)
                                            Err(BadUtf8) -> Err(BadUtf8)
                                            Ok({ val: prop, next: out_offset }) ->
                                                when decode_str(buf, out_offset) is
                                                    Err(OutOfBounds) -> Err(OutOfBounds)
                                                    Err(BadUtf8) -> Err(BadUtf8)
                                                    Ok({ val: output_name, next: final_offset }) ->
                                                        decode_project_items(buf, final_offset, remaining - 1, aliases, List.append(acc, NodeProperty({ alias, prop, output_name })))

                    _ -> Err(InvalidTag)

# ===== Tests =====

# Test 1: Single ScanSeeds + Project round-trips (verify step count and aliases)
expect
    plan : QueryPlan
    plan = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [], label: Unlabeled, inline_props: [] }),
            Project({ items: [WholeNode("n")] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(plan)
    when decode_plan(bytes) is
        Ok(decoded) ->
            List.len(decoded.steps) == 2
            && decoded.aliases == ["n"]
        Err(_) -> Bool.false

# Test 2: Labeled ScanSeeds round-trips
expect
    plan : QueryPlan
    plan = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [], label: Labeled("Person"), inline_props: [] }),
            Project({ items: [WholeNode("n")] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(plan)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.first(decoded.steps) is
                Ok(ScanSeeds({ label })) -> label == Labeled("Person")
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 3: ScanSeeds with inline props round-trips
expect
    plan : QueryPlan
    plan = {
        steps: [
            ScanSeeds({
                alias: "n",
                node_ids: [],
                label: Unlabeled,
                inline_props: [{ key: "name", value: Str("Alice") }],
            }),
            Project({ items: [WholeNode("n")] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(plan)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.first(decoded.steps) is
                Ok(ScanSeeds({ inline_props })) ->
                    List.len(inline_props) == 1
                    && (
                        when List.first(inline_props) is
                            Ok({ key, value }) ->
                                key == "name"
                                && (
                                    when value is
                                        Str(s) -> s == "Alice"
                                        _ -> Bool.false
                                )
                            _ -> Bool.false
                    )
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 4: Traverse round-trips (verify from/to alias, direction, edge_type)
expect
    plan : QueryPlan
    plan = {
        steps: [
            ScanSeeds({ alias: "a", node_ids: [], label: Labeled("Person"), inline_props: [] }),
            Traverse({ from_alias: "a", to_alias: "b", direction: Outgoing, edge_type: Typed("KNOWS"), to_label: Unlabeled }),
            Project({ items: [WholeNode("a"), WholeNode("b")] }),
        ],
        aliases: ["a", "b"],
    }
    bytes = encode_plan(plan)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.get(decoded.steps, 1) is
                Ok(Traverse({ from_alias, to_alias, direction, edge_type })) ->
                    from_alias == "a"
                    && to_alias == "b"
                    && direction == Outgoing
                    && edge_type == Typed("KNOWS")
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 5: Filter round-trips (verify predicate preserved)
expect
    pred : Expr
    pred = Comparison({ left: Variable("n"), op: Eq, right: Literal(Integer(42)) })
    plan : QueryPlan
    plan = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [], label: Labeled("Person"), inline_props: [] }),
            Filter({ predicate: pred }),
            Project({ items: [WholeNode("n")] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(plan)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.get(decoded.steps, 1) is
                Ok(Filter({ predicate })) ->
                    when predicate is
                        Comparison({ left: Variable("n"), op: Eq, right: Literal(Integer(42)) }) -> Bool.true
                        _ -> Bool.false
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 6: NodeProperty project item round-trips (verify prop and output_name)
expect
    plan : QueryPlan
    plan = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [], label: Labeled("Person"), inline_props: [] }),
            Project({ items: [NodeProperty({ alias: "n", prop: "name", output_name: "full_name" })] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(plan)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.last(decoded.steps) is
                Ok(Project({ items })) ->
                    when List.first(items) is
                        Ok(NodeProperty({ alias, prop, output_name })) ->
                            alias == "n" && prop == "name" && output_name == "full_name"
                        _ -> Bool.false
                _ -> Bool.false
        Err(_) -> Bool.false

# Test 7: Multi-hop plan round-trips (ScanSeeds + 2 Traverse + Project, 3 aliases)
expect
    plan : QueryPlan
    plan = {
        steps: [
            ScanSeeds({ alias: "a", node_ids: [], label: Labeled("Person"), inline_props: [] }),
            Traverse({ from_alias: "a", to_alias: "b", direction: Outgoing, edge_type: Typed("KNOWS"), to_label: Unlabeled }),
            Traverse({ from_alias: "b", to_alias: "c", direction: Incoming, edge_type: Typed("FOLLOWS"), to_label: Labeled("User") }),
            Project({ items: [WholeNode("a"), WholeNode("b"), WholeNode("c")] }),
        ],
        aliases: ["a", "b", "c"],
    }
    bytes = encode_plan(plan)
    when decode_plan(bytes) is
        Ok(decoded) ->
            List.len(decoded.steps) == 4
            && decoded.aliases == ["a", "b", "c"]
            && (
                when List.get(decoded.steps, 2) is
                    Ok(Traverse({ from_alias, to_alias, direction, edge_type, to_label })) ->
                        from_alias == "b"
                        && to_alias == "c"
                        && direction == Incoming
                        && edge_type == Typed("FOLLOWS")
                        && to_label == Labeled("User")
                    _ -> Bool.false
            )
        Err(_) -> Bool.false

# Test 8: Empty buffer -> error
expect
    when decode_plan([]) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false
