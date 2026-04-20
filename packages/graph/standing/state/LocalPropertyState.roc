module [
    on_node_events,
    read_results,
]

import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import model.QuineValue exposing [QuineValue]
import ast.ValueConstraint exposing [ValueConstraint, check_value, satisfied_by_none]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect]
import id.QuineId

## Internal state fields for a LocalProperty standing query part.
LocalPropertyFields : {
    query_part_id : StandingQueryPartId,
    value_at_last_report : Result (Result PropertyValue [Absent]) [NeverReported],
    last_report_was_match : Result Bool [NeverReported],
}

## Check if two PropertyValues represent the same value, using QuineValue equality.
##
## Falls back to comparing extracted QuineValues to avoid issues with opaque
## type equality across package boundaries.
property_values_equal : PropertyValue, PropertyValue -> Bool
property_values_equal = |pv1, pv2|
    when (PropertyValue.get_value(pv1), PropertyValue.get_value(pv2)) is
        (Ok(v1), Ok(v2)) -> quine_value_eq(v1, v2)
        (Err(_), Err(_)) -> Bool.true
        _ -> Bool.false

## Structural equality for QuineValue, needed because Eq may not be derivable
## across package boundaries for recursive types containing opaque types.
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

## Check if a current property value (present or absent) satisfies the constraint.
check_current : ValueConstraint, Result PropertyValue [Absent] -> Bool
check_current = |constraint, current|
    when current is
        Err(Absent) -> satisfied_by_none(constraint)
        Ok(pv) ->
            when PropertyValue.get_value(pv) is
                Ok(qv) ->
                    when check_value(constraint, qv) is
                        Ok(matches) -> matches
                        Err(RegexNotSupported) -> Bool.false
                Err(_) -> Bool.false

## Build the result row for an aliased match with a given PropertyValue.
make_aliased_row : Str, PropertyValue -> QueryContext
make_aliased_row = |alias, pv|
    when PropertyValue.get_value(pv) is
        Ok(qv) -> Dict.insert(Dict.empty({}), alias, qv)
        Err(_) -> Dict.insert(Dict.empty({}), alias, Null)

## Process a list of node change events for a LocalProperty standing query.
##
## Filters events for the watched `prop_key`, determines whether the current
## value satisfies the constraint, and emits effects only when match status
## or (for aliased queries) the value itself changes.
on_node_events :
    LocalPropertyFields,
    List NodeChangeEvent,
    Str,
    ValueConstraint,
    Result Str [NoAlias]
    -> { fields : LocalPropertyFields, effects : List SqEffect, changed : Bool }
on_node_events = |fields, events, prop_key, constraint, aliased_as|
    # Find the last relevant event for our property key
    relevant =
        List.walk(events, Err(NoEvent), |acc, event|
            when event is
                PropertySet({ key, value }) if key == prop_key ->
                    Ok(Ok(value))
                PropertyRemoved({ key }) if key == prop_key ->
                    Ok(Err(Absent))
                _ -> acc
        )

    when relevant is
        Err(NoEvent) ->
            # No relevant event. If we have never reported, initialize with absent/no-match.
            when fields.last_report_was_match is
                Err(NeverReported) ->
                    # Initialize: treat as if property is absent
                    current : Result PropertyValue [Absent]
                    current = Err(Absent)
                    matches = check_current(constraint, current)
                    new_fields = {
                        query_part_id: fields.query_part_id,
                        value_at_last_report: Ok(current),
                        last_report_was_match: Ok(matches),
                    }
                    { fields: new_fields, effects: [], changed: Bool.false }

                Ok(_) ->
                    # Already initialized, no event → no change
                    { fields, effects: [], changed: Bool.false }

        Ok(current_property) ->
            matches = check_current(constraint, current_property)

            when aliased_as is
                Ok(alias) ->
                    # With alias: emit when value changes AND matches, or cancel when stops matching
                    value_changed =
                        when fields.value_at_last_report is
                            Err(NeverReported) -> Bool.true
                            Ok(prev) ->
                                when (prev, current_property) is
                                    (Err(Absent), Err(Absent)) -> Bool.false
                                    (Ok(pv1), Ok(pv2)) -> !(property_values_equal(pv1, pv2))
                                    _ -> Bool.true

                    new_fields = {
                        query_part_id: fields.query_part_id,
                        value_at_last_report: Ok(current_property),
                        last_report_was_match: Ok(matches),
                    }

                    if matches && value_changed then
                        # Value changed and still (or newly) matching: emit result row
                        row =
                            when current_property is
                                Ok(pv) -> make_aliased_row(alias, pv)
                                Err(Absent) -> Dict.empty({})
                        { fields: new_fields, effects: [ReportResults([row])], changed: Bool.true }
                    else if !(matches) then
                        # Not matching: check if we were previously matching or unknown
                        was_matching =
                            when fields.last_report_was_match is
                                Err(NeverReported) -> Bool.false
                                Ok(b) -> b
                        if was_matching then
                            # Cancellation: emit empty results
                            { fields: new_fields, effects: [ReportResults([])], changed: Bool.true }
                        else
                            # Was already not matching, no change
                            { fields: new_fields, effects: [], changed: Bool.false }
                    else
                        # Matching but value unchanged (dedup)
                        { fields: new_fields, effects: [], changed: Bool.false }

                Err(NoAlias) ->
                    # Without alias: emit only when match status changes
                    prev_was_match =
                        when fields.last_report_was_match is
                            Err(NeverReported) -> Err(NeverReported)
                            Ok(b) -> Ok(b)

                    new_fields = {
                        query_part_id: fields.query_part_id,
                        value_at_last_report: Ok(current_property),
                        last_report_was_match: Ok(matches),
                    }

                    status_changed =
                        when prev_was_match is
                            Err(NeverReported) -> Bool.true
                            Ok(b) -> b != matches

                    if status_changed then
                        if matches then
                            # Newly matching: emit one empty positive row
                            { fields: new_fields, effects: [ReportResults([Dict.empty({})])], changed: Bool.true }
                        else
                            # Stopped matching: emit empty cancellation
                            { fields: new_fields, effects: [ReportResults([])], changed: Bool.true }
                    else
                        # Status unchanged
                        { fields: new_fields, effects: [], changed: Bool.false }

## Read the current match result for a LocalProperty standing query from
## a property snapshot (e.g. on node wake-up).
read_results :
    Dict Str PropertyValue,
    Str,
    ValueConstraint,
    Result Str [NoAlias]
    -> Result (List QueryContext) [NotReady]
read_results = |properties, prop_key, constraint, aliased_as|
    current : Result PropertyValue [Absent]
    current =
        when Dict.get(properties, prop_key) is
            Ok(pv) -> Ok(pv)
            Err(_) -> Err(Absent)

    matches = check_current(constraint, current)

    if matches then
        when aliased_as is
            Ok(alias) ->
                row =
                    when current is
                        Ok(pv) -> make_aliased_row(alias, pv)
                        Err(Absent) -> Dict.empty({})
                Ok([row])

            Err(NoAlias) ->
                Ok([Dict.empty({})])
    else
        Ok([])

# ===== Tests =====

# Helper: build initial (NeverReported) fields
make_fields : StandingQueryPartId -> LocalPropertyFields
make_fields = |pid| {
    query_part_id: pid,
    value_at_last_report: Err(NeverReported),
    last_report_was_match: Err(NeverReported),
}

# Test 1: PropertySet matching Equal constraint → reports result with alias
expect
    fields = make_fields(1u64)
    events = [PropertySet({ key: "name", value: PropertyValue.from_value(Str("Alice")) })]
    result = on_node_events(fields, events, "name", Equal(Str("Alice")), Ok("n"))
    when result.effects is
        [ReportResults([row])] ->
            when Dict.get(row, "n") is
                Ok(Str("Alice")) -> Bool.true
                _ -> Bool.false
        _ -> Bool.false

# Test 2: PropertySet not matching Equal constraint → reports empty (cancellation-ready)
# Since NeverReported + not matching → no effect (was_matching is false)
expect
    fields = make_fields(1u64)
    events = [PropertySet({ key: "name", value: PropertyValue.from_value(Str("Bob")) })]
    result = on_node_events(fields, events, "name", Equal(Str("Alice")), Ok("n"))
    List.len(result.effects) == 0

# Test 3: No alias: first event matching → empty positive row emitted
expect
    fields = make_fields(1u64)
    events = [PropertySet({ key: "age", value: PropertyValue.from_value(Integer(30)) })]
    result = on_node_events(fields, events, "age", Any, Err(NoAlias))
    when result.effects is
        [ReportResults([row])] -> Dict.len(row) == 0
        _ -> Bool.false

# Test 4: PropertyRemoved with None constraint → matches (absent satisfies None)
expect
    # Start with a prior match state where property was set
    fields = {
        query_part_id: 1u64,
        value_at_last_report: Ok(Ok(PropertyValue.from_value(Str("x")))),
        last_report_was_match: Ok(Bool.false),
    }
    events = [PropertyRemoved({ key: "color", previous_value: PropertyValue.from_value(Str("red")) })]
    result = on_node_events(fields, events, "color", None, Err(NoAlias))
    # None constraint: absent matches, present does not
    # Absent satisfies None → matches=true, status changed (false→true) → emit positive row
    when result.effects is
        [ReportResults([row])] -> Dict.len(row) == 0
        _ -> Bool.false

# Test 5: No relevant event, first call (NeverReported) → initializes state, no effects
expect
    fields = make_fields(2u64)
    other_node = QuineId.from_bytes([0x01])
    events = [EdgeAdded({ edge_type: "KNOWS", direction: Outgoing, other: other_node })]
    result = on_node_events(fields, events, "name", Any, Err(NoAlias))
    # No relevant event, NeverReported → initialize, no effects
    List.len(result.effects) == 0
    && result.fields.last_report_was_match != Err(NeverReported)

# Test 6: read_results: property present and matching → 1 row
expect
    props = Dict.insert(Dict.empty({}), "score", PropertyValue.from_value(Integer(99)))
    result = read_results(props, "score", Equal(Integer(99)), Ok("s"))
    when result is
        Ok([row]) ->
            when Dict.get(row, "s") is
                Ok(Integer(99)) -> Bool.true
                _ -> Bool.false
        _ -> Bool.false

# Test 7: read_results: property absent, Any constraint → no match (empty list)
expect
    props = Dict.empty({})
    result = read_results(props, "missing", Any, Ok("v"))
    when result is
        Ok([]) -> Bool.true
        _ -> Bool.false

# Test 8: read_results: property absent, None constraint → matches (1 empty row)
expect
    props = Dict.empty({})
    result = read_results(props, "missing", None, Err(NoAlias))
    when result is
        Ok([row]) -> Dict.len(row) == 0
        _ -> Bool.false

# Test 9: Repeated same value → no change (dedup)
expect
    # First call: set value and match
    fields0 = make_fields(1u64)
    events1 = [PropertySet({ key: "x", value: PropertyValue.from_value(Integer(42)) })]
    r1 = on_node_events(fields0, events1, "x", Any, Ok("v"))
    # Second call: same value again
    events2 = [PropertySet({ key: "x", value: PropertyValue.from_value(Integer(42)) })]
    r2 = on_node_events(r1.fields, events2, "x", Any, Ok("v"))
    # Second call should produce no effects (value unchanged)
    List.len(r2.effects) == 0
