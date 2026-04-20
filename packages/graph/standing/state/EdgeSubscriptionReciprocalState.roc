module [
    on_node_events,
    on_subscription_result,
    read_results,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.HalfEdge exposing [HalfEdge]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## Internal state fields for an EdgeSubscriptionReciprocal standing query part.
##
## This is the remote side of a cross-edge subscription. Node A's
## SubscribeAcrossEdgeState detects an edge to B and sends a
## CreateSubscription to B with an EdgeSubscriptionReciprocal query.
## Node B creates this state, which:
##   1. Watches for the reciprocal half-edge (B → A).
##   2. When the edge exists, subscribes to the `andThen` sub-query locally.
##   3. Relays andThen results back to the subscriber.
##   4. When the edge is removed, cancels the andThen subscription and reports empty.
EdgeReciprocalFields : {
    query_part_id : StandingQueryPartId,
    half_edge : HalfEdge,
    and_then_id : StandingQueryPartId,
    currently_matching : Bool,
    cached_result : Result (List QueryContext) [NoCachedResult],
}

# ===== HalfEdge equality =====

## Compare two HalfEdges for structural equality.
##
## QuineId is opaque so we compare via to_bytes.
half_edges_eq : HalfEdge, HalfEdge -> Bool
half_edges_eq = |a, b|
    a.edge_type == b.edge_type
    and a.direction == b.direction
    and QuineId.to_bytes(a.other) == QuineId.to_bytes(b.other)

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

# ===== on_node_events =====

## Process a list of node change events for an EdgeSubscriptionReciprocal query part.
##
## For EdgeAdded(he) where he equals fields.half_edge:
##   - Sets currently_matching = true
##   - Looks up the andThen query via ctx.lookup_query(fields.and_then_id)
##   - Emits CreateSubscription to subscribe to the andThen query locally
##   - If cached_result is Ok, re-emits ReportResults with the cached rows
##
## For EdgeRemoved(he) where he equals fields.half_edge:
##   - Sets currently_matching = false
##   - Emits CancelSubscription for the andThen subscription
##   - Emits ReportResults([]) to signal no match
on_node_events :
    EdgeReciprocalFields,
    List NodeChangeEvent,
    SqContext
    -> { fields : EdgeReciprocalFields, effects : List SqEffect, changed : Bool }
on_node_events = |fields, events, ctx|
    List.walk(
        events,
        { fields, effects: [], changed: Bool.false },
        |state, event|
            when event is
                EdgeAdded(he) ->
                    if half_edges_eq(he, state.fields.half_edge) and !(state.fields.currently_matching) then
                        cur_fields = state.fields
                        new_fields = { cur_fields & currently_matching: Bool.true }

                        # Look up the andThen query to subscribe to it
                        subscribe_effects =
                            when ctx.lookup_query(state.fields.and_then_id) is
                                Ok(and_then_query) ->
                                    [
                                        CreateSubscription({
                                            on_node: ctx.executing_node_id,
                                            query: and_then_query,
                                            global_id: 0u128,
                                            subscriber_part_id: state.fields.query_part_id,
                                        }),
                                    ]
                                Err(NotFound) ->
                                    # andThen query not found — skip subscription (shouldn't happen in practice)
                                    []

                        # If we have a cached result, re-emit it now that we're matching
                        report_effects =
                            when state.fields.cached_result is
                                Ok(rows) -> [ReportResults(rows)]
                                Err(NoCachedResult) -> []

                        all_effects = List.concat(subscribe_effects, report_effects)
                        { state &
                            fields: new_fields,
                            effects: List.concat(state.effects, all_effects),
                            changed: Bool.true,
                        }
                    else
                        state

                EdgeRemoved(he) ->
                    if half_edges_eq(he, state.fields.half_edge) and state.fields.currently_matching then
                        cur_fields2 = state.fields
                        new_fields = { cur_fields2 & currently_matching: Bool.false }

                        cancel_effect = CancelSubscription({
                            on_node: ctx.executing_node_id,
                            query_part_id: state.fields.and_then_id,
                            global_id: 0u128,
                        })

                        # Report empty results — we're no longer matching
                        report_effect = ReportResults([])

                        all_effects = [cancel_effect, report_effect]
                        { state &
                            fields: new_fields,
                            effects: List.concat(state.effects, all_effects),
                            changed: Bool.true,
                        }
                    else
                        state

                _ ->
                    # PropertySet / PropertyRemoved — not relevant to reciprocal edge state
                    state,
    )

# ===== on_subscription_result =====

## Process a subscription result delivered from the andThen sub-query.
##
## - Caches the result regardless of matching status.
## - If currently_matching AND result is different from previous cache: emits ReportResults.
## - Returns whether the result was an update (for persistence tracking).
on_subscription_result :
    EdgeReciprocalFields,
    List QueryContext
    -> { fields : EdgeReciprocalFields, effects : List SqEffect, changed : Bool }
on_subscription_result = |fields, result_group|
    # Check if the result actually changed from the previous cache
    result_changed =
        when fields.cached_result is
            Err(NoCachedResult) -> Bool.true
            Ok(prev_rows) ->
                if List.len(prev_rows) != List.len(result_group) then
                    Bool.true
                else
                    !(query_context_lists_eq(prev_rows, result_group))

    new_fields = { fields & cached_result: Ok(result_group) }

    if result_changed and fields.currently_matching then
        { fields: new_fields, effects: [ReportResults(result_group)], changed: Bool.true }
    else if result_changed then
        # Cache updated but not currently matching — no report
        { fields: new_fields, effects: [], changed: Bool.true }
    else
        # Same result — no change
        { fields, effects: [], changed: Bool.false }

# ===== read_results =====

## Read the current result from the cached state.
##
## Returns Ok(rows) if currently_matching and cached_result is Ok.
## Otherwise returns Err(NotReady).
read_results :
    EdgeReciprocalFields,
    Dict Str PropertyValue,
    Str
    -> Result (List QueryContext) [NotReady]
read_results = |fields, _properties, _labels_key|
    if fields.currently_matching then
        when fields.cached_result is
            Ok(rows) -> Ok(rows)
            Err(NoCachedResult) -> Err(NotReady)
    else
        Err(NotReady)

# ===== Test helpers =====

make_fields : StandingQueryPartId, HalfEdge, StandingQueryPartId -> EdgeReciprocalFields
make_fields = |pid, he, and_then_id| {
    query_part_id: pid,
    half_edge: he,
    and_then_id,
    currently_matching: Bool.false,
    cached_result: Err(NoCachedResult),
}

make_ctx : QuineId, StandingQueryPartId -> SqContext
make_ctx = |node_id, and_then_id| {
    lookup_query: |qid|
        if qid == and_then_id then
            Ok(UnitSq)
        else
            Err(NotFound),
    executing_node_id: node_id,
    current_properties: Dict.empty({}),
    labels_property_key: "__labels",
}

make_ctx_val : Str, I64 -> QueryContext
make_ctx_val = |k, v| Dict.insert(Dict.empty({}), k, Integer(v))

# ===== Tests =====

# Test 1: EdgeAdded matching half_edge → currently_matching=true + CreateSubscription
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    fields = make_fields(1u64, he, and_then_id)
    ctx = make_ctx(QuineId.from_bytes([0x0A]), and_then_id)
    result = on_node_events(fields, [EdgeAdded(he)], ctx)
    has_create_sub =
        List.any(result.effects, |e|
            when e is
                CreateSubscription(_) -> Bool.true
                _ -> Bool.false)
    result.fields.currently_matching and has_create_sub and result.changed

# Test 2: EdgeAdded non-matching half_edge → no change
expect
    node_b = QuineId.from_bytes([0x0B])
    node_c = QuineId.from_bytes([0x0C])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    other_he = { edge_type: "KNOWS", direction: Incoming, other: node_c }
    fields = make_fields(1u64, he, and_then_id)
    ctx = make_ctx(QuineId.from_bytes([0x0A]), and_then_id)
    result = on_node_events(fields, [EdgeAdded(other_he)], ctx)
    !(result.fields.currently_matching)
    and List.is_empty(result.effects)
    and !(result.changed)

# Test 3: EdgeRemoved matching → currently_matching=false + CancelSubscription + ReportResults([])
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    # Pre-build with currently_matching=true
    fields : EdgeReciprocalFields
    fields = {
        query_part_id: 1u64,
        half_edge: he,
        and_then_id,
        currently_matching: Bool.true,
        cached_result: Err(NoCachedResult),
    }
    ctx = make_ctx(QuineId.from_bytes([0x0A]), and_then_id)
    result = on_node_events(fields, [EdgeRemoved(he)], ctx)
    has_cancel =
        List.any(result.effects, |e|
            when e is
                CancelSubscription(_) -> Bool.true
                _ -> Bool.false)
    has_report_empty =
        List.any(result.effects, |e|
            when e is
                ReportResults([]) -> Bool.true
                _ -> Bool.false)
    !(result.fields.currently_matching) and has_cancel and has_report_empty and result.changed

# Test 4: on_subscription_result when matching → ReportResults with result
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    fields : EdgeReciprocalFields
    fields = {
        query_part_id: 1u64,
        half_edge: he,
        and_then_id,
        currently_matching: Bool.true,
        cached_result: Err(NoCachedResult),
    }
    result_rows = [make_ctx_val("x", 42)]
    r = on_subscription_result(fields, result_rows)
    has_report =
        List.any(r.effects, |e|
            when e is
                ReportResults(_) -> Bool.true
                _ -> Bool.false)
    r.changed and has_report

# Test 5: on_subscription_result when NOT matching → caches but no ReportResults
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    fields = make_fields(1u64, he, and_then_id)
    # currently_matching = false (default from make_fields)
    result_rows = [make_ctx_val("x", 42)]
    r = on_subscription_result(fields, result_rows)
    # Changed because cache was updated, but no ReportResults
    has_no_report =
        List.all(r.effects, |e|
            when e is
                ReportResults(_) -> Bool.false
                _ -> Bool.true)
    r.changed and has_no_report
    and (
        when r.fields.cached_result is
            Ok(rows) -> List.len(rows) == 1
            Err(_) -> Bool.false
    )

# Test 6: on_subscription_result same result twice → changed=false (dedup)
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    fields : EdgeReciprocalFields
    fields = {
        query_part_id: 1u64,
        half_edge: he,
        and_then_id,
        currently_matching: Bool.true,
        cached_result: Err(NoCachedResult),
    }
    result_rows = [make_ctx_val("y", 99)]
    r1 = on_subscription_result(fields, result_rows)
    r2 = on_subscription_result(r1.fields, result_rows)
    r1.changed and r2.changed == Bool.false

# Test 7: read_results when matching and cached → Ok(cached)
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    rows = [make_ctx_val("x", 7)]
    fields : EdgeReciprocalFields
    fields = {
        query_part_id: 1u64,
        half_edge: he,
        and_then_id,
        currently_matching: Bool.true,
        cached_result: Ok(rows),
    }
    when read_results(fields, Dict.empty({}), "__labels") is
        Ok(r) -> List.len(r) == 1
        Err(_) -> Bool.false

# Test 8: read_results when not matching → NotReady
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    fields = make_fields(1u64, he, and_then_id)
    # currently_matching = false (default)
    read_results(fields, Dict.empty({}), "__labels") == Err(NotReady)

# Test 9: read_results when matching but no cached result → NotReady
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    fields : EdgeReciprocalFields
    fields = {
        query_part_id: 1u64,
        half_edge: he,
        and_then_id,
        currently_matching: Bool.true,
        cached_result: Err(NoCachedResult),
    }
    read_results(fields, Dict.empty({}), "__labels") == Err(NotReady)

# Test 10: EdgeAdded when already matching → idempotent (no extra effects)
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    fields : EdgeReciprocalFields
    fields = {
        query_part_id: 1u64,
        half_edge: he,
        and_then_id,
        currently_matching: Bool.true,
        cached_result: Err(NoCachedResult),
    }
    ctx = make_ctx(QuineId.from_bytes([0x0A]), and_then_id)
    result = on_node_events(fields, [EdgeAdded(he)], ctx)
    # Should produce no effects (already matching)
    List.is_empty(result.effects) and !(result.changed)

# Test 11: EdgeRemoved when not matching → no effects (idempotent)
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    fields = make_fields(1u64, he, and_then_id)
    # currently_matching = false (default)
    ctx = make_ctx(QuineId.from_bytes([0x0A]), and_then_id)
    result = on_node_events(fields, [EdgeRemoved(he)], ctx)
    List.is_empty(result.effects) and !(result.changed)

# Test 12: EdgeAdded then cached result emitted on re-match
expect
    node_b = QuineId.from_bytes([0x0B])
    and_then_id = 42u64
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    cached_rows = [make_ctx_val("z", 5)]
    # Start: not matching, but has a cached result from a previous match cycle
    fields : EdgeReciprocalFields
    fields = {
        query_part_id: 1u64,
        half_edge: he,
        and_then_id,
        currently_matching: Bool.false,
        cached_result: Ok(cached_rows),
    }
    ctx = make_ctx(QuineId.from_bytes([0x0A]), and_then_id)
    result = on_node_events(fields, [EdgeAdded(he)], ctx)
    # Should emit both CreateSubscription and ReportResults(cached_rows)
    has_create_sub =
        List.any(result.effects, |e|
            when e is
                CreateSubscription(_) -> Bool.true
                _ -> Bool.false)
    has_report =
        List.any(result.effects, |e|
            when e is
                ReportResults(rows) -> List.len(rows) == 1
                _ -> Bool.false)
    has_create_sub and has_report
