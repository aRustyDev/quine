module [
    on_initialize,
    on_subscription_result,
    read_results,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.PropertyValue exposing [PropertyValue]
import ast.MvStandingQuery exposing [MvStandingQuery]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect, SqContext]
import expr.Expr exposing [Expr, ExprContext, eval]

## Internal state fields for a FilterMap standing query part.
##
## Caches the post-filter/post-projection result list from the child subquery.
FilterMapFields : {
    query_part_id : StandingQueryPartId,
    kept_results : Result (List QueryContext) [NoCachedResult],
}

# ===== Equality helpers (for dedup) =====

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

query_context_eq : QueryContext, QueryContext -> Bool
query_context_eq = |ctx_a, ctx_b|
    Dict.len(ctx_a) == Dict.len(ctx_b)
    && Dict.walk_until(
        ctx_a,
        Bool.true,
        |_, k, va|
            when Dict.get(ctx_b, k) is
                Ok(vb) ->
                    if quine_value_eq(va, vb) then
                        Continue(Bool.true)
                    else
                        Break(Bool.false)
                Err(_) -> Break(Bool.false),
    )

query_context_lists_eq : List QueryContext, List QueryContext -> Bool
query_context_lists_eq = |a, b|
    List.len(a) == List.len(b)
    && List.walk_until(
        List.map2(a, b, |x, y| (x, y)),
        Bool.true,
        |_, (x, y)|
            if query_context_eq(x, y) then
                Continue(Bool.true)
            else
                Break(Bool.false),
    )

# ===== on_initialize =====

## Initialize FilterMapState by subscribing to the child subquery on self.
##
## Creates a single CreateSubscription effect directed at the executing node,
## so that this node receives result updates from `to_filter`.
on_initialize :
    FilterMapFields,
    MvStandingQuery,
    SqContext
    -> { fields : FilterMapFields, effects : List SqEffect }
on_initialize = |fields, to_filter, ctx|
    effects = [
        CreateSubscription({
            on_node: ctx.executing_node_id,
            query: to_filter,
            global_id: 0u128,
            subscriber_part_id: fields.query_part_id,
        }),
    ]
    { fields, effects }

# ===== on_subscription_result =====

## Process a result group delivered from the child subscription.
##
## For each row in result_group:
##   - If condition is Ok(cond_expr): evaluate against the row.
##     Keep row only if result is Ok(True). (False, Null, or error → discard)
##   - If condition is Err(NoFilter): keep all rows.
##
## For each kept row:
##   - Start with the row itself (or Dict.empty if drop_existing is true).
##   - For each { alias, expr } in to_add: evaluate expr against the original row.
##     If Ok, insert alias -> value. If Err, insert alias -> Null.
##
## Compare new results to cached. If different: emit ReportResults, update cache.
## If same: no effect (dedup).
on_subscription_result :
    FilterMapFields,
    List QueryContext,
    Result Expr [NoFilter],
    Bool,
    List { alias : Str, expr : Expr },
    SqContext
    -> { fields : FilterMapFields, effects : List SqEffect, changed : Bool }
on_subscription_result = |fields, result_group, condition, drop_existing, to_add, ctx|
    expr_ctx : ExprContext
    expr_ctx = {
        node_id: ctx.executing_node_id,
        labels_property_key: ctx.labels_property_key,
        properties: ctx.current_properties,
    }

    # Step 1: Filter rows based on condition
    kept_rows : List QueryContext
    kept_rows = List.keep_if(
        result_group,
        |row|
            when condition is
                Err(NoFilter) ->
                    Bool.true

                Ok(cond_expr) ->
                    when eval(cond_expr, row, expr_ctx) is
                        Ok(True) -> Bool.true
                        _ -> Bool.false,
    )

    # Step 2: Project columns for each kept row
    new_results : List QueryContext
    new_results = List.map(
        kept_rows,
        |row|
            # Start with original row or empty dict based on drop_existing
            base : QueryContext
            base = if drop_existing then Dict.empty({}) else row

            # Add each projection column
            List.walk(
                to_add,
                base,
                |acc, { alias, expr }|
                    value =
                        when eval(expr, row, expr_ctx) is
                            Ok(v) -> v
                            Err(_) -> Null
                    Dict.insert(acc, alias, value),
            ),
    )

    # Step 3: Compare to cached results and emit if changed
    result_changed =
        when fields.kept_results is
            Err(NoCachedResult) -> Bool.true
            Ok(prev_results) -> !(query_context_lists_eq(prev_results, new_results))

    new_fields = { fields & kept_results: Ok(new_results) }

    if result_changed then
        { fields: new_fields, effects: [ReportResults(new_results)], changed: Bool.true }
    else
        { fields, effects: [], changed: Bool.false }

# ===== read_results =====

## Read the cached filtered/projected result list.
##
## Returns Ok(cached) if results have been computed, Err(NotReady) otherwise.
read_results :
    FilterMapFields,
    Dict Str PropertyValue,
    Str
    -> Result (List QueryContext) [NotReady]
read_results = |fields, _properties, _labels_key|
    when fields.kept_results is
        Ok(rows) -> Ok(rows)
        Err(NoCachedResult) -> Err(NotReady)

# ===== Test helpers =====

make_fields : StandingQueryPartId -> FilterMapFields
make_fields = |pid| {
    query_part_id: pid,
    kept_results: Err(NoCachedResult),
}

make_sq_ctx : QuineId -> SqContext
make_sq_ctx = |node_id| {
    lookup_query: |_| Err(NotFound),
    executing_node_id: node_id,
    current_properties: Dict.empty({}),
    labels_property_key: "__labels",
}

make_row : Str, I64 -> QueryContext
make_row = |k, v| Dict.insert(Dict.empty({}), k, Integer(v))

# ===== Tests =====

# Test 1: on_initialize subscribes to to_filter on self
expect
    fields = make_fields(10u64)
    to_filter = UnitSq
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    result = on_initialize(fields, to_filter, ctx)
    when result.effects is
        [CreateSubscription({ on_node, subscriber_part_id })] ->
            QuineId.to_bytes(on_node) == [0x01]
            && subscriber_part_id == 10u64
        _ -> Bool.false

# Test 2: on_subscription_result with NoFilter condition → all rows pass through
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    row1 = make_row("x", 1)
    row2 = make_row("x", 2)
    result = on_subscription_result(fields, [row1, row2], Err(NoFilter), Bool.false, [], ctx)
    when result.fields.kept_results is
        Ok(rows) -> List.len(rows) == 2
        Err(_) -> Bool.false

# Test 3: on_subscription_result with condition evaluating to True → row kept
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    # condition: x == 1
    cond = Comparison({ left: Variable("x"), op: Eq, right: Literal(Integer(1)) })
    row_match = make_row("x", 1)
    result = on_subscription_result(fields, [row_match], Ok(cond), Bool.false, [], ctx)
    when result.fields.kept_results is
        Ok([_]) -> Bool.true
        _ -> Bool.false

# Test 4: on_subscription_result with condition evaluating to False → row filtered out
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    # condition: x == 99 (row has x=1, so False)
    cond = Comparison({ left: Variable("x"), op: Eq, right: Literal(Integer(99)) })
    row_no_match = make_row("x", 1)
    result = on_subscription_result(fields, [row_no_match], Ok(cond), Bool.false, [], ctx)
    when result.fields.kept_results is
        Ok([]) -> Bool.true
        _ -> Bool.false

# Test 5: on_subscription_result with to_add projection → new column added
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    row = make_row("x", 5)
    # Project: "doubled" = Literal(Integer(10))
    projection = { alias: "doubled", expr: Literal(Integer(10)) }
    result = on_subscription_result(fields, [row], Err(NoFilter), Bool.false, [projection], ctx)
    when result.fields.kept_results is
        Ok([out_row]) ->
            # original column preserved
            (when Dict.get(out_row, "x") is
                Ok(Integer(5)) -> Bool.true
                _ -> Bool.false)
            &&
            # new column added
            (when Dict.get(out_row, "doubled") is
                Ok(Integer(10)) -> Bool.true
                _ -> Bool.false)
        _ -> Bool.false

# Test 6: on_subscription_result with drop_existing=true → only projected columns remain
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    row = make_row("x", 5)
    projection = { alias: "y", expr: Literal(Integer(42)) }
    result = on_subscription_result(fields, [row], Err(NoFilter), Bool.true, [projection], ctx)
    when result.fields.kept_results is
        Ok([out_row]) ->
            # original "x" column should NOT be present
            !(Dict.contains(out_row, "x"))
            &&
            # projected "y" column IS present
            (when Dict.get(out_row, "y") is
                Ok(Integer(42)) -> Bool.true
                _ -> Bool.false)
        _ -> Bool.false

# Test 7: on_subscription_result with drop_existing=false → original + projected columns
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    row = make_row("x", 5)
    projection = { alias: "y", expr: Literal(Integer(42)) }
    result = on_subscription_result(fields, [row], Err(NoFilter), Bool.false, [projection], ctx)
    when result.fields.kept_results is
        Ok([out_row]) ->
            # original "x" column preserved
            (when Dict.get(out_row, "x") is
                Ok(Integer(5)) -> Bool.true
                _ -> Bool.false)
            &&
            # projected "y" column added
            (when Dict.get(out_row, "y") is
                Ok(Integer(42)) -> Bool.true
                _ -> Bool.false)
        _ -> Bool.false

# Test 8: on_subscription_result same results twice → changed=false (dedup)
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    row = make_row("x", 1)
    r1 = on_subscription_result(fields, [row], Err(NoFilter), Bool.false, [], ctx)
    r2 = on_subscription_result(r1.fields, [row], Err(NoFilter), Bool.false, [], ctx)
    r1.changed == Bool.true && r2.changed == Bool.false

# Test 9: read_results with cached results → Ok(cached)
expect
    rows = [make_row("a", 7)]
    fields : FilterMapFields
    fields = {
        query_part_id: 10u64,
        kept_results: Ok(rows),
    }
    when read_results(fields, Dict.empty({}), "__labels") is
        Ok(r) -> List.len(r) == 1
        Err(_) -> Bool.false

# Test 10: read_results with no cache → NotReady
expect
    fields = make_fields(10u64)
    read_results(fields, Dict.empty({}), "__labels") == Err(NotReady)

# Test 11: condition with Null result → row filtered out
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    # condition: Null == 1 → Null (not True → filtered)
    cond = Comparison({ left: Literal(Null), op: Eq, right: Literal(Integer(1)) })
    row = make_row("x", 1)
    result = on_subscription_result(fields, [row], Ok(cond), Bool.false, [], ctx)
    when result.fields.kept_results is
        Ok([]) -> Bool.true
        _ -> Bool.false

# Test 12: projection with eval error → Null inserted
expect
    fields = make_fields(10u64)
    ctx = make_sq_ctx(QuineId.from_bytes([0x01]))
    # expr: 1 + True → type error → Null
    # Use a BoolOp with Integer operands (EvalError) to trigger error path
    bad_expr = BoolOp({ left: Literal(Integer(1)), op: And, right: Literal(Integer(2)) })
    projection = { alias: "result", expr: bad_expr }
    row = make_row("x", 1)
    result = on_subscription_result(fields, [row], Err(NoFilter), Bool.false, [projection], ctx)
    when result.fields.kept_results is
        Ok([out_row]) ->
            when Dict.get(out_row, "result") is
                Ok(Null) -> Bool.true
                _ -> Bool.false
        _ -> Bool.false

# Test 13: on_initialize returns unchanged fields
expect
    fields = make_fields(20u64)
    to_filter = UnitSq
    ctx = make_sq_ctx(QuineId.from_bytes([0x02]))
    result = on_initialize(fields, to_filter, ctx)
    result.fields.query_part_id == 20u64
    && (
        when result.fields.kept_results is
            Err(NoCachedResult) -> Bool.true
            _ -> Bool.false
    )
