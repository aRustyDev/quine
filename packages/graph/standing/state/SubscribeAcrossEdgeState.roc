module [
    on_node_events,
    on_subscription_result,
    read_results,
]

import id.QuineId exposing [QuineId]
import model.QuineValue exposing [QuineValue]
import model.HalfEdge exposing [HalfEdge]
import model.EdgeDirection exposing [EdgeDirection]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import ast.MvStandingQuery exposing [MvStandingQuery, query_part_id]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## Internal state fields for a SubscribeAcrossEdge standing query part.
##
## We use Str keys (serialized HalfEdge) for the Dict because Roc cannot
## automatically derive Hash for records whose opaque fields may lack Hash
## derivation in all compiler versions.
SubscribeAcrossEdgeFields : {
    query_part_id : StandingQueryPartId,
    ## Keyed by half_edge_key(he) → result for that edge's sub-query.
    edge_results : Dict Str (Result (List QueryContext) [Pending]),
    ## Shadow store: key → HalfEdge, so we can reconstruct HalfEdge from key.
    edge_map : Dict Str HalfEdge,
}

# ===== Key helpers =====

## Encode an EdgeDirection as a single character string.
dir_str : EdgeDirection -> Str
dir_str = |dir|
    when dir is
        Outgoing -> "O"
        Incoming -> "I"
        Undirected -> "U"

## Derive a stable string key for a HalfEdge.
##
## Format: "<edge_type>:<direction_char>:<other_hex>"
half_edge_key : HalfEdge -> Str
half_edge_key = |he|
    hex = QuineId.to_hex_str(he.other)
    Str.concat(he.edge_type, Str.concat(":", Str.concat(dir_str(he.direction), Str.concat(":", hex))))

# ===== Pattern matching =====

## Test whether a half-edge matches the edge name and direction filters.
edge_matches_pattern : HalfEdge, Result Str [AnyEdge], Result EdgeDirection [AnyDirection] -> Bool
edge_matches_pattern = |he, edge_name, edge_direction|
    name_ok =
        when edge_name is
            Ok(name) -> he.edge_type == name
            Err(AnyEdge) -> Bool.true
    dir_ok =
        when edge_direction is
            Ok(dir) -> he.direction == dir
            Err(AnyDirection) -> Bool.true
    name_ok and dir_ok

# ===== read_results =====

## Compute the current result set from the accumulated per-edge results.
##
## Semantics (existential / OR across edges):
## - No tracked edges → Ok([]) (vacuously true — no edges means no results expected)
## - Any edge still Pending → Err(NotReady)
## - All edges resolved → concatenate all result rows
read_results :
    SubscribeAcrossEdgeFields,
    Dict Str PropertyValue,
    Str
    -> Result (List QueryContext) [NotReady]
read_results = |fields, _properties, _labels_key|
    if Dict.is_empty(fields.edge_results) then
        Ok([])
    else
        # Check for any Pending entries first
        has_pending = Dict.walk_until(
            fields.edge_results,
            Bool.false,
            |_, _k, v|
                when v is
                    Err(Pending) -> Break(Bool.true)
                    Ok(_) -> Continue(Bool.false),
        )
        if has_pending then
            Err(NotReady)
        else
            # Concatenate all result rows
            rows = Dict.walk(
                fields.edge_results,
                [],
                |acc, _k, v|
                    when v is
                        Ok(group) -> List.concat(acc, group)
                        Err(Pending) -> acc, # Should not happen (checked above)
            )
            Ok(rows)

# ===== on_node_events =====

## Process a list of node change events for a SubscribeAcrossEdge query part.
##
## For EdgeAdded events that match the pattern:
##   - Reflects the half-edge to construct the reciprocal
##   - Emits a CreateSubscription to the remote node
##   - Records the edge as Pending in edge_results
##
## For EdgeRemoved events for tracked edges:
##   - Removes the edge from edge_results
##   - Emits a CancelSubscription to the remote node
##   - If the removed edge had resolved results, re-reports via read_results
on_node_events :
    SubscribeAcrossEdgeFields,
    List NodeChangeEvent,
    Result Str [AnyEdge],
    Result EdgeDirection [AnyDirection],
    MvStandingQuery,
    SqContext
    -> { fields : SubscribeAcrossEdgeFields, effects : List SqEffect, changed : Bool }
on_node_events = |fields, events, edge_name, edge_direction, and_then, ctx|
    and_then_id = query_part_id(and_then)

    List.walk(
        events,
        { fields, effects: [], changed: Bool.false },
        |state, event|
            when event is
                EdgeAdded(he) ->
                    if edge_matches_pattern(he, edge_name, edge_direction) then
                        key = half_edge_key(he)
                        # Only add if not already tracked
                        if Dict.contains(state.fields.edge_results, key) then
                            state
                        else
                            # Build reciprocal query on the remote node
                            reciprocal_he = HalfEdge.reflect(he, ctx.executing_node_id)
                            reciprocal_query = EdgeSubscriptionReciprocal({
                                half_edge: reciprocal_he,
                                and_then_id,
                            })
                            new_effect = CreateSubscription({
                                on_node: he.other,
                                query: reciprocal_query,
                                global_id: 0u128,
                                subscriber_part_id: state.fields.query_part_id,
                            })
                            cur_fields = state.fields
                            new_edge_results = Dict.insert(cur_fields.edge_results, key, Err(Pending))
                            new_edge_map = Dict.insert(cur_fields.edge_map, key, he)
                            new_fields = { cur_fields & edge_results: new_edge_results, edge_map: new_edge_map }
                            { state &
                                fields: new_fields,
                                effects: List.append(state.effects, new_effect),
                                changed: Bool.true,
                            }
                    else
                        state

                EdgeRemoved(he) ->
                    key = half_edge_key(he)
                    when Dict.get(state.fields.edge_results, key) is
                        Err(KeyNotFound) ->
                            # Not tracked — ignore
                            state
                        Ok(old_result) ->
                            # Remove from edge_results and edge_map
                            cur_fields2 = state.fields
                            new_edge_results = Dict.remove(cur_fields2.edge_results, key)
                            new_edge_map = Dict.remove(cur_fields2.edge_map, key)
                            new_fields = { cur_fields2 & edge_results: new_edge_results, edge_map: new_edge_map }

                            cancel_effect = CancelSubscription({
                                on_node: he.other,
                                query_part_id: and_then_id,
                                global_id: 0u128,
                            })

                            # If the removed edge had non-empty rows, re-report
                            report_effects =
                                had_results =
                                    when old_result is
                                        Ok(rows) -> !(List.is_empty(rows))
                                        Err(Pending) -> Bool.false
                                if had_results then
                                    # Recompute with edge removed
                                    when read_results(new_fields, Dict.empty({}), "") is
                                        Ok(rows) -> [ReportResults(rows)]
                                        Err(NotReady) -> []
                                else
                                    []

                            all_effects = List.concat([cancel_effect], report_effects)
                            { state &
                                fields: new_fields,
                                effects: List.concat(state.effects, all_effects),
                                changed: Bool.true,
                            }

                _ ->
                    # PropertySet / PropertyRemoved — not relevant to edge state
                    state,
    )

# ===== on_subscription_result =====

## Process a subscription result delivered from a remote node.
##
## Finds the edge in edge_results where he.other == result_from and edge
## matches the pattern. If found and different from cached, updates cache
## and re-reports results via read_results.
on_subscription_result :
    SubscribeAcrossEdgeFields,
    QuineId,
    StandingQueryPartId,
    List QueryContext,
    Result Str [AnyEdge],
    Result EdgeDirection [AnyDirection],
    Dict Str PropertyValue,
    Str
    -> { fields : SubscribeAcrossEdgeFields, effects : List SqEffect, changed : Bool }
on_subscription_result = |fields, result_from, _result_query_part_id, result_group, edge_name, edge_direction, properties, labels_key|
    from_bytes = QuineId.to_bytes(result_from)
    # Find the key for the edge whose `other` matches result_from
    matching_key =
        Dict.walk_until(
            fields.edge_map,
            Err(NotFound),
            |_, k, he|
                if
                    QuineId.to_bytes(he.other) == from_bytes
                    and edge_matches_pattern(he, edge_name, edge_direction)
                then
                    Break(Ok(k))
                else
                    Continue(Err(NotFound)),
        )

    when matching_key is
        Err(NotFound) ->
            # No edge tracked from this node — ignore
            { fields, effects: [], changed: Bool.false }

        Ok(key) ->
            # Check if value changed from cached
            prev_result = Dict.get(fields.edge_results, key) |> Result.with_default(Err(Pending))
            result_changed =
                when prev_result is
                    Err(Pending) -> Bool.true
                    Ok(prev_rows) ->
                        # Quick length check first, then deep equality
                        if List.len(prev_rows) != List.len(result_group) then
                            Bool.true
                        else
                            !(query_context_lists_eq(prev_rows, result_group))

            if result_changed then
                new_edge_results = Dict.insert(fields.edge_results, key, Ok(result_group))
                new_fields = { fields & edge_results: new_edge_results }
                effects =
                    when read_results(new_fields, properties, labels_key) is
                        Ok(rows) -> [ReportResults(rows)]
                        Err(NotReady) -> []
                { fields: new_fields, effects, changed: Bool.true }
            else
                # Same result — no change
                { fields, effects: [], changed: Bool.false }

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

# ===== Test helpers =====

make_fields : StandingQueryPartId -> SubscribeAcrossEdgeFields
make_fields = |pid| {
    query_part_id: pid,
    edge_results: Dict.empty({}),
    edge_map: Dict.empty({}),
}

make_ctx_val : Str, I64 -> QueryContext
make_ctx_val = |k, v| Dict.insert(Dict.empty({}), k, Integer(v))

make_sq_ctx : QuineId -> SqContext
make_sq_ctx = |node_id| {
    lookup_query: |_| Err(NotFound),
    executing_node_id: node_id,
    current_properties: Dict.empty({}),
    labels_property_key: "__labels",
}

# ===== Tests =====

# Test 1: EdgeAdded matching pattern → CreateSubscription effect + Pending entry
expect
    node_a = QuineId.from_bytes([0x0A])
    node_b = QuineId.from_bytes([0x0B])
    fields = make_fields(1u64)
    ctx = make_sq_ctx(node_a)
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    event = EdgeAdded(he)
    and_then = UnitSq
    result = on_node_events(fields, [event], Ok("KNOWS"), Ok(Outgoing), and_then, ctx)
    # Should have exactly 1 CreateSubscription effect
    has_create_sub =
        when result.effects is
            [CreateSubscription(_)] -> Bool.true
            _ -> Bool.false
    key = half_edge_key(he)
    # edge_results should have the key as Pending
    is_pending =
        when Dict.get(result.fields.edge_results, key) is
            Ok(Err(Pending)) -> Bool.true
            _ -> Bool.false
    has_create_sub and is_pending

# Test 2: EdgeAdded not matching name → no effect
expect
    node_a = QuineId.from_bytes([0x0A])
    node_b = QuineId.from_bytes([0x0B])
    fields = make_fields(1u64)
    ctx = make_sq_ctx(node_a)
    he = { edge_type: "LIKES", direction: Outgoing, other: node_b }
    event = EdgeAdded(he)
    and_then = UnitSq
    result = on_node_events(fields, [event], Ok("KNOWS"), Ok(Outgoing), and_then, ctx)
    List.is_empty(result.effects) and Dict.is_empty(result.fields.edge_results)

# Test 3: EdgeAdded not matching direction → no effect
expect
    node_a = QuineId.from_bytes([0x0A])
    node_b = QuineId.from_bytes([0x0B])
    fields = make_fields(1u64)
    ctx = make_sq_ctx(node_a)
    he = { edge_type: "KNOWS", direction: Incoming, other: node_b }
    event = EdgeAdded(he)
    and_then = UnitSq
    result = on_node_events(fields, [event], Ok("KNOWS"), Ok(Outgoing), and_then, ctx)
    List.is_empty(result.effects) and Dict.is_empty(result.fields.edge_results)

# Test 4: EdgeRemoved for tracked edge → CancelSubscription effect + entry removed
expect
    node_a = QuineId.from_bytes([0x0A])
    node_b = QuineId.from_bytes([0x0B])
    and_then = UnitSq
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    key = half_edge_key(he)
    # Pre-populate with the edge as Pending
    fields : SubscribeAcrossEdgeFields
    fields = {
        query_part_id: 1u64,
        edge_results: Dict.insert(Dict.empty({}), key, Err(Pending)),
        edge_map: Dict.insert(Dict.empty({}), key, he),
    }
    ctx = make_sq_ctx(node_a)
    event = EdgeRemoved(he)
    result = on_node_events(fields, [event], Ok("KNOWS"), Ok(Outgoing), and_then, ctx)
    has_cancel =
        List.any(result.effects, |e|
            when e is
                CancelSubscription(_) -> Bool.true
                _ -> Bool.false)
    key_removed = !(Dict.contains(result.fields.edge_results, key))
    has_cancel and key_removed

# Test 5: on_subscription_result caches result for matching edge
expect
    node_b = QuineId.from_bytes([0x0B])
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    key = half_edge_key(he)
    fields : SubscribeAcrossEdgeFields
    fields = {
        query_part_id: 1u64,
        edge_results: Dict.insert(Dict.empty({}), key, Err(Pending)),
        edge_map: Dict.insert(Dict.empty({}), key, he),
    }
    result_rows = [make_ctx_val("x", 42)]
    r = on_subscription_result(
        fields,
        node_b,
        query_part_id(UnitSq),
        result_rows,
        Ok("KNOWS"),
        Ok(Outgoing),
        Dict.empty({}),
        "__labels",
    )
    r.changed
    and
    (
        when Dict.get(r.fields.edge_results, key) is
            Ok(Ok(rows)) -> List.len(rows) == 1
            _ -> Bool.false
    )

# Test 6: on_subscription_result for unknown node → no change
expect
    node_b = QuineId.from_bytes([0x0B])
    node_c = QuineId.from_bytes([0x0C])
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    key = half_edge_key(he)
    fields : SubscribeAcrossEdgeFields
    fields = {
        query_part_id: 1u64,
        edge_results: Dict.insert(Dict.empty({}), key, Err(Pending)),
        edge_map: Dict.insert(Dict.empty({}), key, he),
    }
    r = on_subscription_result(
        fields,
        node_c, # Unknown node
        query_part_id(UnitSq),
        [],
        Ok("KNOWS"),
        Ok(Outgoing),
        Dict.empty({}),
        "__labels",
    )
    r.changed == Bool.false and List.is_empty(r.effects)

# Test 7: read_results with no edges → Ok([])
expect
    fields = make_fields(1u64)
    read_results(fields, Dict.empty({}), "__labels") == Ok([])

# Test 8: read_results with all resolved → concatenated rows
expect
    node_b = QuineId.from_bytes([0x0B])
    node_c = QuineId.from_bytes([0x0C])
    he1 = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    he2 = { edge_type: "KNOWS", direction: Outgoing, other: node_c }
    key1 = half_edge_key(he1)
    key2 = half_edge_key(he2)
    rows1 = [make_ctx_val("x", 1)]
    rows2 = [make_ctx_val("x", 2)]
    fields : SubscribeAcrossEdgeFields
    fields = {
        query_part_id: 1u64,
        edge_results:
            Dict.empty({})
            |> Dict.insert(key1, Ok(rows1))
            |> Dict.insert(key2, Ok(rows2)),
        edge_map:
            Dict.empty({})
            |> Dict.insert(key1, he1)
            |> Dict.insert(key2, he2),
    }
    when read_results(fields, Dict.empty({}), "__labels") is
        Ok(rows) -> List.len(rows) == 2
        Err(_) -> Bool.false

# Test 9: read_results with Pending → NotReady
expect
    node_b = QuineId.from_bytes([0x0B])
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    key = half_edge_key(he)
    fields : SubscribeAcrossEdgeFields
    fields = {
        query_part_id: 1u64,
        edge_results: Dict.insert(Dict.empty({}), key, Err(Pending)),
        edge_map: Dict.insert(Dict.empty({}), key, he),
    }
    read_results(fields, Dict.empty({}), "__labels") == Err(NotReady)

# Test 10: AnyEdge / AnyDirection matches everything
expect
    node_a = QuineId.from_bytes([0x0A])
    node_b = QuineId.from_bytes([0x0B])
    fields = make_fields(1u64)
    ctx = make_sq_ctx(node_a)
    he = { edge_type: "WHATEVER", direction: Incoming, other: node_b }
    event = EdgeAdded(he)
    and_then = UnitSq
    result = on_node_events(fields, [event], Err(AnyEdge), Err(AnyDirection), and_then, ctx)
    List.len(result.effects) == 1

# Test 11: EdgeRemoved for untracked edge → no change
expect
    node_a = QuineId.from_bytes([0x0A])
    node_b = QuineId.from_bytes([0x0B])
    fields = make_fields(1u64)
    ctx = make_sq_ctx(node_a)
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    event = EdgeRemoved(he)
    and_then = UnitSq
    result = on_node_events(fields, [event], Ok("KNOWS"), Ok(Outgoing), and_then, ctx)
    List.is_empty(result.effects) and result.changed == Bool.false

# Test 12: on_subscription_result dedup — same result twice → changed=false second time
expect
    node_b = QuineId.from_bytes([0x0B])
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    key = half_edge_key(he)
    result_rows = [make_ctx_val("y", 99)]
    fields0 : SubscribeAcrossEdgeFields
    fields0 = {
        query_part_id: 1u64,
        edge_results: Dict.insert(Dict.empty({}), key, Err(Pending)),
        edge_map: Dict.insert(Dict.empty({}), key, he),
    }
    r1 = on_subscription_result(
        fields0,
        node_b,
        query_part_id(UnitSq),
        result_rows,
        Ok("KNOWS"),
        Ok(Outgoing),
        Dict.empty({}),
        "__labels",
    )
    r2 = on_subscription_result(
        r1.fields,
        node_b,
        query_part_id(UnitSq),
        result_rows,
        Ok("KNOWS"),
        Ok(Outgoing),
        Dict.empty({}),
        "__labels",
    )
    r1.changed and r2.changed == Bool.false

# Test 13: EdgeAdded twice for same edge → tracked only once (idempotent)
expect
    node_a = QuineId.from_bytes([0x0A])
    node_b = QuineId.from_bytes([0x0B])
    fields = make_fields(1u64)
    ctx = make_sq_ctx(node_a)
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    and_then = UnitSq
    r1 = on_node_events(fields, [EdgeAdded(he)], Ok("KNOWS"), Ok(Outgoing), and_then, ctx)
    r2 = on_node_events(r1.fields, [EdgeAdded(he)], Ok("KNOWS"), Ok(Outgoing), and_then, ctx)
    # Second addition should produce no new effects (already tracked)
    List.is_empty(r2.effects)

# Test 14: reflect — CreateSubscription targets remote node with reciprocal half-edge
expect
    node_a = QuineId.from_bytes([0x0A])
    node_b = QuineId.from_bytes([0x0B])
    fields = make_fields(1u64)
    ctx = make_sq_ctx(node_a)
    he = { edge_type: "KNOWS", direction: Outgoing, other: node_b }
    and_then = UnitSq
    result = on_node_events(fields, [EdgeAdded(he)], Ok("KNOWS"), Ok(Outgoing), and_then, ctx)
    when result.effects is
        [CreateSubscription({ on_node, query: EdgeSubscriptionReciprocal({ half_edge }) })] ->
            # Target node should be node_b
            target_ok = QuineId.to_bytes(on_node) == QuineId.to_bytes(node_b)
            # Reciprocal half-edge: direction reversed, other = node_a
            recip_dir_ok = half_edge.direction == Incoming
            recip_other_ok = QuineId.to_bytes(half_edge.other) == QuineId.to_bytes(node_a)
            target_ok and recip_dir_ok and recip_other_ok
        _ -> Bool.false
