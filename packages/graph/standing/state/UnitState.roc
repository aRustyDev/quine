module [
    read_results,
    on_node_events,
    on_initialize,
]

import id.QuineId
import model.NodeEvent exposing [NodeChangeEvent]
import result.StandingQueryResult exposing [QueryContext]
import SqPartState exposing [SqEffect, SqContext]

## UnitState always returns exactly one empty-row result.
## It never changes in response to graph events.

## Always returns Ok with exactly one empty QueryContext row.
read_results : Dict Str _, Str -> Result (List QueryContext) [NotReady]
read_results = |_properties, _labels_key|
    Ok([Dict.empty({})])

## Always returns no effects and changed=false.
on_node_events : List NodeChangeEvent, SqContext -> { effects : List SqEffect, changed : Bool }
on_node_events = |_events, _ctx|
    { effects: [], changed: Bool.false }

## Always returns no effects on initialization.
on_initialize : SqContext -> { effects : List SqEffect }
on_initialize = |_ctx|
    { effects: [] }

# ===== Tests =====

# read_results returns Ok with 1 empty row
expect
    when read_results(Dict.empty({}), "__labels") is
        Ok(_rows) -> Bool.true
        Err(_) -> Bool.false

# read_results result has exactly 1 entry
expect
    when read_results(Dict.empty({}), "__labels") is
        Ok(rows) -> List.len(rows) == 1
        Err(_) -> Bool.false

# on_node_events returns changed=false with no effects
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
