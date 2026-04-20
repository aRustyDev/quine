module [
    on_node_events,
    read_results,
    extract_labels,
]

import model.PropertyValue exposing [PropertyValue]
import model.NodeEvent exposing [NodeChangeEvent]
import model.QuineValue exposing [QuineValue]
import ast.ValueConstraint exposing [LabelsConstraint, check_labels]
import result.StandingQueryResult exposing [StandingQueryPartId, QueryContext]
import SqPartState exposing [SqEffect]

## Internal state fields for a Labels standing query part.
LabelsFields : {
    query_part_id : StandingQueryPartId,
    last_reported_labels : Result (List Str) [NeverReported],
    last_report_was_match : Result Bool [NeverReported],
}

## Extract label strings from a QuineValue.
##
## Expected format: `List([Str("Person"), Str("Employee")])`.
## Returns [] for non-list values, non-Str items are skipped, or when absent.
extract_labels : Result QuineValue [Absent] -> List Str
extract_labels = |result|
    when result is
        Err(Absent) -> []
        Ok(List(items)) ->
            List.keep_oks(items, |item|
                when item is
                    Str(s) -> Ok(s)
                    _ -> Err(NotStr)
            )
        Ok(_) -> []

## Build a QuineValue.List of Str from a list of label strings.
labels_to_quine_value : List Str -> QuineValue
labels_to_quine_value = |labels|
    List(List.map(labels, Str))

## Check if two label lists are equal (order-sensitive).
labels_equal : List Str, List Str -> Bool
labels_equal = |a, b|
    List.len(a) == List.len(b)
    && List.walk_until(
        List.map2(a, b, |x, y| (x, y)),
        Bool.true,
        |_, (x, y)|
            if x == y then
                Continue(Bool.true)
            else
                Break(Bool.false),
    )

## Process a list of node change events for a Labels standing query.
##
## Filters events for the watched `labels_key`, extracts labels, checks
## the constraint, and emits effects only when match status or label set changes.
on_node_events :
    LabelsFields,
    List NodeChangeEvent,
    Str,
    LabelsConstraint,
    Result Str [NoAlias]
    -> { fields : LabelsFields, effects : List SqEffect, changed : Bool }
on_node_events = |fields, events, labels_key, constraint, aliased_as|
    # Find the last relevant event for the labels key
    relevant =
        List.walk(events, Err(NoEvent), |acc, event|
            when event is
                PropertySet({ key, value }) if key == labels_key ->
                    Ok(Ok(value))
                PropertyRemoved({ key }) if key == labels_key ->
                    Ok(Err(Absent))
                _ -> acc
        )

    when relevant is
        Err(NoEvent) ->
            # No relevant event. If we have never reported, initialize with absent/no-match.
            when fields.last_report_was_match is
                Err(NeverReported) ->
                    labels : List Str
                    labels = []
                    matches = check_labels(constraint, labels)
                    new_fields = {
                        query_part_id: fields.query_part_id,
                        last_reported_labels: Ok(labels),
                        last_report_was_match: Ok(matches),
                    }
                    { fields: new_fields, effects: [], changed: Bool.false }

                Ok(_) ->
                    # Already initialized, no event → no change
                    { fields, effects: [], changed: Bool.false }

        Ok(property_result) ->
            current_value : Result QuineValue [Absent]
            current_value =
                when property_result is
                    Ok(pv) ->
                        when PropertyValue.get_value(pv) is
                            Ok(qv) -> Ok(qv)
                            Err(_) -> Err(Absent)
                    Err(Absent) -> Err(Absent)

            labels = extract_labels(current_value)
            matches = check_labels(constraint, labels)

            when aliased_as is
                Ok(alias) ->
                    # With alias: emit when labels change AND matches, or cancel when stops matching
                    labels_changed =
                        when fields.last_reported_labels is
                            Err(NeverReported) -> Bool.true
                            Ok(prev) -> !(labels_equal(prev, labels))

                    new_fields = {
                        query_part_id: fields.query_part_id,
                        last_reported_labels: Ok(labels),
                        last_report_was_match: Ok(matches),
                    }

                    if matches && labels_changed then
                        # Labels changed and still (or newly) matching: emit result row
                        row : QueryContext
                        row = Dict.insert(Dict.empty({}), alias, labels_to_quine_value(labels))
                        { fields: new_fields, effects: [ReportResults([row])], changed: Bool.true }
                    else if !(matches) then
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
                        # Matching but labels unchanged (dedup)
                        { fields: new_fields, effects: [], changed: Bool.false }

                Err(NoAlias) ->
                    # Without alias: emit only when match status changes
                    prev_was_match =
                        when fields.last_report_was_match is
                            Err(NeverReported) -> Err(NeverReported)
                            Ok(b) -> Ok(b)

                    new_fields = {
                        query_part_id: fields.query_part_id,
                        last_reported_labels: Ok(labels),
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

## Read the current labels match result from a property snapshot (e.g. on node wake-up).
read_results :
    Dict Str PropertyValue,
    Str,
    LabelsConstraint,
    Result Str [NoAlias]
    -> Result (List QueryContext) [NotReady]
read_results = |properties, labels_key, constraint, aliased_as|
    current_value : Result QuineValue [Absent]
    current_value =
        when Dict.get(properties, labels_key) is
            Ok(pv) ->
                when PropertyValue.get_value(pv) is
                    Ok(qv) -> Ok(qv)
                    Err(_) -> Err(Absent)
            Err(_) -> Err(Absent)

    labels = extract_labels(current_value)
    matches = check_labels(constraint, labels)

    if matches then
        when aliased_as is
            Ok(alias) ->
                row : QueryContext
                row = Dict.insert(Dict.empty({}), alias, labels_to_quine_value(labels))
                Ok([row])

            Err(NoAlias) ->
                Ok([Dict.empty({})])
    else
        Ok([])

# ===== Tests =====

# Helper: build initial (NeverReported) fields
make_fields : StandingQueryPartId -> LabelsFields
make_fields = |pid| {
    query_part_id: pid,
    last_reported_labels: Err(NeverReported),
    last_report_was_match: Err(NeverReported),
}

# Test 1: extract_labels with List of Str → correct list
expect
    qv : Result QuineValue [Absent]
    qv = Ok(List([Str("Person"), Str("Employee")]))
    extract_labels(qv) == ["Person", "Employee"]

# Test 2: extract_labels with empty list → []
expect
    qv : Result QuineValue [Absent]
    qv = Ok(List([]))
    extract_labels(qv) == []

# Test 3: extract_labels with Absent → []
expect
    extract_labels(Err(Absent)) == []

# Test 4: extract_labels with non-list → []
expect
    qv : Result QuineValue [Absent]
    qv = Ok(Str("not-a-list"))
    extract_labels(qv) == []

# Test 5: Contains constraint: labels present and matching → changed, effect emitted
expect
    fields = make_fields(1u64)
    label_pv = PropertyValue.from_value(List([Str("Person"), Str("Employee")]))
    events = [PropertySet({ key: "__labels", value: label_pv })]
    result = on_node_events(fields, events, "__labels", Contains(["Person"]), Err(NoAlias))
    when result.effects is
        [ReportResults([row])] -> Dict.len(row) == 0
        _ -> Bool.false

# Test 6: Contains constraint: not matching, NeverReported → emits cancellation (status changed)
expect
    fields = make_fields(1u64)
    label_pv = PropertyValue.from_value(List([Str("Employee")]))
    events = [PropertySet({ key: "__labels", value: label_pv })]
    result = on_node_events(fields, events, "__labels", Contains(["Admin"]), Err(NoAlias))
    # NeverReported → status_changed=true, matches=false → emit ReportResults([])
    result.changed == Bool.true

# Test 7: read_results with matching labels → 1 row with alias key present
expect
    label_pv = PropertyValue.from_value(List([Str("Person")]))
    props = Dict.insert(Dict.empty({}), "__labels", label_pv)
    result = read_results(props, "__labels", Contains(["Person"]), Ok("lbls"))
    when result is
        Ok([row]) -> Dict.contains(row, "lbls")
        _ -> Bool.false

# Test 8: read_results with no labels property → no match (empty list)
expect
    props = Dict.empty({})
    result = read_results(props, "__labels", Contains(["Person"]), Ok("lbls"))
    when result is
        Ok([]) -> Bool.true
        _ -> Bool.false

# Test 9: Unconditional constraint always matches, even empty labels
expect
    fields = make_fields(1u64)
    events = [PropertySet({ key: "__labels", value: PropertyValue.from_value(List([])) })]
    result = on_node_events(fields, events, "__labels", Unconditional, Err(NoAlias))
    when result.effects is
        [ReportResults([row])] -> Dict.len(row) == 0
        _ -> Bool.false

# Test 10: With alias: matching labels → row includes the alias key
expect
    fields = make_fields(1u64)
    label_pv = PropertyValue.from_value(List([Str("Person"), Str("Admin")]))
    events = [PropertySet({ key: "__labels", value: label_pv })]
    result = on_node_events(fields, events, "__labels", Contains(["Person"]), Ok("labels"))
    when result.effects is
        [ReportResults([row])] ->
            Dict.contains(row, "labels")
        _ -> Bool.false

# Test 11: Dedup — same labels reported twice with alias → second call produces no effect
expect
    fields0 = make_fields(1u64)
    label_pv = PropertyValue.from_value(List([Str("Person")]))
    events = [PropertySet({ key: "__labels", value: label_pv })]
    r1 = on_node_events(fields0, events, "__labels", Unconditional, Ok("l"))
    r2 = on_node_events(r1.fields, events, "__labels", Unconditional, Ok("l"))
    List.len(r2.effects) == 0

# Test 12: No relevant event when property key doesn't match, NeverReported → silent init
expect
    fields = make_fields(1u64)
    events = [PropertySet({ key: "other_prop", value: PropertyValue.from_value(Integer(1)) })]
    result = on_node_events(fields, events, "__labels", Unconditional, Err(NoAlias))
    # "other_prop" != "__labels" → Err(NoEvent) path → silent initialization, no effects
    List.len(result.effects) == 0

