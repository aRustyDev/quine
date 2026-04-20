module [
    on_node_events,
    read_results,
    properties_as_quine_value,
]

import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import model.QuineValue exposing [QuineValue]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect]

## Internal state fields for an AllProperties standing query part.
AllPropertiesFields : {
    query_part_id : StandingQueryPartId,
    last_reported_properties : Result (Dict Str PropertyValue) [NeverReported],
}

## Build a QuineValue.Map from a property dictionary, excluding the labels key.
##
## Each PropertyValue is extracted to its QuineValue. If deserialization fails
## for a given property, it is represented as Null in the map.
properties_as_quine_value : Dict Str PropertyValue, Str -> QuineValue
properties_as_quine_value = |properties, labels_key|
    filtered =
        Dict.keep_if(properties, |(k, _v)| k != labels_key)
    qv_map =
        Dict.map(filtered, |_k, pv|
            when PropertyValue.get_value(pv) is
                Ok(qv) -> qv
                Err(_) -> Null
        )
    Map(qv_map)

## Check if two property dictionaries are equal (by value comparison).
##
## Uses structural equality on the extracted QuineValues.
properties_equal : Dict Str PropertyValue, Dict Str PropertyValue -> Bool
properties_equal = |a, b|
    Dict.len(a) == Dict.len(b)
    && Dict.walk_until(
        a,
        Bool.true,
        |_, k, av|
            when Dict.get(b, k) is
                Ok(bv) ->
                    if property_values_equal(av, bv) then
                        Continue(Bool.true)
                    else
                        Break(Bool.false)
                Err(_) -> Break(Bool.false),
    )

## Check if two PropertyValues represent the same value.
property_values_equal : PropertyValue, PropertyValue -> Bool
property_values_equal = |pv1, pv2|
    when (PropertyValue.get_value(pv1), PropertyValue.get_value(pv2)) is
        (Ok(v1), Ok(v2)) -> quine_value_eq(v1, v2)
        (Err(_), Err(_)) -> Bool.true
        _ -> Bool.false

## Structural equality for QuineValue.
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

import id.QuineId

## Process a list of node change events for an AllProperties standing query.
##
## Reports a result whenever any non-labels property changes (and the change
## is not a dedup of the last reported state). Labels-only changes are ignored.
on_node_events :
    AllPropertiesFields,
    List NodeChangeEvent,
    Str,              # aliased_as
    Str,              # labels_key
    Dict Str PropertyValue   # current_properties
    -> { fields : AllPropertiesFields, effects : List SqEffect, changed : Bool }
on_node_events = |fields, events, aliased_as, labels_key, current_properties|
    # Check if any event is a property change for a key other than labels_key
    has_non_labels_change =
        List.any(events, |event|
            when event is
                PropertySet({ key }) -> key != labels_key
                PropertyRemoved({ key }) -> key != labels_key
                _ -> Bool.false
        )

    if has_non_labels_change then
        # Check if properties changed since last report (dedup)
        props_without_labels =
            Dict.keep_if(current_properties, |(k, _v)| k != labels_key)

        props_changed =
            when fields.last_reported_properties is
                Err(NeverReported) -> Bool.true
                Ok(prev) ->
                    # Compare previous (without labels) against current (without labels)
                    prev_without_labels =
                        Dict.keep_if(prev, |(k, _v)| k != labels_key)
                    !(properties_equal(prev_without_labels, props_without_labels))

        new_fields = {
            query_part_id: fields.query_part_id,
            last_reported_properties: Ok(current_properties),
        }

        if props_changed then
            row : QueryContext
            row = Dict.insert(
                Dict.empty({}),
                aliased_as,
                properties_as_quine_value(current_properties, labels_key),
            )
            { fields: new_fields, effects: [ReportResults([row])], changed: Bool.true }
        else
            # Properties unchanged (dedup)
            { fields: new_fields, effects: [], changed: Bool.false }
    else
        # No non-labels property changes: no effect
        { fields, effects: [], changed: Bool.false }

## Read the current property map result from a property snapshot (e.g. on node wake-up).
##
## Always returns Ok with one result row containing the current properties (minus labels).
read_results : Dict Str PropertyValue, Str, Str -> Result (List QueryContext) [NotReady]
read_results = |properties, aliased_as, labels_key|
    row : QueryContext
    row = Dict.insert(
        Dict.empty({}),
        aliased_as,
        properties_as_quine_value(properties, labels_key),
    )
    Ok([row])

# ===== Tests =====

# Helper: build initial (NeverReported) fields
make_fields : StandingQueryPartId -> AllPropertiesFields
make_fields = |pid| {
    query_part_id: pid,
    last_reported_properties: Err(NeverReported),
}

# Test 1: properties_as_quine_value excludes labels key
expect
    props =
        Dict.empty({})
        |> Dict.insert("name", PropertyValue.from_value(Str("Alice")))
        |> Dict.insert("__labels", PropertyValue.from_value(List([Str("Person")])))
    result = properties_as_quine_value(props, "__labels")
    when result is
        Map(m) ->
            Dict.contains(m, "name") && !(Dict.contains(m, "__labels"))
        _ -> Bool.false

# Test 2: Property change triggers report
expect
    fields = make_fields(1u64)
    current_props =
        Dict.empty({})
        |> Dict.insert("name", PropertyValue.from_value(Str("Alice")))
    events = [PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })]
    result = on_node_events(fields, events, "props", "__labels", current_props)
    when result.effects is
        [ReportResults([row])] ->
            Dict.contains(row, "props")
        _ -> Bool.false

# Test 3: Labels change does NOT trigger report
expect
    fields = make_fields(1u64)
    current_props =
        Dict.empty({})
        |> Dict.insert("name", PropertyValue.from_value(Str("Alice")))
        |> Dict.insert("__labels", PropertyValue.from_value(List([Str("Person")])))
    events = [PropertySet({ key: "__labels", value: PropertyValue.from_value(List([Str("Admin")])) })]
    result = on_node_events(fields, events, "props", "__labels", current_props)
    List.len(result.effects) == 0

# Test 4: Same properties as last report → no change (dedup)
expect
    name_pv = PropertyValue.from_value(Str("Alice"))
    current_props = Dict.insert(Dict.empty({}), "name", name_pv)
    fields0 = make_fields(1u64)
    events = [PropertySet({ key: "name", value: name_pv })]
    # First call: reports
    r1 = on_node_events(fields0, events, "props", "__labels", current_props)
    # Second call: same properties, same events → should dedup
    r2 = on_node_events(r1.fields, events, "props", "__labels", current_props)
    List.len(r2.effects) == 0

# Test 5: read_results returns current properties excluding labels
expect
    props =
        Dict.empty({})
        |> Dict.insert("age", PropertyValue.from_value(Integer(30)))
        |> Dict.insert("__labels", PropertyValue.from_value(List([Str("Person")])))
    result = read_results(props, "p", "__labels")
    when result is
        Ok([row]) ->
            when Dict.get(row, "p") is
                Ok(Map(m)) ->
                    Dict.contains(m, "age") && !(Dict.contains(m, "__labels"))
                _ -> Bool.false
        _ -> Bool.false

# Test 6: read_results with empty properties → empty Map
expect
    result = read_results(Dict.empty({}), "all_props", "__labels")
    when result is
        Ok([row]) ->
            when Dict.get(row, "all_props") is
                Ok(Map(m)) -> Dict.len(m) == 0
                _ -> Bool.false
        _ -> Bool.false

# Test 7: Multiple properties are all included in the result map
expect
    props =
        Dict.empty({})
        |> Dict.insert("x", PropertyValue.from_value(Integer(1)))
        |> Dict.insert("y", PropertyValue.from_value(Integer(2)))
        |> Dict.insert("z", PropertyValue.from_value(Integer(3)))
    result = properties_as_quine_value(props, "__labels")
    when result is
        Map(m) -> Dict.len(m) == 3
        _ -> Bool.false
