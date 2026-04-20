module [
    on_initialize,
    on_subscription_result,
    read_results,
]

import id.QuineId
import model.QuineValue exposing [QuineValue]
import ast.MvStandingQuery exposing [MvStandingQuery, query_part_id]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## Internal state fields for a Cross standing query part.
CrossFields : {
    query_part_id : StandingQueryPartId,
    results_accumulator : Dict StandingQueryPartId (Result (List QueryContext) [Pending]),
}

## Structural equality for QuineValue.
##
## Cannot rely on auto-derived Eq for recursive types containing QuineId (opaque).
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
            # Compare by bytes since QuineId is opaque across packages
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

## Structural equality for QueryContext (Dict Str QuineValue).
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

## Structural equality for List QueryContext.
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

## Check if all entries in the accumulator are Ok (not Pending).
is_ready_to_report : Dict StandingQueryPartId (Result (List QueryContext) [Pending]) -> Bool
is_ready_to_report = |accumulator|
    Dict.walk_until(
        accumulator,
        Bool.true,
        |_, _k, v|
            when v is
                Ok(_) -> Continue(Bool.true)
                Err(Pending) -> Break(Bool.false),
    )

## Generate the cross product of all result groups in the accumulator.
##
## Starts with [Dict.empty({})] (one empty row — the identity for cross product).
## For each group, crosses each existing row with each row in the group by merging dicts.
## Returns Err(NotReady) if any group is still Pending.
generate_cross_product : Dict StandingQueryPartId (Result (List QueryContext) [Pending]) -> Result (List QueryContext) [NotReady]
generate_cross_product = |accumulator|
    # Check all are ready first
    if !(is_ready_to_report(accumulator)) then
        Err(NotReady)
    else
        initial : List QueryContext
        initial = [Dict.empty({})]
        result =
            Dict.walk(
                accumulator,
                initial,
                |rows_so_far, _part_id, group_result|
                    when group_result is
                        Err(Pending) ->
                            # Should not happen (we checked above), but be safe
                            rows_so_far
                        Ok(group) ->
                            # Cross: for each existing row, combine with each row in the group
                            List.join(
                                List.map(rows_so_far, |existing_row|
                                    List.map(group, |new_row|
                                        # Merge: new_row keys overwrite existing_row keys with same name
                                        Dict.walk(new_row, existing_row, |merged, k, v|
                                            Dict.insert(merged, k, v)
                                        )
                                    )
                                )
                            ),
            )
        Ok(result)

## Initialize CrossState by subscribing to child queries.
##
## If `emit_lazily` is false: subscribe to ALL child queries immediately.
## If `emit_lazily` is true: subscribe to ONLY the first child query.
## Remaining children will be subscribed lazily in `on_subscription_result`.
on_initialize :
    CrossFields,
    List MvStandingQuery,
    Bool,
    SqContext
    -> { fields : CrossFields, effects : List SqEffect }
on_initialize = |fields, child_queries, emit_lazily, ctx|
    # Determine how many children to subscribe to now
    queries_to_subscribe =
        if emit_lazily then
            List.take_first(child_queries, 1)
        else
            child_queries

    # Build the initial accumulator: all children start as Pending
    initial_accumulator =
        List.walk(
            child_queries,
            Dict.empty({}),
            |acc, sq|
                pid = query_part_id(sq)
                Dict.insert(acc, pid, Err(Pending)),
        )

    # Build effects for the queries we're subscribing to now
    effects =
        List.map(queries_to_subscribe, |sq|
            CreateSubscription({
                on_node: ctx.executing_node_id,
                query: sq,
                global_id: 0u128,
                subscriber_part_id: fields.query_part_id,
            })
        )

    new_fields = { fields & results_accumulator: initial_accumulator }
    { fields: new_fields, effects }

## Handle a result delivered from a child subscription.
##
## Logic:
## 1. If `result_part_id` is not in the accumulator, ignore (return unchanged).
## 2. In lazy mode, when a result arrives from the most-recently-subscribed child,
##    subscribe to the next child. Don't compute the cross product yet.
## 3. When all subscriptions are emitted AND all children have results, compute
##    the cross product and emit ReportResults.
on_subscription_result :
    CrossFields,
    StandingQueryPartId,
    List QueryContext,
    List MvStandingQuery,
    Bool,
    SqContext
    -> { fields : CrossFields, effects : List SqEffect, changed : Bool }
on_subscription_result = |fields, result_part_id, result_group, child_queries, emit_lazily, ctx|
    # Step 1: Check if result_part_id is in the accumulator
    when Dict.get(fields.results_accumulator, result_part_id) is
        Err(KeyNotFound) ->
            # Not for us — ignore
            { fields, effects: [], changed: Bool.false }

        Ok(previous_value) ->
            # Step 2: Cache the result
            updated_accumulator = Dict.insert(fields.results_accumulator, result_part_id, Ok(result_group))
            updated_fields = { fields & results_accumulator: updated_accumulator }

            # Count how many subscriptions have been emitted so far.
            # In lazy mode, the number of subscriptions emitted equals the number of
            # children whose results have been received OR are pending but subscribed.
            # We track this by counting how many child part_ids are in the accumulator
            # that are NOT yet Ok (they are still Pending) after this update.
            #
            # Actually, a simpler approach: in lazy mode, subscriptions are emitted one
            # at a time. We know which one was "most recently subscribed" by finding the
            # last child in child_queries whose part_id is in the accumulator.
            # We subscribe the next one when we get a result from the current frontier.
            child_part_ids = List.map(child_queries, query_part_id)
            total_children = List.len(child_part_ids)

            # Find how many subscriptions have been emitted:
            # In lazy mode, we emitted 1 at init; each result triggers the next.
            # We count how many children are currently in the accumulator
            # (all children are inserted at init, so this is always total_children).
            # Instead, track the "subscription frontier" by finding the index of
            # result_part_id among the child_part_ids.
            result_index =
                List.find_first_index(child_part_ids, |pid| pid == result_part_id)
                |> Result.with_default(0)

            # Determine if we should subscribe the next child (lazy mode only)
            lazy_effects =
                if emit_lazily then
                    # The subscription frontier: we've subscribed children 0..result_index
                    # (inclusive). If result_index+1 < total_children, subscribe the next.
                    next_index = result_index + 1
                    if next_index < total_children then
                        when List.get(child_queries, next_index) is
                            Ok(next_sq) ->
                                [
                                    CreateSubscription({
                                        on_node: ctx.executing_node_id,
                                        query: next_sq,
                                        global_id: 0u128,
                                        subscriber_part_id: fields.query_part_id,
                                    }),
                                ]
                            Err(OutOfBounds) -> []
                    else
                        []
                else
                    []

            # Determine if we're now ready to report (all subscriptions emitted and all have results)
            # In lazy mode: all subscriptions are emitted when we have NO more lazy subscriptions to make.
            # That means: result_index == total_children - 1 (last child just subscribed and delivered),
            # OR we're in eager mode (all subscribed at init).
            all_subscriptions_emitted =
                if emit_lazily then
                    # All subscriptions have been emitted when this result is from the last child
                    result_index == total_children - 1
                else
                    Bool.true

            if all_subscriptions_emitted && is_ready_to_report(updated_accumulator) then
                # Check if the result actually changed (dedup)
                result_changed =
                    when previous_value is
                        Err(Pending) -> Bool.true
                        Ok(prev_list) -> !(query_context_lists_eq(prev_list, result_group))

                if result_changed then
                    when generate_cross_product(updated_accumulator) is
                        Ok(cross_product) ->
                            effects = List.concat(lazy_effects, [ReportResults(cross_product)])
                            { fields: updated_fields, effects, changed: Bool.true }
                        Err(NotReady) ->
                            { fields: updated_fields, effects: lazy_effects, changed: Bool.false }
                else
                    # Same result as before — dedup
                    { fields: updated_fields, effects: lazy_effects, changed: Bool.false }
            else
                # Not yet ready: cache and possibly subscribe next child
                { fields: updated_fields, effects: lazy_effects, changed: Bool.false }

## Read the cross product result from the current accumulator state.
##
## Returns Ok with the cross product if all subscriptions have been emitted
## and all children have results. Otherwise returns Err(NotReady).
read_results :
    CrossFields,
    List MvStandingQuery,
    Dict Str _,
    Str
    -> Result (List QueryContext) [NotReady]
read_results = |fields, child_queries, _properties, _labels_key|
    total_children = List.len(child_queries)

    # If no children, Cross of empty = one empty row (identity)
    if total_children == 0 then
        Ok([Dict.empty({})])
    else
        # Check all children have results (not Pending)
        if !(is_ready_to_report(fields.results_accumulator)) then
            Err(NotReady)
        else
            generate_cross_product(fields.results_accumulator)

# ===== Tests =====

# Helper: build initial CrossFields
make_fields : StandingQueryPartId -> CrossFields
make_fields = |pid| {
    query_part_id: pid,
    results_accumulator: Dict.empty({}),
}

# Helper: build a simple QueryContext
make_ctx : Str, I64 -> QueryContext
make_ctx = |k, v| Dict.insert(Dict.empty({}), k, Integer(v))

# Test 1: on_initialize with emit_lazily=false subscribes to all queries (2 queries → 2 effects)
expect
    fields = make_fields(99u64)
    q1 = UnitSq
    q2 : MvStandingQuery
    q2 = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Err(NoAlias) })
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([0x01]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    result = on_initialize(fields, [q1, q2], Bool.false, ctx)
    List.len(result.effects) == 2

# Test 2: on_initialize with emit_lazily=true subscribes to first query only (2 queries → 1 effect)
expect
    fields = make_fields(99u64)
    q1 = UnitSq
    q2 : MvStandingQuery
    q2 = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Err(NoAlias) })
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([0x01]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    result = on_initialize(fields, [q1, q2], Bool.true, ctx)
    List.len(result.effects) == 1

# Test 3: on_initialize builds accumulator with all children as Pending
expect
    fields = make_fields(99u64)
    q1 = UnitSq
    q2 : MvStandingQuery
    q2 = LocalProperty({ prop_key: "x", constraint: Any, aliased_as: Err(NoAlias) })
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([0x01]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    result = on_initialize(fields, [q1, q2], Bool.false, ctx)
    # Both children should be Pending in accumulator
    pid1 = query_part_id(q1)
    pid2 = query_part_id(q2)
    Dict.get(result.fields.results_accumulator, pid1) == Ok(Err(Pending))
    && Dict.get(result.fields.results_accumulator, pid2) == Ok(Err(Pending))

# Test 4: on_subscription_result caches a result (accumulator updated)
expect
    q1 = UnitSq
    pid1 = query_part_id(q1)
    fields : CrossFields
    fields = {
        query_part_id: 99u64,
        results_accumulator: Dict.insert(Dict.empty({}), pid1, Err(Pending)),
    }
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([0x01]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    result_row = make_ctx("x", 1)
    result = on_subscription_result(fields, pid1, [result_row], [q1], Bool.false, ctx)
    Dict.get(result.fields.results_accumulator, pid1) == Ok(Ok([result_row]))

# Test 5: on_subscription_result ignores results for unknown part IDs
expect
    q1 = UnitSq
    pid1 = query_part_id(q1)
    fields : CrossFields
    fields = {
        query_part_id: 99u64,
        results_accumulator: Dict.insert(Dict.empty({}), pid1, Err(Pending)),
    }
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([0x01]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    unknown_pid = 999u64
    result = on_subscription_result(fields, unknown_pid, [], [q1], Bool.false, ctx)
    # Should be unchanged
    result.changed == Bool.false && List.len(result.effects) == 0

# Test 6: on_subscription_result with lazy mode: first result triggers next subscription
expect
    q1 = UnitSq
    q2 : MvStandingQuery
    q2 = LocalProperty({ prop_key: "y", constraint: Any, aliased_as: Err(NoAlias) })
    pid1 = query_part_id(q1)
    pid2 = query_part_id(q2)
    # Simulate state after on_initialize with emit_lazily=true (only q1 subscribed)
    fields : CrossFields
    fields = {
        query_part_id: 99u64,
        results_accumulator:
            Dict.empty({})
            |> Dict.insert(pid1, Err(Pending))
            |> Dict.insert(pid2, Err(Pending)),
    }
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([0x01]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    # First child (q1 at index 0) delivers result — should trigger subscription to q2
    result = on_subscription_result(fields, pid1, [Dict.empty({})], [q1, q2], Bool.true, ctx)
    # Expect 1 CreateSubscription effect for q2
    when result.effects is
        [CreateSubscription(_)] -> Bool.true
        _ -> Bool.false

# Test 7: generate_cross_product with two single-row groups → one merged row
expect
    pid1 = 1u64
    pid2 = 2u64
    row1 = make_ctx("a", 1)
    row2 = make_ctx("b", 2)
    acc =
        Dict.empty({})
        |> Dict.insert(pid1, Ok([row1]))
        |> Dict.insert(pid2, Ok([row2]))
    when generate_cross_product(acc) is
        Ok([merged]) ->
            (when Dict.get(merged, "a") is
                Ok(v) -> quine_value_eq(v, Integer(1))
                Err(_) -> Bool.false)
            && (when Dict.get(merged, "b") is
                Ok(v) -> quine_value_eq(v, Integer(2))
                Err(_) -> Bool.false)
        _ -> Bool.false

# Test 8: generate_cross_product with [1 row] x [2 rows] → 2 rows
expect
    pid1 = 1u64
    pid2 = 2u64
    row1 = make_ctx("a", 1)
    row2a = make_ctx("b", 2)
    row2b = make_ctx("b", 3)
    acc =
        Dict.empty({})
        |> Dict.insert(pid1, Ok([row1]))
        |> Dict.insert(pid2, Ok([row2a, row2b]))
    when generate_cross_product(acc) is
        Ok(rows) -> List.len(rows) == 2
        _ -> Bool.false

# Test 9: generate_cross_product with one Pending group → NotReady
expect
    pid1 = 1u64
    pid2 = 2u64
    acc =
        Dict.empty({})
        |> Dict.insert(pid1, Ok([make_ctx("a", 1)]))
        |> Dict.insert(pid2, Err(Pending))
    generate_cross_product(acc) == Err(NotReady)

# Test 10: read_results when all ready → cross product returned
expect
    q1 = UnitSq
    pid1 = query_part_id(q1)
    row1 = make_ctx("x", 42)
    fields : CrossFields
    fields = {
        query_part_id: 99u64,
        results_accumulator: Dict.insert(Dict.empty({}), pid1, Ok([row1])),
    }
    when read_results(fields, [q1], Dict.empty({}), "__labels") is
        Ok([row]) ->
            when Dict.get(row, "x") is
                Ok(v) -> quine_value_eq(v, Integer(42))
                Err(_) -> Bool.false
        _ -> Bool.false

# Test 11: read_results when not all subscriptions emitted (still Pending) → NotReady
expect
    q1 = UnitSq
    pid1 = query_part_id(q1)
    fields : CrossFields
    fields = {
        query_part_id: 99u64,
        results_accumulator: Dict.insert(Dict.empty({}), pid1, Err(Pending)),
    }
    read_results(fields, [q1], Dict.empty({}), "__labels") == Err(NotReady)

# Test 12: is_ready_to_report: all Ok → true
expect
    acc =
        Dict.empty({})
        |> Dict.insert(1u64, Ok([make_ctx("a", 1)]))
        |> Dict.insert(2u64, Ok([make_ctx("b", 2)]))
    is_ready_to_report(acc) == Bool.true

# Test 13: is_ready_to_report: some Pending → false
expect
    acc =
        Dict.empty({})
        |> Dict.insert(1u64, Ok([make_ctx("a", 1)]))
        |> Dict.insert(2u64, Err(Pending))
    is_ready_to_report(acc) == Bool.false

# Test 14: Dedup: same result twice → changed=false on second arrival
expect
    q1 = UnitSq
    pid1 = query_part_id(q1)
    row1 = make_ctx("x", 1)
    # First result arrives (from Pending)
    fields0 : CrossFields
    fields0 = {
        query_part_id: 99u64,
        results_accumulator: Dict.insert(Dict.empty({}), pid1, Err(Pending)),
    }
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([0x01]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    r1 = on_subscription_result(fields0, pid1, [row1], [q1], Bool.false, ctx)
    # Second arrival with same result
    r2 = on_subscription_result(r1.fields, pid1, [row1], [q1], Bool.false, ctx)
    r2.changed == Bool.false

# Test 15: Cross product of empty group with anything → empty result
expect
    pid1 = 1u64
    pid2 = 2u64
    acc =
        Dict.empty({})
        |> Dict.insert(pid1, Ok([]))
        |> Dict.insert(pid2, Ok([make_ctx("b", 2)]))
    when generate_cross_product(acc) is
        Ok([]) -> Bool.true
        _ -> Bool.false

# Test 16: Cross product identity: [{} ] x [{x:1}] → [{x:1}]
expect
    pid1 = 1u64
    pid2 = 2u64
    acc =
        Dict.empty({})
        |> Dict.insert(pid1, Ok([Dict.empty({})]))
        |> Dict.insert(pid2, Ok([make_ctx("x", 1)]))
    when generate_cross_product(acc) is
        Ok([row]) ->
            when Dict.get(row, "x") is
                Ok(v) -> quine_value_eq(v, Integer(1))
                Err(_) -> Bool.false
        _ -> Bool.false
