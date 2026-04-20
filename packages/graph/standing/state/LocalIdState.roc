module [
    rehydrate,
    read_results,
    on_node_events,
]

import id.QuineId exposing [QuineId]
import model.NodeEvent exposing [NodeChangeEvent]
import model.QuineValue exposing [QuineValue]
import result.StandingQueryResult exposing [QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## LocalIdState returns the node's own ID.
## The result is pre-computed during rehydrate and held in the state.

## Pre-compute the result row for this node's ID.
##
## If `format_as_string` is true, the ID is stored as a hex string (`Str` variant).
## If false, the ID is stored as raw bytes (`Id` variant).
## Returns a single-element list containing the result row.
rehydrate : Str, Bool, QuineId -> List QueryContext
rehydrate = |aliased_as, format_as_string, node_id|
    id_value : QuineValue
    id_value =
        if format_as_string then
            Str(QuineId.to_hex_str(node_id))
        else
            Id(node_id)
    row : QueryContext
    row = Dict.insert(Dict.empty({}), aliased_as, id_value)
    [row]

## Always returns the pre-computed result list unchanged.
read_results : List QueryContext, Dict Str _, Str -> Result (List QueryContext) [NotReady]
read_results = |pre_computed_result, _properties, _labels_key|
    Ok(pre_computed_result)

## Always returns no effects and changed=false.
## LocalId never changes — the node's ID is immutable.
on_node_events : List NodeChangeEvent, SqContext -> { effects : List SqEffect, changed : Bool }
on_node_events = |_events, _ctx|
    { effects: [], changed: Bool.false }

# ===== Tests =====

# rehydrate with format_as_string=false produces Id value with correct bytes
expect
    node_id = QuineId.from_bytes([0xab, 0xcd])
    rows = rehydrate("my_id", Bool.false, node_id)
    when List.first(rows) is
        Ok(row) ->
            when Dict.get(row, "my_id") is
                Ok(Id(qid)) -> QuineId.to_bytes(qid) == [0xab, 0xcd]
                _ -> Bool.false
        Err(_) -> Bool.false

# rehydrate with format_as_string=true produces Str value
expect
    node_id = QuineId.from_bytes([0xde, 0xad])
    rows = rehydrate("node", Bool.true, node_id)
    when List.first(rows) is
        Ok(row) ->
            when Dict.get(row, "node") is
                Ok(Str(s)) -> s == "dead"
                _ -> Bool.false
        Err(_) -> Bool.false

# read_results always returns the pre-computed result
expect
    node_id = QuineId.from_bytes([0x01])
    pre_computed = rehydrate("id", Bool.false, node_id)
    result = read_results(pre_computed, Dict.empty({}), "__labels")
    when result is
        Ok(rows) -> rows == pre_computed
        Err(_) -> Bool.false

# on_node_events returns changed=false
expect
    ctx : SqContext
    ctx = {
        lookup_query: |_| Err(NotFound),
        executing_node_id: QuineId.from_bytes([0x01]),
        current_properties: Dict.empty({}),
        labels_property_key: "__labels",
    }
    result = on_node_events([], ctx)
    result.changed == Bool.false and List.len(result.effects) == 0
