module [
    Expr,
    CompOp,
    BoolLogic,
    ExprContext,
    eval,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]

## A Cypher-like expression AST for FilterMap evaluation.
##
## Covers the subset needed by Phase 4 standing query FilterMap:
## literals, variable lookup, property access, comparisons,
## boolean logic, null checks, list membership, and built-in functions.
Expr : [
    Literal QuineValue,
    Variable Str,
    Property { expr : Expr, key : Str },
    Comparison { left : Expr, op : CompOp, right : Expr },
    BoolOp { left : Expr, op : BoolLogic, right : Expr },
    Not Expr,
    IsNull Expr,
    InList { elem : Expr, list : Expr },
    FnCall { name : Str, args : List Expr },
]

## Comparison operators.
CompOp : [Eq, Neq, Lt, Gt, Lte, Gte]

## Binary boolean logic operators.
BoolLogic : [And, Or]

## A row of named values — the query result context.
##
## Same structure as StandingQueryResult's QueryContext.
QueryContext : Dict Str QuineValue

## Node-level context passed alongside the query context during evaluation.
ExprContext : {
    node_id : QuineId,
    labels_property_key : Str,
    properties : Dict Str PropertyValue,
}

## Evaluate an expression against a query context and node context.
##
## Returns Ok(QuineValue) on success, Err(EvalError msg) on type/semantic errors.
## Variable lookups that find no binding return Ok(Null) — Cypher semantics.
eval : Expr, QueryContext, ExprContext -> Result QuineValue [EvalError Str]
eval = |expr, query_ctx, expr_ctx|
    when expr is
        Literal(value) ->
            Ok(value)

        Variable(name) ->
            when Dict.get(query_ctx, name) is
                Ok(value) -> Ok(value)
                Err(_) -> Ok(Null)

        Property({ expr: inner, key }) ->
            inner_val = eval(inner, query_ctx, expr_ctx)?
            when inner_val is
                Map(m) ->
                    when Dict.get(m, key) is
                        Ok(v) -> Ok(v)
                        Err(_) -> Ok(Null)
                _ -> Ok(Null)

        Comparison({ left, op, right }) ->
            lv = eval(left, query_ctx, expr_ctx)?
            rv = eval(right, query_ctx, expr_ctx)?
            eval_comparison(lv, op, rv)

        BoolOp({ left, op, right }) ->
            lv = eval(left, query_ctx, expr_ctx)?
            rv = eval(right, query_ctx, expr_ctx)?
            eval_bool_op(lv, op, rv)

        Not(inner) ->
            inner_val = eval(inner, query_ctx, expr_ctx)?
            when inner_val is
                True -> Ok(False)
                False -> Ok(True)
                Null -> Ok(Null)
                _ -> Err(EvalError("NOT requires a boolean or null value"))

        IsNull(inner) ->
            inner_val = eval(inner, query_ctx, expr_ctx)?
            when inner_val is
                Null -> Ok(True)
                _ -> Ok(False)

        InList({ elem, list }) ->
            elem_val = eval(elem, query_ctx, expr_ctx)?
            list_val = eval(list, query_ctx, expr_ctx)?
            when list_val is
                Null -> Ok(Null)
                List(items) ->
                    found = List.any(items, |item| quine_value_eq(item, elem_val))
                    if found then Ok(True) else Ok(False)
                _ -> Err(EvalError("IN requires a list on the right-hand side"))

        FnCall({ name, args }) ->
            eval_fn_call(name, args, query_ctx, expr_ctx)

## Evaluate a comparison between two QuineValues.
##
## Null on either side short-circuits to Null (SQL null semantics).
## Ordered comparisons (Lt/Gt/Lte/Gte) are supported for Integer and Floating.
## Strings support only Eq/Neq in Phase 4.
eval_comparison : QuineValue, CompOp, QuineValue -> Result QuineValue [EvalError Str]
eval_comparison = |lv, op, rv|
    when (lv, rv) is
        (Null, _) -> Ok(Null)
        (_, Null) -> Ok(Null)
        _ ->
            when op is
                Eq ->
                    if quine_value_eq(lv, rv) then Ok(True) else Ok(False)

                Neq ->
                    if quine_value_eq(lv, rv) then Ok(False) else Ok(True)

                Lt ->
                    when (lv, rv) is
                        (Integer(a), Integer(b)) ->
                            if a < b then Ok(True) else Ok(False)
                        (Floating(a), Floating(b)) ->
                            when Num.compare(a, b) is
                                LT -> Ok(True)
                                _ -> Ok(False)
                        _ -> Err(EvalError("< requires two integers or two floats"))

                Gt ->
                    when (lv, rv) is
                        (Integer(a), Integer(b)) ->
                            if a > b then Ok(True) else Ok(False)
                        (Floating(a), Floating(b)) ->
                            when Num.compare(a, b) is
                                GT -> Ok(True)
                                _ -> Ok(False)
                        _ -> Err(EvalError("> requires two integers or two floats"))

                Lte ->
                    when (lv, rv) is
                        (Integer(a), Integer(b)) ->
                            if a <= b then Ok(True) else Ok(False)
                        (Floating(a), Floating(b)) ->
                            when Num.compare(a, b) is
                                GT -> Ok(False)
                                _ -> Ok(True)
                        _ -> Err(EvalError("<= requires two integers or two floats"))

                Gte ->
                    when (lv, rv) is
                        (Integer(a), Integer(b)) ->
                            if a >= b then Ok(True) else Ok(False)
                        (Floating(a), Floating(b)) ->
                            when Num.compare(a, b) is
                                LT -> Ok(False)
                                _ -> Ok(True)
                        _ -> Err(EvalError(">= requires two integers or two floats"))

## Evaluate a boolean binary operation using three-valued (Kleene) logic.
##
## And: True∧True=True, True∧False=False, True∧Null=Null,
##      False∧anything=False, Null∧False=False, Null∧Null=Null
## Or:  True∨anything=True, False∨False=False, False∨Null=Null,
##      Null∨True=True, Null∨Null=Null
eval_bool_op : QuineValue, BoolLogic, QuineValue -> Result QuineValue [EvalError Str]
eval_bool_op = |lv, op, rv|
    when op is
        And ->
            when (lv, rv) is
                (False, _) -> Ok(False)
                (_, False) -> Ok(False)
                (True, True) -> Ok(True)
                (True, Null) -> Ok(Null)
                (Null, True) -> Ok(Null)
                (Null, Null) -> Ok(Null)
                _ -> Err(EvalError("AND requires boolean or null operands"))

        Or ->
            when (lv, rv) is
                (True, _) -> Ok(True)
                (_, True) -> Ok(True)
                (False, False) -> Ok(False)
                (False, Null) -> Ok(Null)
                (Null, False) -> Ok(Null)
                (Null, Null) -> Ok(Null)
                _ -> Err(EvalError("OR requires boolean or null operands"))

## Evaluate a built-in function call.
##
## Supported functions:
## - "id" (0 args): returns the node's ID as a Bytes value
## - "labels" (0 args): returns the labels property value, or an empty list
## Unknown function names return EvalError.
eval_fn_call : Str, List Expr, QueryContext, ExprContext -> Result QuineValue [EvalError Str]
eval_fn_call = |name, args, _query_ctx, expr_ctx|
    when name is
        "id" ->
            if List.len(args) != 0 then
                Err(EvalError("id() takes no arguments"))
            else
                Ok(Bytes(QuineId.to_bytes(expr_ctx.node_id)))

        "labels" ->
            if List.len(args) != 0 then
                Err(EvalError("labels() takes no arguments"))
            else
                when Dict.get(expr_ctx.properties, expr_ctx.labels_property_key) is
                    Ok(pv) ->
                        when PropertyValue.get_value(pv) is
                            Ok(v) -> Ok(v)
                            Err(_) -> Ok(List([]))
                    Err(_) -> Ok(List([]))

        _ ->
            Err(EvalError("Unknown function: $(name)"))

## Structural equality for QuineValue.
##
## Needed because Eq may not be derivable across package boundaries
## for recursive types containing opaque types (like QuineId).
quine_value_eq : QuineValue, QuineValue -> Bool
quine_value_eq = |a, b|
    when (a, b) is
        (Str(x), Str(y)) -> x == y
        (Integer(x), Integer(y)) -> x == y
        (Floating(x), Floating(y)) ->
            Num.is_approx_eq(x, y, { rtol: 0.0, atol: 0.0 })
        (True, True) -> Bool.true
        (False, False) -> Bool.true
        (Null, Null) -> Bool.true
        (Bytes(x), Bytes(y)) -> x == y
        (Id(x), Id(y)) ->
            QuineId.to_bytes(x) == QuineId.to_bytes(y)
        (List(xs), List(ys)) ->
            List.len(xs) == List.len(ys)
            && List.walk_until(
                List.map2(xs, ys, |x, y| (x, y)),
                Bool.true,
                |_, (x, y)|
                    if quine_value_eq(x, y) then
                        Continue(Bool.true)
                    else
                        Break(Bool.false),
            )
        (Map(xm), Map(ym)) ->
            Dict.len(xm) == Dict.len(ym)
            && Dict.walk_until(
                xm,
                Bool.true,
                |_, k, xv|
                    when Dict.get(ym, k) is
                        Ok(yv) ->
                            if quine_value_eq(xv, yv) then
                                Continue(Bool.true)
                            else
                                Break(Bool.false)
                        Err(_) -> Break(Bool.false),
            )
        _ -> Bool.false

# ===== Test helpers =====

make_ctx : ExprContext
make_ctx = {
    node_id: QuineId.from_bytes([0x01, 0x02]),
    labels_property_key: "__labels",
    properties: Dict.empty({}),
}

empty_qctx : QueryContext
empty_qctx = Dict.empty({})

# ===== Tests =====

# Test 1: Literal Str evaluates to itself
expect
    when eval(Literal(Str("hello")), empty_qctx, make_ctx) is
        Ok(Str("hello")) -> Bool.true
        _ -> Bool.false

# Test 2: Literal Integer evaluates to itself
expect
    when eval(Literal(Integer(42)), empty_qctx, make_ctx) is
        Ok(Integer(42)) -> Bool.true
        _ -> Bool.false

# Test 3: Literal Null evaluates to Null
expect
    when eval(Literal(Null), empty_qctx, make_ctx) is
        Ok(Null) -> Bool.true
        _ -> Bool.false

# Test 4: Variable present → its value
expect
    qctx = Dict.insert(empty_qctx, "x", Integer(99))
    when eval(Variable("x"), qctx, make_ctx) is
        Ok(Integer(99)) -> Bool.true
        _ -> Bool.false

# Test 5: Variable missing → Null
expect
    when eval(Variable("missing"), empty_qctx, make_ctx) is
        Ok(Null) -> Bool.true
        _ -> Bool.false

# Test 6: Property on Map → value
expect
    m = Dict.insert(Dict.empty({}), "name", Str("Alice"))
    qctx = Dict.insert(empty_qctx, "n", Map(m))
    when eval(Property({ expr: Variable("n"), key: "name" }), qctx, make_ctx) is
        Ok(Str("Alice")) -> Bool.true
        _ -> Bool.false

# Test 7: Property on Map missing key → Null
expect
    m = Dict.insert(Dict.empty({}), "name", Str("Alice"))
    qctx = Dict.insert(empty_qctx, "n", Map(m))
    when eval(Property({ expr: Variable("n"), key: "age" }), qctx, make_ctx) is
        Ok(Null) -> Bool.true
        _ -> Bool.false

# Test 8: Property on non-Map → Null
expect
    qctx = Dict.insert(empty_qctx, "n", Integer(42))
    when eval(Property({ expr: Variable("n"), key: "name" }), qctx, make_ctx) is
        Ok(Null) -> Bool.true
        _ -> Bool.false

# Test 9: Comparison Eq equal → True
expect
    when eval(
        Comparison({ left: Literal(Integer(5)), op: Eq, right: Literal(Integer(5)) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 10: Comparison Eq unequal → False
expect
    when eval(
        Comparison({ left: Literal(Integer(5)), op: Eq, right: Literal(Integer(6)) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(False) -> Bool.true
        _ -> Bool.false

# Test 11: Comparison Neq → opposite of Eq
expect
    when eval(
        Comparison({ left: Literal(Integer(5)), op: Neq, right: Literal(Integer(6)) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 12: Comparison Lt integers → correct
expect
    when eval(
        Comparison({ left: Literal(Integer(3)), op: Lt, right: Literal(Integer(5)) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 13: Comparison Gt integers → correct
expect
    when eval(
        Comparison({ left: Literal(Integer(5)), op: Gt, right: Literal(Integer(3)) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 14: Comparison with Null → Null
expect
    when eval(
        Comparison({ left: Literal(Null), op: Eq, right: Literal(Integer(5)) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(Null) -> Bool.true
        _ -> Bool.false

# Test 15: BoolOp And True True → True
expect
    when eval(
        BoolOp({ left: Literal(True), op: And, right: Literal(True) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 16: BoolOp And True False → False
expect
    when eval(
        BoolOp({ left: Literal(True), op: And, right: Literal(False) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(False) -> Bool.true
        _ -> Bool.false

# Test 17: BoolOp And False Null → False (short-circuit)
expect
    when eval(
        BoolOp({ left: Literal(False), op: And, right: Literal(Null) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(False) -> Bool.true
        _ -> Bool.false

# Test 18: BoolOp Or False True → True
expect
    when eval(
        BoolOp({ left: Literal(False), op: Or, right: Literal(True) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 19: BoolOp Or False Null → Null
expect
    when eval(
        BoolOp({ left: Literal(False), op: Or, right: Literal(Null) }),
        empty_qctx,
        make_ctx,
    ) is
        Ok(Null) -> Bool.true
        _ -> Bool.false

# Test 20: Not True → False
expect
    when eval(Not(Literal(True)), empty_qctx, make_ctx) is
        Ok(False) -> Bool.true
        _ -> Bool.false

# Test 21: Not False → True
expect
    when eval(Not(Literal(False)), empty_qctx, make_ctx) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 22: Not Null → Null
expect
    when eval(Not(Literal(Null)), empty_qctx, make_ctx) is
        Ok(Null) -> Bool.true
        _ -> Bool.false

# Test 23: IsNull Null → True
expect
    when eval(IsNull(Literal(Null)), empty_qctx, make_ctx) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 24: IsNull non-null → False
expect
    when eval(IsNull(Literal(Integer(0))), empty_qctx, make_ctx) is
        Ok(False) -> Bool.true
        _ -> Bool.false

# Test 25: InList present → True
expect
    list_expr = Literal(List([Integer(1), Integer(2), Integer(3)]))
    when eval(InList({ elem: Literal(Integer(2)), list: list_expr }), empty_qctx, make_ctx) is
        Ok(True) -> Bool.true
        _ -> Bool.false

# Test 26: InList absent → False
expect
    list_expr = Literal(List([Integer(1), Integer(2), Integer(3)]))
    when eval(InList({ elem: Literal(Integer(99)), list: list_expr }), empty_qctx, make_ctx) is
        Ok(False) -> Bool.true
        _ -> Bool.false

# Test 27: InList on Null → Null
expect
    when eval(InList({ elem: Literal(Integer(1)), list: Literal(Null) }), empty_qctx, make_ctx) is
        Ok(Null) -> Bool.true
        _ -> Bool.false

# Test 28: FnCall "id" → node ID as bytes
expect
    ctx = {
        node_id: QuineId.from_bytes([0xab, 0xcd]),
        labels_property_key: "__labels",
        properties: Dict.empty({}),
    }
    when eval(FnCall({ name: "id", args: [] }), empty_qctx, ctx) is
        Ok(Bytes([0xab, 0xcd])) -> Bool.true
        _ -> Bool.false

# Test 29: FnCall "labels" with property → labels value
expect
    pv = PropertyValue.from_value(List([Str("Person"), Str("Actor")]))
    props = Dict.insert(Dict.empty({}), "__labels", pv)
    ctx = {
        node_id: QuineId.from_bytes([0x01]),
        labels_property_key: "__labels",
        properties: props,
    }
    when eval(FnCall({ name: "labels", args: [] }), empty_qctx, ctx) is
        Ok(List([Str("Person"), Str("Actor")])) -> Bool.true
        _ -> Bool.false

# Test 30: FnCall "labels" without property → empty list
expect
    when eval(FnCall({ name: "labels", args: [] }), empty_qctx, make_ctx) is
        Ok(List([])) -> Bool.true
        _ -> Bool.false

# Test 31: FnCall unknown → EvalError
expect
    when eval(FnCall({ name: "no_such_fn", args: [] }), empty_qctx, make_ctx) is
        Err(EvalError(_)) -> Bool.true
        _ -> Bool.false
