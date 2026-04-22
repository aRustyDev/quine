# C1.2: Cypher Query Planner — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert a CypherQuery AST (from the Roc parser) into a serialized QueryPlan that the Rust executor can decode and walk. This is the Roc→Rust FFI boundary for Cypher queries.

**Architecture:** Roc planner (`packages/cypher/Planner.roc`) converts AST to QueryPlan. Roc codecs (`PlanCodec.roc`, `ExprCodec.roc`) serialize it to bytes. Rust decoders (`platform/src/cypher/`) deserialize into Rust types. TDD — failing tests first, then implement.

**Tech Stack:** Roc (`packages/cypher/`, `packages/expr/`, `packages/core/model/`), Rust (`platform/src/cypher/`)

**Spec:** `docs/superpowers/specs/2026-04-22-cypher-query-planner-design.md`

**Test commands:**
- Roc: `roc test packages/cypher/<Module>.roc`
- Roc check: `roc check packages/cypher/main.roc`
- Rust: `cd platform && cargo test cypher`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `packages/cypher/main.roc` | Modify | Add Planner, PlanCodec, ExprCodec to package exports |
| `packages/cypher/Planner.roc` | Create | QueryPlan, PlanStep, ProjectItem types + `plan` function |
| `packages/cypher/ExprCodec.roc` | Create | `encode_expr`, `decode_expr` for Expr ↔ bytes |
| `packages/cypher/PlanCodec.roc` | Create | `encode_plan`, `decode_plan` for QueryPlan ↔ bytes |
| `platform/src/cypher/mod.rs` | Create | Module root — re-exports plan, expr |
| `platform/src/cypher/expr.rs` | Create | Rust Expr types + `decode_expr` |
| `platform/src/cypher/plan.rs` | Create | Rust QueryPlan types + `decode_plan` |
| `platform/src/main.rs` | Modify | Add `mod cypher;` |

---

### Task 1: Planner Types and Package Wiring

**Files:**
- Modify: `packages/cypher/main.roc`
- Create: `packages/cypher/Planner.roc`

- [ ] **Step 1: Update package manifest**

Add Planner, PlanCodec, ExprCodec to exports. Add `id` dependency for QuineId.

```roc
# packages/cypher/main.roc
package [Ast, Token, Lexer, Parser, Planner, PlanCodec, ExprCodec] {
    expr: "../expr/main.roc",
    model: "../core/model/main.roc",
    id: "../core/id/main.roc",
}
```

- [ ] **Step 2: Create Planner.roc with types and a stub plan function**

```roc
module [
    QueryPlan,
    PlanStep,
    ProjectItem,
    plan,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import expr.Expr exposing [Expr]

## A flat sequence of operations for the Rust executor to walk.
QueryPlan : {
    steps : List PlanStep,
    aliases : List Str,
}

## One step in a query plan.
PlanStep : [
    ScanSeeds {
        alias : Str,
        node_ids : List QuineId,
        label : [Labeled Str, Unlabeled],
        inline_props : List { key : Str, value : QuineValue },
    },
    Traverse {
        from_alias : Str,
        edge_type : [Typed Str, Untyped],
        direction : [Outgoing, Incoming, Undirected],
        to_alias : Str,
        to_label : [Labeled Str, Unlabeled],
    },
    Filter {
        predicate : Expr,
    },
    Project {
        items : List ProjectItem,
    },
]

## An item in the Project step.
ProjectItem : [
    WholeNode Str,
    NodeProperty { alias : Str, prop : Str, output_name : Str },
]

## Convert a CypherQuery AST + seed node IDs into a QueryPlan.
plan : { pattern : _, where_ : _, return_items : _ }, List QuineId -> Result QueryPlan [PlanError Str]
plan = |_query, _node_ids|
    Err(PlanError("not implemented"))
```

- [ ] **Step 3: Verify it compiles**

Run: `roc check packages/cypher/main.roc`
Expected: 0 errors

- [ ] **Step 4: Commit**

```bash
git add packages/cypher/main.roc packages/cypher/Planner.roc
git commit -m "C1.2: planner types — QueryPlan, PlanStep, ProjectItem"
```

---

### Task 2: Planner Logic — ScanSeeds and Traverse

**Files:**
- Modify: `packages/cypher/Planner.roc`

- [ ] **Step 1: Write failing tests for ScanSeeds generation**

Add to `Planner.roc`:

```roc
import Ast exposing [CypherQuery, Pattern, NodePattern, EdgePattern, ReturnItem]

# ===== Test helpers =====

make_node : Str -> NodePattern
make_node = |name|
    { alias: Named(name), label: Unlabeled, props: [] }

make_labeled_node : Str, Str -> NodePattern
make_labeled_node = |name, lbl|
    { alias: Named(name), label: Labeled(lbl), props: [] }

make_edge : Str, [Outgoing, Incoming, Undirected] -> EdgePattern
make_edge = |typ, dir|
    { alias: Anon, edge_type: Typed(typ), direction: dir }

seed : QuineId
seed = QuineId.from_bytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10])

# ===== Tests =====

# Test: single node query generates ScanSeeds + Project
expect
    query : CypherQuery
    query = {
        pattern: { start: make_node("n"), steps: [] },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    when plan(query, [seed]) is
        Ok(qp) ->
            List.len(qp.steps) == 2
            && (when List.first(qp.steps) is
                Ok(ScanSeeds({ alias, label })) -> alias == "n" && label == Unlabeled
                _ -> Bool.false)
        Err(_) -> Bool.false

# Test: no seeds and no inline props → PlanError
expect
    query : CypherQuery
    query = {
        pattern: { start: make_node("n"), steps: [] },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    when plan(query, []) is
        Err(PlanError(_)) -> Bool.true
        _ -> Bool.false

# Test: labeled node populates label field
expect
    query : CypherQuery
    query = {
        pattern: { start: make_labeled_node("n", "Person"), steps: [] },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    when plan(query, [seed]) is
        Ok(qp) ->
            when List.first(qp.steps) is
                Ok(ScanSeeds({ label })) ->
                    when label is
                        Labeled("Person") -> Bool.true
                        _ -> Bool.false
                _ -> Bool.false
        Err(_) -> Bool.false

# Test: inline props are captured in ScanSeeds
expect
    query : CypherQuery
    query = {
        pattern: {
            start: { alias: Named("n"), label: Unlabeled, props: [{ key: "name", value: Str("Alice") }] },
            steps: [],
        },
        where_: NoWhere,
        return_items: [WholeAlias("n")],
    }
    # inline props act as seeds — no node_ids needed
    when plan(query, []) is
        Ok(qp) ->
            when List.first(qp.steps) is
                Ok(ScanSeeds({ inline_props })) -> List.len(inline_props) == 1
                _ -> Bool.false
        Err(_) -> Bool.false
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `roc test packages/cypher/Planner.roc`
Expected: 4 failures (stub returns Err)

- [ ] **Step 3: Write failing tests for Traverse generation**

```roc
# Test: single-hop generates ScanSeeds + Traverse + Project
expect
    query : CypherQuery
    query = {
        pattern: {
            start: make_node("a"),
            steps: [{ edge: make_edge("KNOWS", Outgoing), node: make_node("b") }],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("b")],
    }
    when plan(query, [seed]) is
        Ok(qp) ->
            List.len(qp.steps) == 3
            && (when List.get(qp.steps, 1) is
                Ok(Traverse({ from_alias, to_alias, direction })) ->
                    from_alias == "a" && to_alias == "b" && direction == Outgoing
                _ -> Bool.false)
        Err(_) -> Bool.false

# Test: multi-hop generates multiple Traverse steps
expect
    query : CypherQuery
    query = {
        pattern: {
            start: make_node("a"),
            steps: [
                { edge: make_edge("KNOWS", Outgoing), node: make_node("b") },
                { edge: make_edge("FOLLOWS", Outgoing), node: make_node("c") },
            ],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("c")],
    }
    when plan(query, [seed]) is
        Ok(qp) ->
            List.len(qp.steps) == 4  # ScanSeeds + 2 Traverse + Project
        Err(_) -> Bool.false
```

- [ ] **Step 4: Implement ScanSeeds and Traverse generation**

Replace the stub `plan` function:

```roc
plan = |query, node_ids|
    start_node = query.pattern.start
    has_seeds = List.len(node_ids) > 0
    has_inline = List.len(start_node.props) > 0
    has_label = when start_node.label is
        Labeled(_) -> Bool.true
        Unlabeled -> Bool.false

    if !(has_seeds || has_inline || has_label) then
        Err(PlanError("no seed nodes: provide node_ids or inline property constraints"))
    else
        alias = when start_node.alias is
            Named(name) -> name
            Anon -> "_start"

        scan_step = ScanSeeds({
            alias,
            node_ids,
            label: start_node.label,
            inline_props: start_node.props,
        })

        traverse_steps = List.map(query.pattern.steps, |step|
            to_alias = when step.node.alias is
                Named(name) -> name
                Anon -> "_anon"
            Traverse({
                from_alias: alias_for_traverse_from(scan_step, query.pattern.steps, step),
                edge_type: step.edge.edge_type,
                direction: step.edge.direction,
                to_alias,
                to_label: step.node.label,
            }))

        project_result = build_project(query.return_items, collect_aliases(scan_step, traverse_steps))
        when project_result is
            Ok(project_step) ->
                all_steps = List.concat([scan_step], traverse_steps) |> List.append(project_step)
                aliases = collect_alias_list(scan_step, traverse_steps)
                Ok({ steps: all_steps, aliases })
            Err(e) -> Err(e)
```

Wait — this approach has a problem with tracking `from_alias` across traverse steps. Let me use a simpler indexed approach:

```roc
plan = |query, node_ids|
    start_node = query.pattern.start
    has_seeds = List.len(node_ids) > 0
    has_inline = List.len(start_node.props) > 0
    has_label = when start_node.label is
        Labeled(_) -> Bool.true
        Unlabeled -> Bool.false

    if !(has_seeds || has_inline || has_label) then
        Err(PlanError("no seed nodes: provide node_ids or inline property constraints"))
    else
        start_alias = when start_node.alias is
            Named(name) -> name
            Anon -> "_start"

        scan_step = ScanSeeds({
            alias: start_alias,
            node_ids,
            label: start_node.label,
            inline_props: start_node.props,
        })

        traverse_result = build_traversals(start_alias, query.pattern.steps)

        when traverse_result is
            Ok({ steps: trav_steps, aliases: trav_aliases }) ->
                all_aliases = List.concat([start_alias], trav_aliases)
                project_result = build_project(query.return_items, all_aliases)
                when project_result is
                    Ok(project_step) ->
                        filter_steps = when query.where_ is
                            Where(expr) -> [Filter({ predicate: expr })]
                            NoWhere -> []
                        all_steps =
                            [scan_step]
                            |> List.concat(trav_steps)
                            |> List.concat(filter_steps)
                            |> List.append(project_step)
                        Ok({ steps: all_steps, aliases: all_aliases })
                    Err(e) -> Err(e)
            Err(e) -> Err(e)

## Build Traverse steps, threading the "current" alias through each hop.
build_traversals : Str, List { edge : EdgePattern, node : NodePattern } -> Result { steps : List PlanStep, aliases : List Str } [PlanError Str]
build_traversals = |start_alias, pattern_steps|
    List.walk(
        pattern_steps,
        Ok({ steps: [], aliases: [], prev_alias: start_alias }),
        |acc_result, step|
            when acc_result is
                Err(e) -> Err(e)
                Ok(acc) ->
                    to_alias = when step.node.alias is
                        Named(name) -> name
                        Anon -> "_anon_$(Num.to_str(List.len(acc.steps)))"
                    trav = Traverse({
                        from_alias: acc.prev_alias,
                        edge_type: step.edge.edge_type,
                        direction: step.edge.direction,
                        to_alias,
                        to_label: step.node.label,
                    })
                    Ok({
                        steps: List.append(acc.steps, trav),
                        aliases: List.append(acc.aliases, to_alias),
                        prev_alias: to_alias,
                    }),
    )
    |> Result.map(|acc| { steps: acc.steps, aliases: acc.aliases })

## Build the Project step from ReturnItems, validating aliases.
build_project : List ReturnItem, List Str -> Result PlanStep [PlanError Str]
build_project = |return_items, known_aliases|
    items_result = List.walk(
        return_items,
        Ok([]),
        |acc_result, item|
            when acc_result is
                Err(e) -> Err(e)
                Ok(acc) ->
                    when item is
                        WholeAlias(alias) ->
                            if List.contains(known_aliases, alias) then
                                Ok(List.append(acc, WholeNode(alias)))
                            else
                                Err(PlanError("unknown alias in RETURN: $(alias)"))
                        PropAccess({ alias, prop, rename_as }) ->
                            if List.contains(known_aliases, alias) then
                                out_name = when rename_as is
                                    As(name) -> name
                                    NoAs -> "$(alias).$(prop)"
                                Ok(List.append(acc, NodeProperty({ alias, prop, output_name: out_name })))
                            else
                                Err(PlanError("unknown alias in RETURN: $(alias)")),
    )
    Result.map(items_result, |items| Project({ items }))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `roc test packages/cypher/Planner.roc`
Expected: 6 passed, 0 failed

- [ ] **Step 6: Commit**

```bash
git add packages/cypher/Planner.roc
git commit -m "C1.2: planner logic — ScanSeeds, Traverse, build_project"
```

---

### Task 3: Planner Logic — Filter, Project, and Error Cases

**Files:**
- Modify: `packages/cypher/Planner.roc`

- [ ] **Step 1: Write failing tests for Filter, Project, and errors**

```roc
# Test: WHERE clause generates Filter step
expect
    query : CypherQuery
    query = {
        pattern: { start: make_node("n"), steps: [] },
        where_: Where(Comparison({ left: Property({ expr: Variable("n"), key: "age" }), op: Gt, right: Literal(Integer(25)) })),
        return_items: [WholeAlias("n")],
    }
    when plan(query, [seed]) is
        Ok(qp) ->
            List.len(qp.steps) == 3  # ScanSeeds + Filter + Project
            && (when List.get(qp.steps, 1) is
                Ok(Filter(_)) -> Bool.true
                _ -> Bool.false)
        Err(_) -> Bool.false

# Test: PropAccess return item with AS rename
expect
    query : CypherQuery
    query = {
        pattern: { start: make_node("n"), steps: [] },
        where_: NoWhere,
        return_items: [PropAccess({ alias: "n", prop: "name", rename_as: As("person_name") })],
    }
    when plan(query, [seed]) is
        Ok(qp) ->
            when List.last(qp.steps) is
                Ok(Project({ items })) ->
                    when List.first(items) is
                        Ok(NodeProperty({ output_name })) -> output_name == "person_name"
                        _ -> Bool.false
                _ -> Bool.false
        Err(_) -> Bool.false

# Test: PropAccess return item without AS defaults to "alias.prop"
expect
    query : CypherQuery
    query = {
        pattern: { start: make_node("n"), steps: [] },
        where_: NoWhere,
        return_items: [PropAccess({ alias: "n", prop: "name", rename_as: NoAs })],
    }
    when plan(query, [seed]) is
        Ok(qp) ->
            when List.last(qp.steps) is
                Ok(Project({ items })) ->
                    when List.first(items) is
                        Ok(NodeProperty({ output_name })) -> output_name == "n.name"
                        _ -> Bool.false
                _ -> Bool.false
        Err(_) -> Bool.false

# Test: unknown alias in RETURN → PlanError
expect
    query : CypherQuery
    query = {
        pattern: { start: make_node("n"), steps: [] },
        where_: NoWhere,
        return_items: [WholeAlias("x")],
    }
    when plan(query, [seed]) is
        Err(PlanError(msg)) -> Str.contains(msg, "unknown alias")
        _ -> Bool.false

# Test: aliases list contains all bound aliases
expect
    query : CypherQuery
    query = {
        pattern: {
            start: make_node("a"),
            steps: [{ edge: make_edge("KNOWS", Outgoing), node: make_node("b") }],
        },
        where_: NoWhere,
        return_items: [WholeAlias("a"), WholeAlias("b")],
    }
    when plan(query, [seed]) is
        Ok(qp) -> qp.aliases == ["a", "b"]
        Err(_) -> Bool.false
```

- [ ] **Step 2: Run tests to verify new ones fail (or pass if already implemented)**

Run: `roc test packages/cypher/Planner.roc`

If Filter/Project tests already pass from Task 2's implementation, that's expected — the logic was included there. If any fail, fix them now. The error case and alias tests may need attention.

- [ ] **Step 3: Fix any failing tests**

Adjust `plan` or `build_project` as needed to make all tests pass. The implementation from Task 2 should already handle most of these. Verify the aliases list is correctly populated.

- [ ] **Step 4: Run all tests**

Run: `roc test packages/cypher/Planner.roc`
Expected: 11 passed, 0 failed

- [ ] **Step 5: Verify package compiles clean**

Run: `roc check packages/cypher/main.roc`
Expected: 0 errors

- [ ] **Step 6: Commit**

```bash
git add packages/cypher/Planner.roc
git commit -m "C1.2: planner — Filter, Project, error cases, alias collection"
```

---

### Task 4: Expr Codec (Roc)

**Files:**
- Create: `packages/cypher/ExprCodec.roc`

- [ ] **Step 1: Write the ExprCodec module with encode and decode**

This codec serializes `Expr` trees to bytes using a tag-per-node recursive format. It depends on the QuineValue codec from the graph package, but since that's in a different package, we reimplement the QuineValue encoding here (same tags, same format).

```roc
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

# ===== Tags =====

# Expr tags (0x40 range)
tag_literal = 0x40
tag_variable = 0x41
tag_property = 0x42
tag_comparison = 0x43
tag_bool_op = 0x44
tag_not = 0x45
tag_is_null = 0x46
tag_in_list = 0x47
tag_fn_call = 0x48

# CompOp tags
comp_eq = 0x00
comp_neq = 0x01
comp_lt = 0x02
comp_gt = 0x03
comp_lte = 0x04
comp_gte = 0x05

# BoolLogic tags
bool_and = 0x00
bool_or = 0x01

# QuineValue tags (same as Codec.roc)
qv_str = 0x01
qv_integer = 0x02
qv_floating = 0x03
qv_true = 0x04
qv_false = 0x05
qv_null = 0x06
qv_bytes = 0x07

# ===== Primitive encoders (duplicated from Codec.roc — different package) =====

encode_u16 : U16 -> List U8
encode_u16 = |n|
    lo = Num.int_cast(Num.bitwise_and(n, 0xFF))
    hi = Num.int_cast(Num.shift_right_zf_by(n, 8))
    [lo, hi]

decode_u16 : List U8, U64 -> Result { val : U16, next : U64 } [OutOfBounds]
decode_u16 = |buf, offset|
    lo_result = List.get(buf, offset)
    hi_result = List.get(buf, offset + 1)
    when (lo_result, hi_result) is
        (Ok(lo), Ok(hi)) ->
            val : U16
            val = Num.int_cast(lo) |> Num.bitwise_or(Num.shift_left_by(Num.int_cast(hi), 8))
            Ok({ val, next: offset + 2 })
        _ -> Err(OutOfBounds)

encode_u64 : U64 -> List U8
encode_u64 = |n|
    List.range({ start: At(0), end: Before(8) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))

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

encode_str : Str -> List U8
encode_str = |s|
    bytes = Str.to_utf8(s)
    len : U16
    len = Num.int_cast(List.len(bytes))
    encode_u16(len) |> List.concat(bytes)

decode_str : List U8, U64 -> Result { val : Str, next : U64 } [OutOfBounds, BadUtf8]
decode_str = |buf, offset|
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: len_u16, next: data_start }) ->
            len = Num.int_cast(len_u16)
            extracted = List.sublist(buf, { start: data_start, len })
            if List.len(extracted) == len then
                when Str.from_utf8(extracted) is
                    Ok(s) -> Ok({ val: s, next: data_start + len })
                    Err(_) -> Err(BadUtf8)
            else
                Err(OutOfBounds)

# ===== QuineValue codec (inline — same tags as Codec.roc) =====

encode_quine_value : QuineValue -> List U8
encode_quine_value = |qv|
    when qv is
        Str(s) -> List.concat([qv_str], encode_str(s))
        Integer(i) ->
            bits : U64
            bits = Num.int_cast(i)
            List.concat([qv_integer], encode_u64(bits))
        Floating(_) -> [qv_null]  # F64 encoding deferred
        True -> [qv_true]
        False -> [qv_false]
        Null -> [qv_null]
        Bytes(b) ->
            len : U16
            len = Num.int_cast(List.len(b))
            List.concat([qv_bytes], encode_u16(len)) |> List.concat(b)
        List(_) -> [qv_null]  # List encoding deferred
        Map(_) -> [qv_null]  # Map encoding deferred
        Id(_) -> [qv_null]   # Id encoding deferred

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
                _ -> Err(InvalidTag)

# ===== CompOp / BoolLogic =====

encode_comp_op : CompOp -> U8
encode_comp_op = |op|
    when op is
        Eq -> comp_eq
        Neq -> comp_neq
        Lt -> comp_lt
        Gt -> comp_gt
        Lte -> comp_lte
        Gte -> comp_gte

decode_comp_op : U8 -> Result CompOp [InvalidTag]
decode_comp_op = |tag|
    when tag is
        0x00 -> Ok(Eq)
        0x01 -> Ok(Neq)
        0x02 -> Ok(Lt)
        0x03 -> Ok(Gt)
        0x04 -> Ok(Lte)
        0x05 -> Ok(Gte)
        _ -> Err(InvalidTag)

encode_bool_logic : BoolLogic -> U8
encode_bool_logic = |op|
    when op is
        And -> bool_and
        Or -> bool_or

decode_bool_logic : U8 -> Result BoolLogic [InvalidTag]
decode_bool_logic = |tag|
    when tag is
        0x00 -> Ok(And)
        0x01 -> Ok(Or)
        _ -> Err(InvalidTag)

# ===== Expr encode/decode =====

encode_expr : Expr -> List U8
encode_expr = |expr|
    when expr is
        Literal(qv) ->
            List.concat([tag_literal], encode_quine_value(qv))

        Variable(name) ->
            List.concat([tag_variable], encode_str(name))

        Property({ expr: inner, key }) ->
            List.concat([tag_property], encode_expr(inner))
            |> List.concat(encode_str(key))

        Comparison({ left, op, right }) ->
            [tag_comparison]
            |> List.concat(encode_expr(left))
            |> List.append(encode_comp_op(op))
            |> List.concat(encode_expr(right))

        BoolOp({ left, op, right }) ->
            [tag_bool_op]
            |> List.concat(encode_expr(left))
            |> List.append(encode_bool_logic(op))
            |> List.concat(encode_expr(right))

        Not(inner) ->
            List.concat([tag_not], encode_expr(inner))

        IsNull(inner) ->
            List.concat([tag_is_null], encode_expr(inner))

        InList({ elem, list }) ->
            [tag_in_list]
            |> List.concat(encode_expr(elem))
            |> List.concat(encode_expr(list))

        FnCall({ name, args }) ->
            arg_count : U16
            arg_count = Num.int_cast(List.len(args))
            buf = [tag_fn_call]
                |> List.concat(encode_str(name))
                |> List.concat(encode_u16(arg_count))
            List.walk(args, buf, |acc, arg| List.concat(acc, encode_expr(arg)))

decode_expr : List U8, U64 -> Result { val : Expr, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_expr = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            data_start = offset + 1
            when tag is
                0x40 ->
                    when decode_quine_value(buf, data_start) is
                        Ok({ val: qv, next }) -> Ok({ val: Literal(qv), next })
                        Err(e) -> Err(e)

                0x41 ->
                    when decode_str(buf, data_start) is
                        Ok({ val: name, next }) -> Ok({ val: Variable(name), next })
                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8)

                0x42 ->
                    when decode_expr(buf, data_start) is
                        Ok({ val: inner, next: key_offset }) ->
                            when decode_str(buf, key_offset) is
                                Ok({ val: key, next }) ->
                                    Ok({ val: Property({ expr: inner, key }), next })
                                Err(OutOfBounds) -> Err(OutOfBounds)
                                Err(BadUtf8) -> Err(BadUtf8)
                        Err(e) -> Err(e)

                0x43 ->
                    when decode_expr(buf, data_start) is
                        Ok({ val: left, next: op_offset }) ->
                            when List.get(buf, op_offset) is
                                Err(_) -> Err(OutOfBounds)
                                Ok(op_byte) ->
                                    when decode_comp_op(op_byte) is
                                        Err(e) -> Err(e)
                                        Ok(op) ->
                                            when decode_expr(buf, op_offset + 1) is
                                                Ok({ val: right, next }) ->
                                                    Ok({ val: Comparison({ left, op, right }), next })
                                                Err(e) -> Err(e)
                        Err(e) -> Err(e)

                0x44 ->
                    when decode_expr(buf, data_start) is
                        Ok({ val: left, next: op_offset }) ->
                            when List.get(buf, op_offset) is
                                Err(_) -> Err(OutOfBounds)
                                Ok(op_byte) ->
                                    when decode_bool_logic(op_byte) is
                                        Err(e) -> Err(e)
                                        Ok(op) ->
                                            when decode_expr(buf, op_offset + 1) is
                                                Ok({ val: right, next }) ->
                                                    Ok({ val: BoolOp({ left, op, right }), next })
                                                Err(e) -> Err(e)
                        Err(e) -> Err(e)

                0x45 ->
                    when decode_expr(buf, data_start) is
                        Ok({ val: inner, next }) -> Ok({ val: Not(inner), next })
                        Err(e) -> Err(e)

                0x46 ->
                    when decode_expr(buf, data_start) is
                        Ok({ val: inner, next }) -> Ok({ val: IsNull(inner), next })
                        Err(e) -> Err(e)

                0x47 ->
                    when decode_expr(buf, data_start) is
                        Ok({ val: elem, next: list_offset }) ->
                            when decode_expr(buf, list_offset) is
                                Ok({ val: list, next }) ->
                                    Ok({ val: InList({ elem, list }), next })
                                Err(e) -> Err(e)
                        Err(e) -> Err(e)

                0x48 ->
                    when decode_str(buf, data_start) is
                        Ok({ val: name, next: count_offset }) ->
                            when decode_u16(buf, count_offset) is
                                Ok({ val: count, next: args_start }) ->
                                    decode_expr_list(buf, args_start, Num.int_cast(count))
                                    |> Result.map(|{ val: args, next }| { val: FnCall({ name, args }), next })
                                Err(e) -> Err(e)
                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8)

                _ -> Err(InvalidTag)

decode_expr_list : List U8, U64, U64 -> Result { val : List Expr, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_expr_list = |buf, offset, count|
    List.walk(
        List.range({ start: At(0u64), end: Before(count) }),
        Ok({ val: [], next: offset }),
        |acc_result, _|
            when acc_result is
                Err(e) -> Err(e)
                Ok(acc) ->
                    when decode_expr(buf, acc.next) is
                        Ok({ val: expr, next }) ->
                            Ok({ val: List.append(acc.val, expr), next })
                        Err(e) -> Err(e),
    )
```

- [ ] **Step 2: Write round-trip tests**

```roc
# ===== ExprCodec Tests =====

# Test: Literal Str round-trips
expect
    expr = Literal(Str("hello"))
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Literal(Str("hello")), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: Literal Integer round-trips
expect
    expr = Literal(Integer(42))
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Literal(Integer(42)), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: Literal True round-trips
expect
    expr = Literal(True)
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Literal(True), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: Literal Null round-trips
expect
    expr = Literal(Null)
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Literal(Null), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: Variable round-trips
expect
    expr = Variable("n")
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Variable("n"), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: Property round-trips
expect
    expr = Property({ expr: Variable("n"), key: "age" })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Property({ expr: Variable("n"), key: "age" }), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: Comparison round-trips
expect
    expr = Comparison({ left: Variable("x"), op: Gt, right: Literal(Integer(10)) })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Comparison({ left: Variable("x"), op: Gt, right: Literal(Integer(10)) }), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: BoolOp round-trips
expect
    expr = BoolOp({ left: Literal(True), op: And, right: Literal(False) })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: BoolOp({ left: Literal(True), op: And, right: Literal(False) }), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: Not round-trips
expect
    expr = Not(Literal(True))
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: Not(Literal(True)), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: IsNull round-trips
expect
    expr = IsNull(Variable("x"))
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: IsNull(Variable("x")), next }) -> next == List.len(bytes)
        _ -> Bool.false

# Test: Nested comparison — n.age > 25 AND n.active = true
expect
    expr = BoolOp({
        left: Comparison({ left: Property({ expr: Variable("n"), key: "age" }), op: Gt, right: Literal(Integer(25)) }),
        op: And,
        right: Comparison({ left: Property({ expr: Variable("n"), key: "active" }), op: Eq, right: Literal(True) }),
    })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: decoded, next }) ->
            next == List.len(bytes)
            && (when decoded is
                BoolOp({ op: And }) -> Bool.true
                _ -> Bool.false)
        _ -> Bool.false

# Test: FnCall with no args round-trips
expect
    expr = FnCall({ name: "id", args: [] })
    bytes = encode_expr(expr)
    when decode_expr(bytes, 0) is
        Ok({ val: FnCall({ name: "id", args }) }) -> List.is_empty(args)
        _ -> Bool.false

# Test: empty buffer → OutOfBounds
expect
    when decode_expr([], 0) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false

# Test: unknown tag → InvalidTag
expect
    when decode_expr([0xFF], 0) is
        Err(InvalidTag) -> Bool.true
        _ -> Bool.false

# Test: CompOp round-trips
expect
    ops = [Eq, Neq, Lt, Gt, Lte, Gte]
    List.all(ops, |op| decode_comp_op(encode_comp_op(op)) == Ok(op))

# Test: BoolLogic round-trips
expect
    ops = [And, Or]
    List.all(ops, |op| decode_bool_logic(encode_bool_logic(op)) == Ok(op))
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/cypher/ExprCodec.roc`
Expected: 16 passed, 0 failed

- [ ] **Step 4: Commit**

```bash
git add packages/cypher/ExprCodec.roc
git commit -m "C1.2: ExprCodec — encode/decode Expr trees to bytes"
```

---

### Task 5: Plan Codec (Roc)

**Files:**
- Create: `packages/cypher/PlanCodec.roc`

- [ ] **Step 1: Write the PlanCodec module**

```roc
module [
    encode_plan,
    decode_plan,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import expr.Expr exposing [Expr]
import Planner exposing [QueryPlan, PlanStep, ProjectItem]
import ExprCodec

# ===== Tags =====

tag_scan_seeds = 0x30
tag_traverse = 0x31
tag_filter = 0x32
tag_project = 0x33

proj_whole_node = 0x00
proj_node_property = 0x01

dir_outgoing = 0x00
dir_incoming = 0x01
dir_undirected = 0x02

label_unlabeled = 0x00
label_labeled = 0x01

type_untyped = 0x00
type_typed = 0x01

# ===== Primitive encoders (same as ExprCodec) =====

encode_u16 : U16 -> List U8
encode_u16 = |n|
    lo = Num.int_cast(Num.bitwise_and(n, 0xFF))
    hi = Num.int_cast(Num.shift_right_zf_by(n, 8))
    [lo, hi]

decode_u16 : List U8, U64 -> Result { val : U16, next : U64 } [OutOfBounds]
decode_u16 = |buf, offset|
    lo_result = List.get(buf, offset)
    hi_result = List.get(buf, offset + 1)
    when (lo_result, hi_result) is
        (Ok(lo), Ok(hi)) ->
            val : U16
            val = Num.int_cast(lo) |> Num.bitwise_or(Num.shift_left_by(Num.int_cast(hi), 8))
            Ok({ val, next: offset + 2 })
        _ -> Err(OutOfBounds)

encode_u32 : U32 -> List U8
encode_u32 = |n|
    List.range({ start: At(0), end: Before(4) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))

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

encode_str : Str -> List U8
encode_str = |s|
    bytes = Str.to_utf8(s)
    len : U16
    len = Num.int_cast(List.len(bytes))
    encode_u16(len) |> List.concat(bytes)

decode_str : List U8, U64 -> Result { val : Str, next : U64 } [OutOfBounds, BadUtf8]
decode_str = |buf, offset|
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: len_u16, next: data_start }) ->
            len = Num.int_cast(len_u16)
            extracted = List.sublist(buf, { start: data_start, len })
            if List.len(extracted) == len then
                when Str.from_utf8(extracted) is
                    Ok(s) -> Ok({ val: s, next: data_start + len })
                    Err(_) -> Err(BadUtf8)
            else
                Err(OutOfBounds)

# ===== Alias table =====

## Find the index of an alias in the alias list, or -1 if not found.
alias_index : List Str, Str -> U16
alias_index = |aliases, name|
    result = List.walk_until(
        aliases,
        { idx: 0u16, found: Bool.false },
        |acc, a|
            if a == name then
                Break({ idx: acc.idx, found: Bool.true })
            else
                Continue({ idx: acc.idx + 1, found: acc.found }),
    )
    result.idx

# ===== Encode =====

encode_plan : QueryPlan -> List U8
encode_plan = |qp|
    step_count : U16
    step_count = Num.int_cast(List.len(qp.steps))
    alias_count : U16
    alias_count = Num.int_cast(List.len(qp.aliases))

    buf = encode_u16(step_count)
        |> List.concat(encode_u16(alias_count))

    # Encode alias string table
    buf_with_aliases = List.walk(qp.aliases, buf, |acc, a|
        List.concat(acc, encode_str(a)))

    # Encode steps
    List.walk(qp.steps, buf_with_aliases, |acc, step|
        List.concat(acc, encode_step(step, qp.aliases)))

encode_step : PlanStep, List Str -> List U8
encode_step = |step, aliases|
    when step is
        ScanSeeds({ alias, node_ids, label, inline_props }) ->
            buf = [tag_scan_seeds]
                |> List.concat(encode_u16(alias_index(aliases, alias)))

            # Label
            buf_with_label = when label is
                Unlabeled -> List.append(buf, label_unlabeled)
                Labeled(lbl) ->
                    List.append(buf, label_labeled) |> List.concat(encode_str(lbl))

            # Inline props
            prop_count : U16
            prop_count = Num.int_cast(List.len(inline_props))
            buf_with_props = List.concat(buf_with_label, encode_u16(prop_count))
            buf_with_prop_data = List.walk(inline_props, buf_with_props, |acc, prop|
                acc
                |> List.concat(encode_str(prop.key))
                |> List.concat(ExprCodec.encode_quine_value(prop.value)))

            # Node IDs
            id_count : U16
            id_count = Num.int_cast(List.len(node_ids))
            buf_with_id_count = List.concat(buf_with_prop_data, encode_u16(id_count))
            List.walk(node_ids, buf_with_id_count, |acc, qid|
                List.concat(acc, QuineId.to_bytes(qid)))

        Traverse({ from_alias, to_alias, direction, edge_type, to_label }) ->
            buf = [tag_traverse]
                |> List.concat(encode_u16(alias_index(aliases, from_alias)))
                |> List.concat(encode_u16(alias_index(aliases, to_alias)))

            dir_byte = when direction is
                Outgoing -> dir_outgoing
                Incoming -> dir_incoming
                Undirected -> dir_undirected
            buf_with_dir = List.append(buf, dir_byte)

            buf_with_type = when edge_type is
                Untyped -> List.append(buf_with_dir, type_untyped)
                Typed(t) -> List.append(buf_with_dir, type_typed) |> List.concat(encode_str(t))

            when to_label is
                Unlabeled -> List.append(buf_with_type, label_unlabeled)
                Labeled(lbl) -> List.append(buf_with_type, label_labeled) |> List.concat(encode_str(lbl))

        Filter({ predicate }) ->
            expr_bytes = ExprCodec.encode_expr(predicate)
            len : U32
            len = Num.int_cast(List.len(expr_bytes))
            [tag_filter]
            |> List.concat(encode_u32(len))
            |> List.concat(expr_bytes)

        Project({ items }) ->
            item_count : U16
            item_count = Num.int_cast(List.len(items))
            buf = [tag_project] |> List.concat(encode_u16(item_count))
            List.walk(items, buf, |acc, item|
                List.concat(acc, encode_project_item(item, aliases)))

encode_project_item : ProjectItem, List Str -> List U8
encode_project_item = |item, aliases|
    when item is
        WholeNode(alias) ->
            [proj_whole_node] |> List.concat(encode_u16(alias_index(aliases, alias)))
        NodeProperty({ alias, prop, output_name }) ->
            [proj_node_property]
            |> List.concat(encode_u16(alias_index(aliases, alias)))
            |> List.concat(encode_str(prop))
            |> List.concat(encode_str(output_name))

# ===== Decode =====

decode_plan : List U8 -> Result QueryPlan [OutOfBounds, BadUtf8, InvalidTag]
decode_plan = |buf|
    when decode_u16(buf, 0) is
        Err(e) -> Err(e)
        Ok({ val: step_count_u16, next: alias_count_offset }) ->
            when decode_u16(buf, alias_count_offset) is
                Err(e) -> Err(e)
                Ok({ val: alias_count_u16, next: aliases_start }) ->
                    step_count = Num.int_cast(step_count_u16)
                    alias_count = Num.int_cast(alias_count_u16)

                    aliases_result = decode_str_list(buf, aliases_start, alias_count)
                    when aliases_result is
                        Err(e) -> Err(e)
                        Ok({ val: aliases, next: steps_start }) ->
                            steps_result = decode_step_list(buf, steps_start, step_count, aliases)
                            when steps_result is
                                Ok({ val: steps }) -> Ok({ steps, aliases })
                                Err(e) -> Err(e)

decode_str_list : List U8, U64, U64 -> Result { val : List Str, next : U64 } [OutOfBounds, BadUtf8]
decode_str_list = |buf, offset, count|
    List.walk(
        List.range({ start: At(0u64), end: Before(count) }),
        Ok({ val: [], next: offset }),
        |acc_result, _|
            when acc_result is
                Err(e) -> Err(e)
                Ok(acc) ->
                    when decode_str(buf, acc.next) is
                        Ok({ val: s, next }) ->
                            Ok({ val: List.append(acc.val, s), next })
                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8),
    )

decode_step_list : List U8, U64, U64, List Str -> Result { val : List PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_step_list = |buf, offset, count, aliases|
    List.walk(
        List.range({ start: At(0u64), end: Before(count) }),
        Ok({ val: [], next: offset }),
        |acc_result, _|
            when acc_result is
                Err(e) -> Err(e)
                Ok(acc) ->
                    when decode_step(buf, acc.next, aliases) is
                        Ok({ val: step, next }) ->
                            Ok({ val: List.append(acc.val, step), next })
                        Err(e) -> Err(e),
    )

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

lookup_alias : List Str, U16 -> Str
lookup_alias = |aliases, idx|
    when List.get(aliases, Num.int_cast(idx)) is
        Ok(a) -> a
        Err(_) -> "_unknown"

decode_scan_seeds : List U8, U64, List Str -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_scan_seeds = |buf, offset, aliases|
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: alias_idx, next: label_offset }) ->
            alias = lookup_alias(aliases, alias_idx)
            when List.get(buf, label_offset) is
                Err(_) -> Err(OutOfBounds)
                Ok(label_tag) ->
                    label_result = if label_tag == 0x01 then
                            when decode_str(buf, label_offset + 1) is
                                Ok({ val: lbl, next }) -> Ok({ val: Labeled(lbl), next })
                                Err(OutOfBounds) -> Err(OutOfBounds)
                                Err(BadUtf8) -> Err(BadUtf8)
                        else
                            Ok({ val: Unlabeled, next: label_offset + 1 })

                    when label_result is
                        Err(e) -> Err(e)
                        Ok({ val: label, next: props_offset }) ->
                            when decode_u16(buf, props_offset) is
                                Err(e) -> Err(e)
                                Ok({ val: prop_count_u16, next: props_start }) ->
                                    props_result = decode_inline_props(buf, props_start, Num.int_cast(prop_count_u16))
                                    when props_result is
                                        Err(e) -> Err(e)
                                        Ok({ val: inline_props, next: ids_offset }) ->
                                            when decode_u16(buf, ids_offset) is
                                                Err(e) -> Err(e)
                                                Ok({ val: id_count_u16, next: ids_start }) ->
                                                    ids_result = decode_node_ids(buf, ids_start, Num.int_cast(id_count_u16))
                                                    when ids_result is
                                                        Ok({ val: node_ids, next }) ->
                                                            Ok({ val: ScanSeeds({ alias, node_ids, label, inline_props }), next })
                                                        Err(e) -> Err(e)

decode_inline_props : List U8, U64, U64 -> Result { val : List { key : Str, value : QuineValue }, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_inline_props = |buf, offset, count|
    List.walk(
        List.range({ start: At(0u64), end: Before(count) }),
        Ok({ val: [], next: offset }),
        |acc_result, _|
            when acc_result is
                Err(e) -> Err(e)
                Ok(acc) ->
                    when decode_str(buf, acc.next) is
                        Ok({ val: key, next: val_offset }) ->
                            when ExprCodec.decode_quine_value(buf, val_offset) is
                                Ok({ val: value, next }) ->
                                    Ok({ val: List.append(acc.val, { key, value }), next })
                                Err(e) -> Err(e)
                        Err(OutOfBounds) -> Err(OutOfBounds)
                        Err(BadUtf8) -> Err(BadUtf8),
    )

decode_node_ids : List U8, U64, U64 -> Result { val : List QuineId, next : U64 } [OutOfBounds]
decode_node_ids = |buf, offset, count|
    List.walk(
        List.range({ start: At(0u64), end: Before(count) }),
        Ok({ val: [], next: offset }),
        |acc_result, _|
            when acc_result is
                Err(e) -> Err(e)
                Ok(acc) ->
                    qid_bytes = List.sublist(buf, { start: acc.next, len: 16 })
                    if List.len(qid_bytes) == 16 then
                        Ok({ val: List.append(acc.val, QuineId.from_bytes(qid_bytes)), next: acc.next + 16 })
                    else
                        Err(OutOfBounds),
    )

decode_traverse : List U8, U64, List Str -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_traverse = |buf, offset, aliases|
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: from_idx, next: to_offset }) ->
            when decode_u16(buf, to_offset) is
                Err(e) -> Err(e)
                Ok({ val: to_idx, next: dir_offset }) ->
                    when List.get(buf, dir_offset) is
                        Err(_) -> Err(OutOfBounds)
                        Ok(dir_byte) ->
                            direction = when dir_byte is
                                0x00 -> Outgoing
                                0x01 -> Incoming
                                _ -> Undirected
                            when List.get(buf, dir_offset + 1) is
                                Err(_) -> Err(OutOfBounds)
                                Ok(type_tag) ->
                                    type_result = if type_tag == 0x01 then
                                            when decode_str(buf, dir_offset + 2) is
                                                Ok({ val: t, next }) -> Ok({ val: Typed(t), next })
                                                Err(OutOfBounds) -> Err(OutOfBounds)
                                                Err(BadUtf8) -> Err(BadUtf8)
                                        else
                                            Ok({ val: Untyped, next: dir_offset + 2 })
                                    when type_result is
                                        Err(e) -> Err(e)
                                        Ok({ val: edge_type, next: label_offset }) ->
                                            when List.get(buf, label_offset) is
                                                Err(_) -> Err(OutOfBounds)
                                                Ok(lbl_tag) ->
                                                    label_result = if lbl_tag == 0x01 then
                                                            when decode_str(buf, label_offset + 1) is
                                                                Ok({ val: lbl, next }) -> Ok({ val: Labeled(lbl), next })
                                                                Err(OutOfBounds) -> Err(OutOfBounds)
                                                                Err(BadUtf8) -> Err(BadUtf8)
                                                        else
                                                            Ok({ val: Unlabeled, next: label_offset + 1 })
                                                    when label_result is
                                                        Ok({ val: to_label, next }) ->
                                                            Ok({
                                                                val: Traverse({
                                                                    from_alias: lookup_alias(aliases, from_idx),
                                                                    to_alias: lookup_alias(aliases, to_idx),
                                                                    direction,
                                                                    edge_type,
                                                                    to_label,
                                                                }),
                                                                next,
                                                            })
                                                        Err(e) -> Err(e)

decode_filter : List U8, U64 -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_filter = |buf, offset|
    when decode_u32(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: len_u32, next: expr_start }) ->
            expr_len = Num.int_cast(len_u32)
            when ExprCodec.decode_expr(buf, expr_start) is
                Ok({ val: predicate, next: _ }) ->
                    Ok({ val: Filter({ predicate }), next: expr_start + expr_len })
                Err(e) -> Err(e)

decode_project : List U8, U64, List Str -> Result { val : PlanStep, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_project = |buf, offset, aliases|
    when decode_u16(buf, offset) is
        Err(e) -> Err(e)
        Ok({ val: item_count_u16, next: items_start }) ->
            items_result = decode_project_items(buf, items_start, Num.int_cast(item_count_u16), aliases)
            when items_result is
                Ok({ val: items, next }) -> Ok({ val: Project({ items }), next })
                Err(e) -> Err(e)

decode_project_items : List U8, U64, U64, List Str -> Result { val : List ProjectItem, next : U64 } [OutOfBounds, BadUtf8, InvalidTag]
decode_project_items = |buf, offset, count, aliases|
    List.walk(
        List.range({ start: At(0u64), end: Before(count) }),
        Ok({ val: [], next: offset }),
        |acc_result, _|
            when acc_result is
                Err(e) -> Err(e)
                Ok(acc) ->
                    when List.get(buf, acc.next) is
                        Err(_) -> Err(OutOfBounds)
                        Ok(item_tag) ->
                            when item_tag is
                                0x00 ->
                                    when decode_u16(buf, acc.next + 1) is
                                        Ok({ val: idx, next }) ->
                                            Ok({ val: List.append(acc.val, WholeNode(lookup_alias(aliases, idx))), next })
                                        Err(e) -> Err(e)
                                0x01 ->
                                    when decode_u16(buf, acc.next + 1) is
                                        Ok({ val: idx, next: prop_offset }) ->
                                            when decode_str(buf, prop_offset) is
                                                Ok({ val: prop, next: out_offset }) ->
                                                    when decode_str(buf, out_offset) is
                                                        Ok({ val: output_name, next }) ->
                                                            Ok({ val: List.append(acc.val, NodeProperty({ alias: lookup_alias(aliases, idx), prop, output_name })), next })
                                                        Err(OutOfBounds) -> Err(OutOfBounds)
                                                        Err(BadUtf8) -> Err(BadUtf8)
                                                Err(OutOfBounds) -> Err(OutOfBounds)
                                                Err(BadUtf8) -> Err(BadUtf8)
                                        Err(e) -> Err(e)
                                _ -> Err(InvalidTag),
    )
```

- [ ] **Step 2: Write round-trip tests**

```roc
import id.QuineId exposing [QuineId]

# ===== PlanCodec Tests =====

seed : QuineId
seed = QuineId.from_bytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10])

# Test: single ScanSeeds + Project round-trips
expect
    qp : QueryPlan
    qp = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [seed], label: Unlabeled, inline_props: [] }),
            Project({ items: [WholeNode("n")] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(qp)
    when decode_plan(bytes) is
        Ok(decoded) ->
            List.len(decoded.steps) == 2
            && decoded.aliases == ["n"]
        Err(_) -> Bool.false

# Test: labeled ScanSeeds round-trips
expect
    qp : QueryPlan
    qp = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [seed], label: Labeled("Person"), inline_props: [] }),
            Project({ items: [WholeNode("n")] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(qp)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.first(decoded.steps) is
                Ok(ScanSeeds({ label: Labeled("Person") })) -> Bool.true
                _ -> Bool.false
        Err(_) -> Bool.false

# Test: ScanSeeds with inline props round-trips
expect
    qp : QueryPlan
    qp = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [], label: Unlabeled, inline_props: [{ key: "name", value: Str("Alice") }] }),
            Project({ items: [WholeNode("n")] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(qp)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.first(decoded.steps) is
                Ok(ScanSeeds({ inline_props })) -> List.len(inline_props) == 1
                _ -> Bool.false
        Err(_) -> Bool.false

# Test: Traverse round-trips
expect
    qp : QueryPlan
    qp = {
        steps: [
            ScanSeeds({ alias: "a", node_ids: [seed], label: Unlabeled, inline_props: [] }),
            Traverse({ from_alias: "a", to_alias: "b", direction: Outgoing, edge_type: Typed("KNOWS"), to_label: Unlabeled }),
            Project({ items: [WholeNode("a"), WholeNode("b")] }),
        ],
        aliases: ["a", "b"],
    }
    bytes = encode_plan(qp)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.get(decoded.steps, 1) is
                Ok(Traverse({ from_alias, to_alias, direction, edge_type })) ->
                    from_alias == "a" && to_alias == "b" && direction == Outgoing
                    && (when edge_type is
                        Typed("KNOWS") -> Bool.true
                        _ -> Bool.false)
                _ -> Bool.false
        Err(_) -> Bool.false

# Test: Filter round-trips
expect
    pred = Comparison({ left: Variable("x"), op: Gt, right: Literal(Integer(10)) })
    qp : QueryPlan
    qp = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [seed], label: Unlabeled, inline_props: [] }),
            Filter({ predicate: pred }),
            Project({ items: [WholeNode("n")] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(qp)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.get(decoded.steps, 1) is
                Ok(Filter(_)) -> Bool.true
                _ -> Bool.false
        Err(_) -> Bool.false

# Test: NodeProperty project item round-trips
expect
    qp : QueryPlan
    qp = {
        steps: [
            ScanSeeds({ alias: "n", node_ids: [seed], label: Unlabeled, inline_props: [] }),
            Project({ items: [NodeProperty({ alias: "n", prop: "name", output_name: "person_name" })] }),
        ],
        aliases: ["n"],
    }
    bytes = encode_plan(qp)
    when decode_plan(bytes) is
        Ok(decoded) ->
            when List.last(decoded.steps) is
                Ok(Project({ items })) ->
                    when List.first(items) is
                        Ok(NodeProperty({ prop, output_name })) ->
                            prop == "name" && output_name == "person_name"
                        _ -> Bool.false
                _ -> Bool.false
        Err(_) -> Bool.false

# Test: multi-hop plan round-trips
expect
    qp : QueryPlan
    qp = {
        steps: [
            ScanSeeds({ alias: "a", node_ids: [seed], label: Unlabeled, inline_props: [] }),
            Traverse({ from_alias: "a", to_alias: "b", direction: Outgoing, edge_type: Typed("KNOWS"), to_label: Unlabeled }),
            Traverse({ from_alias: "b", to_alias: "c", direction: Outgoing, edge_type: Typed("FOLLOWS"), to_label: Labeled("User") }),
            Project({ items: [NodeProperty({ alias: "a", prop: "name", output_name: "a.name" }), NodeProperty({ alias: "c", prop: "name", output_name: "c.name" })] }),
        ],
        aliases: ["a", "b", "c"],
    }
    bytes = encode_plan(qp)
    when decode_plan(bytes) is
        Ok(decoded) ->
            List.len(decoded.steps) == 4
            && decoded.aliases == ["a", "b", "c"]
        Err(_) -> Bool.false

# Test: empty buffer → error
expect
    when decode_plan([]) is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false
```

- [ ] **Step 3: Run tests**

Run: `roc test packages/cypher/PlanCodec.roc`
Expected: 8 passed, 0 failed

- [ ] **Step 4: Commit**

```bash
git add packages/cypher/PlanCodec.roc
git commit -m "C1.2: PlanCodec — encode/decode QueryPlan to bytes"
```

---

### Task 6: Rust Cypher Module — Expr Types and Decoder

**Files:**
- Create: `platform/src/cypher/mod.rs`
- Create: `platform/src/cypher/expr.rs`
- Modify: `platform/src/main.rs`

- [ ] **Step 1: Create module root and add to main.rs**

```rust
// platform/src/cypher/mod.rs
pub mod expr;
pub mod plan;
```

Add `mod cypher;` to `platform/src/main.rs` alongside other mod declarations.

- [ ] **Step 2: Create expr.rs with types and decoder**

```rust
// platform/src/cypher/expr.rs
//
// Rust-side Expr types and decoder, matching ExprCodec.roc.
// The executor holds Expr as opaque bytes and sends them back to Roc for
// evaluation. These types exist for debug/test round-trip verification.

// Expr tags
const TAG_LITERAL: u8 = 0x40;
const TAG_VARIABLE: u8 = 0x41;
const TAG_PROPERTY: u8 = 0x42;
const TAG_COMPARISON: u8 = 0x43;
const TAG_BOOL_OP: u8 = 0x44;
const TAG_NOT: u8 = 0x45;
const TAG_IS_NULL: u8 = 0x46;
const TAG_IN_LIST: u8 = 0x47;
const TAG_FN_CALL: u8 = 0x48;

// QuineValue tags
const QV_STR: u8 = 0x01;
const QV_INTEGER: u8 = 0x02;
const QV_TRUE: u8 = 0x04;
const QV_FALSE: u8 = 0x05;
const QV_NULL: u8 = 0x06;

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Literal(QuineValue),
    Variable(String),
    Property { expr: Box<Expr>, key: String },
    Comparison { left: Box<Expr>, op: CompOp, right: Box<Expr> },
    BoolOp { left: Box<Expr>, op: BoolLogic, right: Box<Expr> },
    Not(Box<Expr>),
    IsNull(Box<Expr>),
    InList { elem: Box<Expr>, list: Box<Expr> },
    FnCall { name: String, args: Vec<Expr> },
}

#[derive(Debug, Clone, PartialEq)]
pub enum QuineValue {
    Str(String),
    Integer(i64),
    True,
    False,
    Null,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CompOp { Eq, Neq, Lt, Gt, Lte, Gte }

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BoolLogic { And, Or }

#[derive(Debug)]
pub enum DecodeError {
    OutOfBounds,
    BadUtf8,
    InvalidTag(u8),
}

pub fn decode_expr(buf: &[u8], offset: usize) -> Result<(Expr, usize), DecodeError> {
    let tag = *buf.get(offset).ok_or(DecodeError::OutOfBounds)?;
    let data = offset + 1;
    match tag {
        TAG_LITERAL => {
            let (qv, next) = decode_quine_value(buf, data)?;
            Ok((Expr::Literal(qv), next))
        }
        TAG_VARIABLE => {
            let (name, next) = decode_string(buf, data)?;
            Ok((Expr::Variable(name), next))
        }
        TAG_PROPERTY => {
            let (inner, key_offset) = decode_expr(buf, data)?;
            let (key, next) = decode_string(buf, key_offset)?;
            Ok((Expr::Property { expr: Box::new(inner), key }, next))
        }
        TAG_COMPARISON => {
            let (left, op_offset) = decode_expr(buf, data)?;
            let op_byte = *buf.get(op_offset).ok_or(DecodeError::OutOfBounds)?;
            let op = decode_comp_op(op_byte)?;
            let (right, next) = decode_expr(buf, op_offset + 1)?;
            Ok((Expr::Comparison { left: Box::new(left), op, right: Box::new(right) }, next))
        }
        TAG_BOOL_OP => {
            let (left, op_offset) = decode_expr(buf, data)?;
            let op_byte = *buf.get(op_offset).ok_or(DecodeError::OutOfBounds)?;
            let op = decode_bool_logic(op_byte)?;
            let (right, next) = decode_expr(buf, op_offset + 1)?;
            Ok((Expr::BoolOp { left: Box::new(left), op, right: Box::new(right) }, next))
        }
        TAG_NOT => {
            let (inner, next) = decode_expr(buf, data)?;
            Ok((Expr::Not(Box::new(inner)), next))
        }
        TAG_IS_NULL => {
            let (inner, next) = decode_expr(buf, data)?;
            Ok((Expr::IsNull(Box::new(inner)), next))
        }
        TAG_IN_LIST => {
            let (elem, list_offset) = decode_expr(buf, data)?;
            let (list, next) = decode_expr(buf, list_offset)?;
            Ok((Expr::InList { elem: Box::new(elem), list: Box::new(list) }, next))
        }
        TAG_FN_CALL => {
            let (name, count_offset) = decode_string(buf, data)?;
            let count = decode_u16(buf, count_offset)?;
            let mut args = Vec::with_capacity(count as usize);
            let mut pos = count_offset + 2;
            for _ in 0..count {
                let (arg, next) = decode_expr(buf, pos)?;
                args.push(arg);
                pos = next;
            }
            Ok((Expr::FnCall { name, args }, pos))
        }
        _ => Err(DecodeError::InvalidTag(tag)),
    }
}

fn decode_comp_op(byte: u8) -> Result<CompOp, DecodeError> {
    match byte {
        0x00 => Ok(CompOp::Eq),
        0x01 => Ok(CompOp::Neq),
        0x02 => Ok(CompOp::Lt),
        0x03 => Ok(CompOp::Gt),
        0x04 => Ok(CompOp::Lte),
        0x05 => Ok(CompOp::Gte),
        _ => Err(DecodeError::InvalidTag(byte)),
    }
}

fn decode_bool_logic(byte: u8) -> Result<BoolLogic, DecodeError> {
    match byte {
        0x00 => Ok(BoolLogic::And),
        0x01 => Ok(BoolLogic::Or),
        _ => Err(DecodeError::InvalidTag(byte)),
    }
}

fn decode_quine_value(buf: &[u8], offset: usize) -> Result<(QuineValue, usize), DecodeError> {
    let tag = *buf.get(offset).ok_or(DecodeError::OutOfBounds)?;
    let data = offset + 1;
    match tag {
        QV_STR => {
            let (s, next) = decode_string(buf, data)?;
            Ok((QuineValue::Str(s), next))
        }
        QV_INTEGER => {
            let bits = decode_u64(buf, data)?;
            Ok((QuineValue::Integer(bits as i64), data + 8))
        }
        QV_TRUE => Ok((QuineValue::True, data)),
        QV_FALSE => Ok((QuineValue::False, data)),
        QV_NULL => Ok((QuineValue::Null, data)),
        _ => Err(DecodeError::InvalidTag(tag)),
    }
}

fn decode_u16(buf: &[u8], offset: usize) -> Result<u16, DecodeError> {
    let lo = *buf.get(offset).ok_or(DecodeError::OutOfBounds)? as u16;
    let hi = *buf.get(offset + 1).ok_or(DecodeError::OutOfBounds)? as u16;
    Ok(lo | (hi << 8))
}

fn decode_u32(buf: &[u8], offset: usize) -> Result<u32, DecodeError> {
    if offset + 4 > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let mut val = 0u32;
    for i in 0..4 {
        val |= (buf[offset + i] as u32) << (i * 8);
    }
    Ok(val)
}

fn decode_u64(buf: &[u8], offset: usize) -> Result<u64, DecodeError> {
    if offset + 8 > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let mut val = 0u64;
    for i in 0..8 {
        val |= (buf[offset + i] as u64) << (i * 8);
    }
    Ok(val)
}

fn decode_string(buf: &[u8], offset: usize) -> Result<(String, usize), DecodeError> {
    let len = decode_u16(buf, offset)? as usize;
    let start = offset + 2;
    let end = start + len;
    if end > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let s = std::str::from_utf8(&buf[start..end]).map_err(|_| DecodeError::BadUtf8)?;
    Ok((s.to_string(), end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_literal_str() {
        // tag_literal(0x40) + qv_str(0x01) + len(5):LE + "hello"
        let buf = [0x40, 0x01, 0x05, 0x00, b'h', b'e', b'l', b'l', b'o'];
        let (expr, next) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Literal(QuineValue::Str("hello".into())));
        assert_eq!(next, buf.len());
    }

    #[test]
    fn decode_literal_integer() {
        // tag_literal(0x40) + qv_integer(0x02) + 42i64 as u64 LE
        let mut buf = vec![0x40, 0x02];
        buf.extend_from_slice(&42u64.to_le_bytes());
        let (expr, _) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Literal(QuineValue::Integer(42)));
    }

    #[test]
    fn decode_literal_true() {
        let buf = [0x40, 0x04];
        let (expr, _) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Literal(QuineValue::True));
    }

    #[test]
    fn decode_literal_null() {
        let buf = [0x40, 0x06];
        let (expr, _) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Literal(QuineValue::Null));
    }

    #[test]
    fn decode_variable() {
        let buf = [0x41, 0x01, 0x00, b'n'];
        let (expr, _) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Variable("n".into()));
    }

    #[test]
    fn decode_comparison() {
        // x > 10: Comparison(Variable("x"), Gt, Literal(Integer(10)))
        let mut buf = vec![0x43]; // TAG_COMPARISON
        buf.extend_from_slice(&[0x41, 0x01, 0x00, b'x']); // Variable "x"
        buf.push(0x03); // Gt
        buf.push(0x40); // Literal
        buf.push(0x02); // Integer
        buf.extend_from_slice(&10u64.to_le_bytes());
        let (expr, _) = decode_expr(&buf, 0).unwrap();
        match expr {
            Expr::Comparison { op: CompOp::Gt, .. } => {}
            _ => panic!("expected Comparison Gt"),
        }
    }

    #[test]
    fn decode_not() {
        // NOT(true)
        let buf = [0x45, 0x40, 0x04];
        let (expr, _) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Not(Box::new(Expr::Literal(QuineValue::True))));
    }

    #[test]
    fn decode_empty_buffer_errors() {
        assert!(decode_expr(&[], 0).is_err());
    }

    #[test]
    fn decode_unknown_tag_errors() {
        assert!(matches!(decode_expr(&[0xFF], 0), Err(DecodeError::InvalidTag(0xFF))));
    }
}
```

- [ ] **Step 3: Build and run Rust tests**

Run: `cd platform && cargo test cypher`
Expected: 8 passed

- [ ] **Step 4: Commit**

```bash
git add platform/src/cypher/mod.rs platform/src/cypher/expr.rs platform/src/main.rs
git commit -m "C1.2: Rust Expr types and decoder, cypher module scaffold"
```

---

### Task 7: Rust QueryPlan Types and Decoder

**Files:**
- Create: `platform/src/cypher/plan.rs`

- [ ] **Step 1: Create plan.rs with types and decode_plan**

```rust
// platform/src/cypher/plan.rs
//
// Rust-side QueryPlan types and decoder, matching PlanCodec.roc.

use super::expr::{self, DecodeError, Expr};

// Step tags
const TAG_SCAN_SEEDS: u8 = 0x30;
const TAG_TRAVERSE: u8 = 0x31;
const TAG_FILTER: u8 = 0x32;
const TAG_PROJECT: u8 = 0x33;

// Project item tags
const PROJ_WHOLE_NODE: u8 = 0x00;
const PROJ_NODE_PROPERTY: u8 = 0x01;

#[derive(Debug, Clone, PartialEq)]
pub struct QueryPlan {
    pub steps: Vec<PlanStep>,
    pub aliases: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PlanStep {
    ScanSeeds {
        alias_idx: usize,
        label: Option<String>,
        inline_props: Vec<(String, expr::QuineValue)>,
        node_ids: Vec<[u8; 16]>,
    },
    Traverse {
        from_alias_idx: usize,
        to_alias_idx: usize,
        direction: Direction,
        edge_type: Option<String>,
        to_label: Option<String>,
    },
    Filter {
        expr_bytes: Vec<u8>,
    },
    Project {
        items: Vec<ProjectItem>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Direction {
    Outgoing,
    Incoming,
    Undirected,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ProjectItem {
    WholeNode(usize),
    NodeProperty {
        alias_idx: usize,
        prop: String,
        output_name: String,
    },
}

pub fn decode_plan(buf: &[u8]) -> Result<QueryPlan, DecodeError> {
    let step_count = decode_u16(buf, 0)? as usize;
    let alias_count = decode_u16(buf, 2)? as usize;

    let mut pos = 4;
    let mut aliases = Vec::with_capacity(alias_count);
    for _ in 0..alias_count {
        let (s, next) = decode_string(buf, pos)?;
        aliases.push(s);
        pos = next;
    }

    let mut steps = Vec::with_capacity(step_count);
    for _ in 0..step_count {
        let (step, next) = decode_step(buf, pos)?;
        steps.push(step);
        pos = next;
    }

    Ok(QueryPlan { steps, aliases })
}

fn decode_step(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    let tag = *buf.get(offset).ok_or(DecodeError::OutOfBounds)?;
    let data = offset + 1;
    match tag {
        TAG_SCAN_SEEDS => decode_scan_seeds(buf, data),
        TAG_TRAVERSE => decode_traverse(buf, data),
        TAG_FILTER => decode_filter(buf, data),
        TAG_PROJECT => decode_project(buf, data),
        _ => Err(DecodeError::InvalidTag(tag)),
    }
}

fn decode_scan_seeds(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    let alias_idx = decode_u16(buf, offset)? as usize;
    let mut pos = offset + 2;

    // Label
    let label_tag = *buf.get(pos).ok_or(DecodeError::OutOfBounds)?;
    pos += 1;
    let label = if label_tag == 0x01 {
        let (s, next) = decode_string(buf, pos)?;
        pos = next;
        Some(s)
    } else {
        None
    };

    // Inline props
    let prop_count = decode_u16(buf, pos)? as usize;
    pos += 2;
    let mut inline_props = Vec::with_capacity(prop_count);
    for _ in 0..prop_count {
        let (key, key_end) = decode_string(buf, pos)?;
        let (val, val_end) = expr::decode_quine_value_from_buf(buf, key_end)?;
        inline_props.push((key, val));
        pos = val_end;
    }

    // Node IDs
    let id_count = decode_u16(buf, pos)? as usize;
    pos += 2;
    let mut node_ids = Vec::with_capacity(id_count);
    for _ in 0..id_count {
        if pos + 16 > buf.len() {
            return Err(DecodeError::OutOfBounds);
        }
        let mut qid = [0u8; 16];
        qid.copy_from_slice(&buf[pos..pos + 16]);
        node_ids.push(qid);
        pos += 16;
    }

    Ok((PlanStep::ScanSeeds { alias_idx, label, inline_props, node_ids }, pos))
}

fn decode_traverse(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    let from_alias_idx = decode_u16(buf, offset)? as usize;
    let to_alias_idx = decode_u16(buf, offset + 2)? as usize;
    let mut pos = offset + 4;

    let dir_byte = *buf.get(pos).ok_or(DecodeError::OutOfBounds)?;
    let direction = match dir_byte {
        0x00 => Direction::Outgoing,
        0x01 => Direction::Incoming,
        _ => Direction::Undirected,
    };
    pos += 1;

    let type_tag = *buf.get(pos).ok_or(DecodeError::OutOfBounds)?;
    pos += 1;
    let edge_type = if type_tag == 0x01 {
        let (s, next) = decode_string(buf, pos)?;
        pos = next;
        Some(s)
    } else {
        None
    };

    let label_tag = *buf.get(pos).ok_or(DecodeError::OutOfBounds)?;
    pos += 1;
    let to_label = if label_tag == 0x01 {
        let (s, next) = decode_string(buf, pos)?;
        pos = next;
        Some(s)
    } else {
        None
    };

    Ok((PlanStep::Traverse { from_alias_idx, to_alias_idx, direction, edge_type, to_label }, pos))
}

fn decode_filter(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    let len = decode_u32(buf, offset)? as usize;
    let expr_start = offset + 4;
    let expr_end = expr_start + len;
    if expr_end > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let expr_bytes = buf[expr_start..expr_end].to_vec();
    Ok((PlanStep::Filter { expr_bytes }, expr_end))
}

fn decode_project(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    let item_count = decode_u16(buf, offset)? as usize;
    let mut pos = offset + 2;
    let mut items = Vec::with_capacity(item_count);
    for _ in 0..item_count {
        let item_tag = *buf.get(pos).ok_or(DecodeError::OutOfBounds)?;
        pos += 1;
        match item_tag {
            PROJ_WHOLE_NODE => {
                let idx = decode_u16(buf, pos)? as usize;
                pos += 2;
                items.push(ProjectItem::WholeNode(idx));
            }
            PROJ_NODE_PROPERTY => {
                let idx = decode_u16(buf, pos)? as usize;
                pos += 2;
                let (prop, prop_end) = decode_string(buf, pos)?;
                let (output_name, next) = decode_string(buf, prop_end)?;
                pos = next;
                items.push(ProjectItem::NodeProperty { alias_idx: idx, prop, output_name });
            }
            _ => return Err(DecodeError::InvalidTag(item_tag)),
        }
    }
    Ok((PlanStep::Project { items }, pos))
}

fn decode_u16(buf: &[u8], offset: usize) -> Result<u16, DecodeError> {
    let lo = *buf.get(offset).ok_or(DecodeError::OutOfBounds)? as u16;
    let hi = *buf.get(offset + 1).ok_or(DecodeError::OutOfBounds)? as u16;
    Ok(lo | (hi << 8))
}

fn decode_u32(buf: &[u8], offset: usize) -> Result<u32, DecodeError> {
    if offset + 4 > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let mut val = 0u32;
    for i in 0..4 {
        val |= (buf[offset + i] as u32) << (i * 8);
    }
    Ok(val)
}

fn decode_string(buf: &[u8], offset: usize) -> Result<(String, usize), DecodeError> {
    let len = decode_u16(buf, offset)? as usize;
    let start = offset + 2;
    let end = start + len;
    if end > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let s = std::str::from_utf8(&buf[start..end]).map_err(|_| DecodeError::BadUtf8)?;
    Ok((s.to_string(), end))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: build a minimal plan buffer by hand.
    /// Plan: 1 step (ScanSeeds alias_idx=0, unlabeled, 0 props, 1 node_id)
    ///       1 alias ("n")
    fn minimal_scan_plan() -> Vec<u8> {
        let mut buf = Vec::new();
        // step_count=1
        buf.extend_from_slice(&1u16.to_le_bytes());
        // alias_count=1
        buf.extend_from_slice(&1u16.to_le_bytes());
        // alias "n"
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.push(b'n');
        // ScanSeeds tag
        buf.push(TAG_SCAN_SEEDS);
        // alias_idx=0
        buf.extend_from_slice(&0u16.to_le_bytes());
        // label=Unlabeled
        buf.push(0x00);
        // inline_prop_count=0
        buf.extend_from_slice(&0u16.to_le_bytes());
        // node_id_count=1
        buf.extend_from_slice(&1u16.to_le_bytes());
        // 16-byte QID
        buf.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
        buf
    }

    #[test]
    fn decode_minimal_scan() {
        let buf = minimal_scan_plan();
        let plan = decode_plan(&buf).unwrap();
        assert_eq!(plan.aliases, vec!["n"]);
        assert_eq!(plan.steps.len(), 1);
        match &plan.steps[0] {
            PlanStep::ScanSeeds { alias_idx, label, node_ids, .. } => {
                assert_eq!(*alias_idx, 0);
                assert!(label.is_none());
                assert_eq!(node_ids.len(), 1);
            }
            _ => panic!("expected ScanSeeds"),
        }
    }

    #[test]
    fn decode_traverse_step() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&1u16.to_le_bytes()); // step_count=1
        buf.extend_from_slice(&2u16.to_le_bytes()); // alias_count=2
        // aliases
        buf.extend_from_slice(&1u16.to_le_bytes()); buf.push(b'a');
        buf.extend_from_slice(&1u16.to_le_bytes()); buf.push(b'b');
        // Traverse tag
        buf.push(TAG_TRAVERSE);
        buf.extend_from_slice(&0u16.to_le_bytes()); // from_alias_idx=0
        buf.extend_from_slice(&1u16.to_le_bytes()); // to_alias_idx=1
        buf.push(0x00); // Outgoing
        buf.push(0x01); // Typed
        buf.extend_from_slice(&5u16.to_le_bytes()); // "KNOWS"
        buf.extend_from_slice(b"KNOWS");
        buf.push(0x00); // to_label=Unlabeled

        let plan = decode_plan(&buf).unwrap();
        match &plan.steps[0] {
            PlanStep::Traverse { from_alias_idx, to_alias_idx, direction, edge_type, to_label } => {
                assert_eq!(*from_alias_idx, 0);
                assert_eq!(*to_alias_idx, 1);
                assert_eq!(*direction, Direction::Outgoing);
                assert_eq!(edge_type.as_deref(), Some("KNOWS"));
                assert!(to_label.is_none());
            }
            _ => panic!("expected Traverse"),
        }
    }

    #[test]
    fn decode_filter_step() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&1u16.to_le_bytes()); // step_count=1
        buf.extend_from_slice(&0u16.to_le_bytes()); // alias_count=0
        // Filter tag
        buf.push(TAG_FILTER);
        // Expr bytes: Literal(Null) = [0x40, 0x06]
        let expr = [0x40u8, 0x06];
        buf.extend_from_slice(&(expr.len() as u32).to_le_bytes());
        buf.extend_from_slice(&expr);

        let plan = decode_plan(&buf).unwrap();
        match &plan.steps[0] {
            PlanStep::Filter { expr_bytes } => {
                assert_eq!(expr_bytes, &[0x40, 0x06]);
            }
            _ => panic!("expected Filter"),
        }
    }

    #[test]
    fn decode_project_whole_node() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&1u16.to_le_bytes()); // step_count=1
        buf.extend_from_slice(&1u16.to_le_bytes()); // alias_count=1
        buf.extend_from_slice(&1u16.to_le_bytes()); buf.push(b'n');
        // Project tag
        buf.push(TAG_PROJECT);
        buf.extend_from_slice(&1u16.to_le_bytes()); // item_count=1
        buf.push(PROJ_WHOLE_NODE);
        buf.extend_from_slice(&0u16.to_le_bytes()); // alias_idx=0

        let plan = decode_plan(&buf).unwrap();
        match &plan.steps[0] {
            PlanStep::Project { items } => {
                assert_eq!(items, &[ProjectItem::WholeNode(0)]);
            }
            _ => panic!("expected Project"),
        }
    }

    #[test]
    fn decode_project_node_property() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.extend_from_slice(&1u16.to_le_bytes()); buf.push(b'n');
        buf.push(TAG_PROJECT);
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.push(PROJ_NODE_PROPERTY);
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&4u16.to_le_bytes()); buf.extend_from_slice(b"name");
        buf.extend_from_slice(&6u16.to_le_bytes()); buf.extend_from_slice(b"n.name");

        let plan = decode_plan(&buf).unwrap();
        match &plan.steps[0] {
            PlanStep::Project { items } => {
                assert_eq!(items[0], ProjectItem::NodeProperty {
                    alias_idx: 0, prop: "name".into(), output_name: "n.name".into()
                });
            }
            _ => panic!("expected Project"),
        }
    }

    #[test]
    fn decode_empty_buffer_errors() {
        assert!(decode_plan(&[]).is_err());
    }

    #[test]
    fn decode_unknown_step_tag_errors() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.push(0xFF);
        assert!(decode_plan(&buf).is_err());
    }
}
```

- [ ] **Step 2: Add decode_quine_value_from_buf to expr.rs**

The plan decoder needs to decode inline QuineValues. Add this public function to `expr.rs`:

```rust
/// Decode a QuineValue from a buffer at an offset.
/// Used by plan.rs to decode inline property values in ScanSeeds.
pub fn decode_quine_value_from_buf(buf: &[u8], offset: usize) -> Result<(QuineValue, usize), DecodeError> {
    decode_quine_value(buf, offset)
}
```

Make `decode_quine_value` accessible by adding the pub wrapper (the existing function stays private).

- [ ] **Step 3: Build and run all Rust tests**

Run: `cd platform && cargo test cypher`
Expected: All tests pass (8 expr + 7 plan = 15)

- [ ] **Step 4: Commit**

```bash
git add platform/src/cypher/plan.rs platform/src/cypher/expr.rs
git commit -m "C1.2: Rust QueryPlan types and decoder"
```

---

### Task 8: Full Integration Check

**Files:** No new files — verification only.

- [ ] **Step 1: Run all Roc cypher tests**

Run: `roc test packages/cypher/Planner.roc && roc test packages/cypher/ExprCodec.roc && roc test packages/cypher/PlanCodec.roc`
Expected: All pass

- [ ] **Step 2: Run Roc check on entire package**

Run: `roc check packages/cypher/main.roc`
Expected: 0 errors

- [ ] **Step 3: Run all Rust tests**

Run: `cd platform && cargo test`
Expected: All pass (including new cypher tests)

- [ ] **Step 4: Run existing Roc tests to check for regressions**

Run: `roc test packages/expr/Expr.roc && roc test packages/cypher/Lexer.roc && roc test packages/cypher/Parser.roc`
Expected: All pass

- [ ] **Step 5: Commit any fixes**

If any tests needed fixes, commit them:
```bash
git add -u
git commit -m "C1.2: fix integration issues"
```

- [ ] **Step 6: Close beads issue**

```bash
bd close qr-1fz --reason="Planner, ExprCodec, PlanCodec in Roc + Rust decoders. All tests pass."
```
