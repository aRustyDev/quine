module [
    SqPartState,
    SqEffect,
    SqContext,
    SubscriptionResult,
    SqSubscription,
    SqMsgSubscriber,
    create_state,
]

import ast.MvStandingQuery exposing [MvStandingQuery]
import result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId, QueryContext]
import id.QuineId exposing [QuineId]
import model.PropertyValue exposing [PropertyValue]
import model.HalfEdge exposing [HalfEdge]

## The per-node per-query-part state for one vertex of an MVSQ evaluation.
##
## Each variant corresponds to one MvStandingQuery variant. The state stores
## only what is needed to decide whether a subsequent graph event changes
## the match status.
SqPartState : [
    ## UnitSq always matches — no state needed.
    UnitState,
    ## Cross: accumulates child results per StandingQueryPartId.
    CrossState {
        query_part_id : StandingQueryPartId,
        results_accumulator : Dict StandingQueryPartId (Result (List QueryContext) [Pending]),
    },
    ## LocalProperty: remembers what value and match status were last reported.
    LocalPropertyState {
        query_part_id : StandingQueryPartId,
        value_at_last_report : Result (Result PropertyValue [Absent]) [NeverReported],
        last_report_was_match : Result Bool [NeverReported],
    },
    ## Labels: remembers the last reported label set and match status.
    LabelsState {
        query_part_id : StandingQueryPartId,
        last_reported_labels : Result (List Str) [NeverReported],
        last_report_was_match : Result Bool [NeverReported],
    },
    ## LocalId: holds one pre-computed result row (the node's own ID).
    LocalIdState {
        query_part_id : StandingQueryPartId,
        result : List QueryContext,
    },
    ## AllProperties: remembers the last reported property map.
    AllPropertiesState {
        query_part_id : StandingQueryPartId,
        last_reported_properties : Result (Dict Str PropertyValue) [NeverReported],
    },
    ## SubscribeAcrossEdge: accumulates per-half-edge child results.
    ## Keys are serialized HalfEdge strings (type:dir:hex) to avoid needing
    ## Hash on the opaque QuineId inside HalfEdge.
    SubscribeAcrossEdgeState {
        query_part_id : StandingQueryPartId,
        edge_results : Dict Str (Result (List QueryContext) [Pending]),
        edge_map : Dict Str HalfEdge,
    },
    ## EdgeSubscriptionReciprocal: tracks whether the remote sub-query matches.
    EdgeSubscriptionReciprocalState {
        query_part_id : StandingQueryPartId,
        half_edge : HalfEdge,
        and_then_id : StandingQueryPartId,
        currently_matching : Bool,
        cached_result : Result (List QueryContext) [NoCachedResult],
    },
    ## FilterMap: caches the filtered/projected result list.
    FilterMapState {
        query_part_id : StandingQueryPartId,
        kept_results : Result (List QueryContext) [NoCachedResult],
    },
]

## A side-effect emitted by standing-query state transitions.
SqEffect : [
    ## Ask the platform to subscribe node `on_node` to the given query.
    CreateSubscription {
        on_node : QuineId,
        query : MvStandingQuery,
        global_id : StandingQueryId,
        subscriber_part_id : StandingQueryPartId,
    },
    ## Cancel a subscription previously created on `on_node`.
    CancelSubscription {
        on_node : QuineId,
        query_part_id : StandingQueryPartId,
        global_id : StandingQueryId,
    },
    ## Emit a set of result rows to the top-level standing query consumer.
    ReportResults (List QueryContext),
]

## Read-only context threaded through MVSQ state-transition functions.
SqContext : {
    ## Resolve a StandingQueryPartId to its compiled query (for subscriptions).
    lookup_query : StandingQueryPartId -> Result MvStandingQuery [NotFound],
    ## The node currently executing the state transition.
    executing_node_id : QuineId,
    ## Snapshot of the node's current properties (key -> PropertyValue).
    current_properties : Dict Str PropertyValue,
    ## The special property key under which node labels are stored.
    labels_property_key : Str,
}

## A subscription result message delivered to a subscriber node.
SubscriptionResult : {
    ## The node that produced this result.
    from : QuineId,
    ## The query part that produced this result.
    query_part_id : StandingQueryPartId,
    ## The top-level standing query this result belongs to.
    global_id : StandingQueryId,
    ## The query part on the receiving node that should handle this result.
    for_query_part_id : StandingQueryPartId,
    ## The result rows being delivered.
    result_group : List QueryContext,
}

## Identifies who should receive a standing-query result notification.
SqMsgSubscriber : [
    ## Another node in the graph that is waiting for this sub-query's results.
    NodeSubscriber {
        subscribing_node : QuineId,
        global_id : StandingQueryId,
        query_part_id : StandingQueryPartId,
    },
    ## A top-level (global) standing query result consumer.
    GlobalSubscriber { global_id : StandingQueryId },
]

## Links a query part to its current set of subscribers.
SqSubscription : {
    for_query : StandingQueryPartId,
    global_id : StandingQueryId,
    subscribers : List SqMsgSubscriber,
}

## Construct the initial SqPartState for the given MvStandingQuery variant.
##
## The state is uninitialised — it does not yet reflect any graph events.
## Tasks 5-9 will add the state-transition functions that mutate this value.
create_state : MvStandingQuery -> SqPartState
create_state = |query|
    pid = MvStandingQuery.query_part_id(query)
    when query is
        UnitSq ->
            UnitState

        Cross(_) ->
            CrossState({
                query_part_id: pid,
                results_accumulator: Dict.empty({}),
            })

        LocalProperty(_) ->
            LocalPropertyState({
                query_part_id: pid,
                value_at_last_report: Err(NeverReported),
                last_report_was_match: Err(NeverReported),
            })

        Labels(_) ->
            LabelsState({
                query_part_id: pid,
                last_reported_labels: Err(NeverReported),
                last_report_was_match: Err(NeverReported),
            })

        LocalId({ aliased_as }) ->
            # Pre-seed the result with a single empty context row keyed by the alias.
            # The actual ID value is filled in during state transitions (Task 5+).
            initial_row : QueryContext
            initial_row = Dict.insert(Dict.empty({}), aliased_as, Null)
            LocalIdState({
                query_part_id: pid,
                result: [initial_row],
            })

        AllProperties(_) ->
            AllPropertiesState({
                query_part_id: pid,
                last_reported_properties: Err(NeverReported),
            })

        SubscribeAcrossEdge(_) ->
            SubscribeAcrossEdgeState({
                query_part_id: pid,
                edge_results: Dict.empty({}),
                edge_map: Dict.empty({}),
            })

        EdgeSubscriptionReciprocal({ half_edge, and_then_id }) ->
            EdgeSubscriptionReciprocalState({
                query_part_id: pid,
                half_edge,
                and_then_id,
                currently_matching: Bool.false,
                cached_result: Err(NoCachedResult),
            })

        FilterMap(_) ->
            FilterMapState({
                query_part_id: pid,
                kept_results: Err(NoCachedResult),
            })

# ===== Tests =====

# UnitSq always produces UnitState
expect
    when create_state(UnitSq) is
        UnitState -> Bool.true
        _ -> Bool.false

# LocalProperty starts with NeverReported on both fields
expect
    lp = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Err(NoAlias) })
    when create_state(lp) is
        LocalPropertyState({ value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }) ->
            Bool.true
        _ -> Bool.false

# LocalId starts with exactly one result row keyed by aliased_as
expect
    li = LocalId({ aliased_as: "my_id", format_as_string: Bool.false })
    when create_state(li) is
        LocalIdState({ result }) ->
            List.len(result) == 1
        _ -> Bool.false

# Cross starts with an empty results_accumulator
expect
    cross = Cross({ queries: [UnitSq], emit_subscriptions_lazily: Bool.false })
    when create_state(cross) is
        CrossState({ results_accumulator }) ->
            Dict.len(results_accumulator) == 0
        _ -> Bool.false

# EdgeSubscriptionReciprocal starts with currently_matching = false and NoCachedResult
expect
    he = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x01]) }
    esr = EdgeSubscriptionReciprocal({ half_edge: he, and_then_id: 42u64 })
    when create_state(esr) is
        EdgeSubscriptionReciprocalState({ currently_matching, cached_result: Err(NoCachedResult) }) ->
            currently_matching == Bool.false
        _ -> Bool.false

# Labels starts with NeverReported on both fields
expect
    labels_sq = Labels({ aliased_as: Err(NoAlias), constraint: Unconditional })
    when create_state(labels_sq) is
        LabelsState({ last_reported_labels: Err(NeverReported), last_report_was_match: Err(NeverReported) }) ->
            Bool.true
        _ -> Bool.false

# AllProperties starts with NeverReported
expect
    ap = AllProperties({ aliased_as: "props" })
    when create_state(ap) is
        AllPropertiesState({ last_reported_properties: Err(NeverReported) }) ->
            Bool.true
        _ -> Bool.false

# SubscribeAcrossEdge starts with empty edge_results and edge_map
expect
    sae = SubscribeAcrossEdge({ edge_name: Ok("KNOWS"), edge_direction: Ok(Outgoing), and_then: UnitSq })
    when create_state(sae) is
        SubscribeAcrossEdgeState({ edge_results, edge_map }) ->
            Dict.len(edge_results) == 0 && Dict.len(edge_map) == 0
        _ -> Bool.false

# FilterMap starts with NoCachedResult
expect
    fm = FilterMap({ condition: Err(NoFilter), to_filter: UnitSq, drop_existing: Bool.false, to_add: [] })
    when create_state(fm) is
        FilterMapState({ kept_results: Err(NoCachedResult) }) ->
            Bool.true
        _ -> Bool.false
