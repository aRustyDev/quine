module [
    generate_result_reports,
    ResultsReporter,
    new_reporter,
    apply_and_emit_results,
]

import StandingQueryResult exposing [StandingQueryResult, QueryContext]
import model.QuineValue exposing [QuineValue]
import id.QuineId

## Tracks the last-emitted result group so we can diff successive result sets.
ResultsReporter : {
    last_results : List QueryContext,
}

## Create a fresh reporter with no prior results.
new_reporter : ResultsReporter
new_reporter = { last_results: [] }

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
        (Id(x), Id(y)) -> QuineId.to_bytes(x) == QuineId.to_bytes(y)
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
##
## Two contexts are equal iff they have the same keys with equal values.
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

## Multiset difference: elements in `a` not found in `b`.
##
## For each element in `a`, it is kept only if it appears more times in `a`
## than in `b`. Consumes one matching element from `b` per match found.
list_diff : List QueryContext, List QueryContext -> List QueryContext
list_diff = |a, b|
    { result: result_list } =
        List.walk(
            a,
            { remaining_b: b, result: [] },
            |state, item|
                # Try to find item in remaining_b
                when List.find_first_index(state.remaining_b, |candidate| query_context_eq(item, candidate)) is
                    Ok(idx) ->
                        # Found a match: consume it from remaining_b and skip this item
                        new_remaining = List.drop_at(state.remaining_b, idx)
                        { state & remaining_b: new_remaining }

                    Err(NotFound) ->
                        # No match: keep this item in the result
                        { state & result: List.append(state.result, item) },
        )
    result_list

## Compute the diff between two result groups.
##
## Returns a list of StandingQueryResult:
## - Elements added (in new_results but not old_results) become positive matches.
## - Elements removed (in old_results but not new_results) become cancellations,
##   only when include_cancellations is Bool.true.
generate_result_reports : List QueryContext, List QueryContext, Bool -> List StandingQueryResult
generate_result_reports = |old_results, new_results, include_cancellations|
    added = list_diff(new_results, old_results)
    removed = list_diff(old_results, new_results)

    positive = List.map(added, |ctx| { is_positive_match: Bool.true, data: ctx })
    cancellations =
        if include_cancellations then
            List.map(removed, |ctx| { is_positive_match: Bool.false, data: ctx })
        else
            []

    List.concat(positive, cancellations)

## Apply a new result group to a reporter, emitting result diffs.
##
## Returns an updated reporter (with last_results set to new_results) and
## the list of StandingQueryResult reports to emit.
apply_and_emit_results : ResultsReporter, List QueryContext, Bool -> { reporter : ResultsReporter, reports : List StandingQueryResult }
apply_and_emit_results = |reporter, new_results, include_cancellations|
    reports = generate_result_reports(reporter.last_results, new_results, include_cancellations)
    updated_reporter = { reporter & last_results: new_results }
    { reporter: updated_reporter, reports }

# ===== Tests =====

# Helper: build a simple QueryContext with a single Str key-value pair
make_ctx : Str, Str -> QueryContext
make_ctx = |k, v| Dict.insert(Dict.empty({}), k, Str(v))

# Test 1: Empty → non-empty: all positive reports
expect
    old : List QueryContext
    old = []
    new = [make_ctx("name", "Alice"), make_ctx("name", "Bob")]
    reports = generate_result_reports(old, new, Bool.true)
    List.len(reports) == 2
    && List.all(reports, |r| r.is_positive_match == Bool.true)

# Test 2: Non-empty → empty: all cancellations when include_cancellations=true
expect
    old = [make_ctx("name", "Alice"), make_ctx("name", "Bob")]
    new : List QueryContext
    new = []
    reports = generate_result_reports(old, new, Bool.true)
    List.len(reports) == 2
    && List.all(reports, |r| r.is_positive_match == Bool.false)

# Test 3: Non-empty → empty: no reports when include_cancellations=false
expect
    old = [make_ctx("name", "Alice"), make_ctx("name", "Bob")]
    new : List QueryContext
    new = []
    reports = generate_result_reports(old, new, Bool.false)
    List.len(reports) == 0

# Test 4: Same results → no reports
expect
    ctx = make_ctx("name", "Alice")
    old = [ctx]
    new = [ctx]
    reports = generate_result_reports(old, new, Bool.true)
    List.len(reports) == 0

# Test 5: Partial overlap: one added, one removed → 2 reports
expect
    alice = make_ctx("name", "Alice")
    bob = make_ctx("name", "Bob")
    old = [alice]
    new = [bob]
    reports = generate_result_reports(old, new, Bool.true)
    positives = List.keep_if(reports, |r| r.is_positive_match)
    cancellations = List.keep_if(reports, |r| !(r.is_positive_match))
    List.len(positives) == 1
    && List.len(cancellations) == 1

# Test 6: ResultsReporter: apply first results → positive reports
expect
    reporter = new_reporter
    ctx = make_ctx("id", "1")
    result = apply_and_emit_results(reporter, [ctx], Bool.true)
    List.len(result.reports) == 1
    && (List.first(result.reports) |> Result.map_ok(|r| r.is_positive_match) == Ok(Bool.true))
    && List.len(result.reporter.last_results) == 1

# Test 7: ResultsReporter: apply same results again → no reports
expect
    reporter = new_reporter
    ctx = make_ctx("id", "1")
    r1 = apply_and_emit_results(reporter, [ctx], Bool.true)
    r2 = apply_and_emit_results(r1.reporter, [ctx], Bool.true)
    List.len(r2.reports) == 0

# Test 8: list_diff basic: [a,b] minus [a] = [b]
expect
    a = make_ctx("x", "a")
    b = make_ctx("x", "b")
    diff = list_diff([a, b], [a])
    List.len(diff) == 1
    && query_context_eq(List.first(diff) |> Result.with_default(Dict.empty({})), b)

# Test 9: list_diff duplicate handling: [a,a,a] minus [a] = [a,a]
expect
    a = make_ctx("x", "dup")
    diff = list_diff([a, a, a], [a])
    List.len(diff) == 2
