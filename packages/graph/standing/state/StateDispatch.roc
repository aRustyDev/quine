module [
    dispatch_on_initialize,
    dispatch_on_node_events,
    dispatch_on_subscription_result,
    dispatch_read_results,
]

import SqPartState exposing [SqPartState, SqEffect, SqContext, SubscriptionResult]
import UnitState
import LocalIdState
import LocalPropertyState
import LabelsState
import AllPropertiesState
import CrossState
import SubscribeAcrossEdgeState
import EdgeSubscriptionReciprocalState
import FilterMapState
import ast.MvStandingQuery exposing [MvStandingQuery, query_part_id]
import result.StandingQueryResult exposing [QueryContext]
import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import id.QuineId exposing [QuineId]

## Route on_initialize to the correct state module.
##
## Returns an updated SqPartState and any emitted SqEffects.
dispatch_on_initialize : SqPartState, MvStandingQuery, SqContext -> { state : SqPartState, effects : List SqEffect }
dispatch_on_initialize = |state, query, ctx|
    when state is
        UnitState ->
            result = UnitState.on_initialize(ctx)
            { state: UnitState, effects: result.effects }

        CrossState(fields) ->
            when query is
                Cross({ queries, emit_subscriptions_lazily }) ->
                    result = CrossState.on_initialize(fields, queries, emit_subscriptions_lazily, ctx)
                    { state: CrossState(result.fields), effects: result.effects }

                _ ->
                    { state, effects: [] }

        FilterMapState(fields) ->
            when query is
                FilterMap({ to_filter }) ->
                    result = FilterMapState.on_initialize(fields, to_filter, ctx)
                    { state: FilterMapState(result.fields), effects: result.effects }

                _ ->
                    { state, effects: [] }

        # These variants have no init-time subscriptions to create.
        LocalPropertyState(_) -> { state, effects: [] }
        LabelsState(_) -> { state, effects: [] }
        LocalIdState(_) -> { state, effects: [] }
        AllPropertiesState(_) -> { state, effects: [] }
        SubscribeAcrossEdgeState(_) -> { state, effects: [] }
        EdgeSubscriptionReciprocalState(_) -> { state, effects: [] }

## Route on_node_events to the correct state module.
##
## Returns an updated SqPartState, emitted effects, and whether state changed.
dispatch_on_node_events :
    SqPartState,
    List NodeChangeEvent,
    MvStandingQuery,
    SqContext
    -> { state : SqPartState, effects : List SqEffect, changed : Bool }
dispatch_on_node_events = |state, events, query, ctx|
    when state is
        LocalPropertyState(fields) ->
            when query is
                LocalProperty({ prop_key, constraint, aliased_as }) ->
                    result = LocalPropertyState.on_node_events(fields, events, prop_key, constraint, aliased_as)
                    { state: LocalPropertyState(result.fields), effects: result.effects, changed: result.changed }

                _ ->
                    { state, effects: [], changed: Bool.false }

        LabelsState(fields) ->
            when query is
                Labels({ constraint, aliased_as }) ->
                    result = LabelsState.on_node_events(fields, events, ctx.labels_property_key, constraint, aliased_as)
                    { state: LabelsState(result.fields), effects: result.effects, changed: result.changed }

                _ ->
                    { state, effects: [], changed: Bool.false }

        AllPropertiesState(fields) ->
            when query is
                AllProperties({ aliased_as }) ->
                    result = AllPropertiesState.on_node_events(fields, events, aliased_as, ctx.labels_property_key, ctx.current_properties)
                    { state: AllPropertiesState(result.fields), effects: result.effects, changed: result.changed }

                _ ->
                    { state, effects: [], changed: Bool.false }

        SubscribeAcrossEdgeState(fields) ->
            when query is
                SubscribeAcrossEdge({ edge_name, edge_direction, and_then }) ->
                    result = SubscribeAcrossEdgeState.on_node_events(fields, events, edge_name, edge_direction, and_then, ctx)
                    { state: SubscribeAcrossEdgeState(result.fields), effects: result.effects, changed: result.changed }

                _ ->
                    { state, effects: [], changed: Bool.false }

        EdgeSubscriptionReciprocalState(fields) ->
            result = EdgeSubscriptionReciprocalState.on_node_events(fields, events, ctx)
            { state: EdgeSubscriptionReciprocalState(result.fields), effects: result.effects, changed: result.changed }

        # These variants do not respond to node events.
        UnitState -> { state, effects: [], changed: Bool.false }
        CrossState(_) -> { state, effects: [], changed: Bool.false }
        LocalIdState(_) -> { state, effects: [], changed: Bool.false }
        FilterMapState(_) -> { state, effects: [], changed: Bool.false }

## Route on_subscription_result to the correct state module.
##
## Returns an updated SqPartState, emitted effects, and whether state changed.
dispatch_on_subscription_result :
    SqPartState,
    SubscriptionResult,
    MvStandingQuery,
    SqContext
    -> { state : SqPartState, effects : List SqEffect, changed : Bool }
dispatch_on_subscription_result = |state, sub_result, query, ctx|
    when state is
        CrossState(fields) ->
            when query is
                Cross({ queries, emit_subscriptions_lazily }) ->
                    result = CrossState.on_subscription_result(
                        fields,
                        sub_result.query_part_id,
                        sub_result.result_group,
                        queries,
                        emit_subscriptions_lazily,
                        ctx,
                    )
                    { state: CrossState(result.fields), effects: result.effects, changed: result.changed }

                _ ->
                    { state, effects: [], changed: Bool.false }

        SubscribeAcrossEdgeState(fields) ->
            when query is
                SubscribeAcrossEdge({ edge_name, edge_direction }) ->
                    result = SubscribeAcrossEdgeState.on_subscription_result(
                        fields,
                        sub_result.from,
                        sub_result.query_part_id,
                        sub_result.result_group,
                        edge_name,
                        edge_direction,
                        ctx.current_properties,
                        ctx.labels_property_key,
                    )
                    { state: SubscribeAcrossEdgeState(result.fields), effects: result.effects, changed: result.changed }

                _ ->
                    { state, effects: [], changed: Bool.false }

        EdgeSubscriptionReciprocalState(fields) ->
            result = EdgeSubscriptionReciprocalState.on_subscription_result(fields, sub_result.result_group)
            { state: EdgeSubscriptionReciprocalState(result.fields), effects: result.effects, changed: result.changed }

        FilterMapState(fields) ->
            when query is
                FilterMap({ drop_existing }) ->
                    ## NOTE: MvStandingQuery.Expr is a placeholder [ExprPlaceholder] and is
                    ## structurally incompatible with expr.Expr (the real expression type
                    ## used by FilterMapState). Until the AST is upgraded to use the real
                    ## Expr type, we pass Err(NoFilter) for the condition and [] for to_add,
                    ## which causes all rows to pass through without filtering or projection.
                    result = FilterMapState.on_subscription_result(
                        fields,
                        sub_result.result_group,
                        Err(NoFilter),
                        drop_existing,
                        [],
                        ctx,
                    )
                    { state: FilterMapState(result.fields), effects: result.effects, changed: result.changed }

                _ ->
                    { state, effects: [], changed: Bool.false }

        # These variants do not process subscription results.
        UnitState -> { state, effects: [], changed: Bool.false }
        LocalPropertyState(_) -> { state, effects: [], changed: Bool.false }
        LabelsState(_) -> { state, effects: [], changed: Bool.false }
        LocalIdState(_) -> { state, effects: [], changed: Bool.false }
        AllPropertiesState(_) -> { state, effects: [], changed: Bool.false }

## Route read_results to the correct state module.
##
## Returns Ok(List QueryContext) if state is ready, Err(NotReady) otherwise.
dispatch_read_results :
    SqPartState,
    MvStandingQuery,
    Dict Str PropertyValue,
    Str
    -> Result (List QueryContext) [NotReady]
dispatch_read_results = |state, query, properties, labels_key|
    when state is
        UnitState ->
            UnitState.read_results(properties, labels_key)

        LocalIdState({ result }) ->
            LocalIdState.read_results(result, properties, labels_key)

        LocalPropertyState(_fields) ->
            when query is
                LocalProperty({ prop_key, constraint, aliased_as }) ->
                    LocalPropertyState.read_results(properties, prop_key, constraint, aliased_as)

                _ ->
                    Err(NotReady)

        LabelsState(_) ->
            when query is
                Labels({ constraint, aliased_as }) ->
                    LabelsState.read_results(properties, labels_key, constraint, aliased_as)

                _ ->
                    Err(NotReady)

        AllPropertiesState(_) ->
            when query is
                AllProperties({ aliased_as }) ->
                    AllPropertiesState.read_results(properties, aliased_as, labels_key)

                _ ->
                    Err(NotReady)

        CrossState(fields) ->
            when query is
                Cross({ queries }) ->
                    CrossState.read_results(fields, queries, properties, labels_key)

                _ ->
                    Err(NotReady)

        SubscribeAcrossEdgeState(fields) ->
            SubscribeAcrossEdgeState.read_results(fields, properties, labels_key)

        EdgeSubscriptionReciprocalState(fields) ->
            EdgeSubscriptionReciprocalState.read_results(fields, properties, labels_key)

        FilterMapState(fields) ->
            FilterMapState.read_results(fields, properties, labels_key)

# ===== Tests =====

# Helper: build SqContext
make_ctx : QuineId -> SqContext
make_ctx = |node_id| {
    lookup_query: |_| Err(NotFound),
    executing_node_id: node_id,
    current_properties: Dict.empty({}),
    labels_property_key: "__labels",
}

# Test 1: dispatch_on_initialize for UnitState → no effects
expect
    ctx = make_ctx(QuineId.from_bytes([0x01]))
    result = dispatch_on_initialize(UnitState, UnitSq, ctx)
    List.len(result.effects) == 0
    &&
    (when result.state is
        UnitState -> Bool.true
        _ -> Bool.false)

# Test 2: dispatch_on_initialize for CrossState with 2 queries → 2 CreateSubscription effects
expect
    ctx = make_ctx(QuineId.from_bytes([0x01]))
    q1 = UnitSq
    q2 : MvStandingQuery
    q2 = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Err(NoAlias) })
    cross_query = Cross({ queries: [q1, q2], emit_subscriptions_lazily: Bool.false })
    pid = query_part_id(cross_query)
    cross_state = CrossState({
        query_part_id: pid,
        results_accumulator: Dict.empty({}),
    })
    result = dispatch_on_initialize(cross_state, cross_query, ctx)
    List.len(result.effects) == 2
    &&
    List.all(result.effects, |e|
        when e is
            CreateSubscription(_) -> Bool.true
            _ -> Bool.false
    )

# Test 3: dispatch_on_node_events for LocalPropertyState with matching PropertySet → effects
expect
    ctx = make_ctx(QuineId.from_bytes([0x01]))
    lp_query = LocalProperty({ prop_key: "score", constraint: Any, aliased_as: Ok("s") })
    pid = query_part_id(lp_query)
    lp_state = LocalPropertyState({
        query_part_id: pid,
        value_at_last_report: Err(NeverReported),
        last_report_was_match: Err(NeverReported),
    })
    events = [PropertySet({ key: "score", value: PropertyValue.from_value(Integer(42)) })]
    result = dispatch_on_node_events(lp_state, events, lp_query, ctx)
    # First match on an aliased property → ReportResults emitted
    List.len(result.effects) == 1

# Test 4: dispatch_on_subscription_result for CrossState → caches result and may report
expect
    ctx = make_ctx(QuineId.from_bytes([0x01]))
    q1 = UnitSq
    pid1 = query_part_id(q1)
    cross_query = Cross({ queries: [q1], emit_subscriptions_lazily: Bool.false })
    pid_cross = query_part_id(cross_query)
    cross_state = CrossState({
        query_part_id: pid_cross,
        results_accumulator: Dict.insert(Dict.empty({}), pid1, Err(Pending)),
    })
    sub_result : SubscriptionResult
    sub_result = {
        from: QuineId.from_bytes([0x02]),
        query_part_id: pid1,
        global_id: 0u128,
        for_query_part_id: pid_cross,
        result_group: [Dict.empty({})],
    }
    result = dispatch_on_subscription_result(cross_state, sub_result, cross_query, ctx)
    # Single child, result arrived → should report cross product
    result.changed == Bool.true

# Test 5: dispatch_read_results for UnitState → Ok with one empty row
expect
    result = dispatch_read_results(UnitState, UnitSq, Dict.empty({}), "__labels")
    when result is
        Ok(rows) -> List.len(rows) == 1
        Err(_) -> Bool.false

# Test 6: dispatch_read_results for LocalIdState → Ok with the pre-computed result
expect
    node_id = QuineId.from_bytes([0xAB, 0xCD])
    rows = LocalIdState.rehydrate("id", Bool.false, node_id)
    li_query = LocalId({ aliased_as: "id", format_as_string: Bool.false })
    pid = query_part_id(li_query)
    li_state = LocalIdState({
        query_part_id: pid,
        result: rows,
    })
    result = dispatch_read_results(li_state, li_query, Dict.empty({}), "__labels")
    when result is
        Ok(out_rows) -> List.len(out_rows) == 1
        Err(_) -> Bool.false
