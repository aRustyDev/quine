module [
    ValueConstraint,
    LabelsConstraint,
    check_value,
    check_labels,
    satisfied_by_none,
]

import model.QuineValue exposing [QuineValue]
import id.QuineId

## A constraint on a property value used by LocalProperty standing queries.
ValueConstraint : [
    Equal QuineValue,
    NotEqual QuineValue,
    Any,
    None,
    Unconditional,
    Regex Str,
    ListContains (List QuineValue),
]

## A constraint on node labels used by Labels standing queries.
LabelsConstraint : [
    Contains (List Str),
    Unconditional,
]

## Structural equality for QuineValue.
##
## Roc cannot auto-derive Eq across package boundaries for recursive types
## containing opaque types (QuineId). This function provides explicit equality.
quine_value_eq : QuineValue, QuineValue -> Bool
quine_value_eq = |a, b|
    when (a, b) is
        (Str(x), Str(y)) -> x == y
        (Integer(x), Integer(y)) -> x == y
        (Floating(x), Floating(y)) ->
            # F64 does not implement Eq due to NaN. Use zero-tolerance approx
            # equality, which is exact for non-NaN values. NaN != NaN here too.
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

## Check whether a present property value satisfies the constraint.
check_value : ValueConstraint, QuineValue -> Result Bool [RegexNotSupported]
check_value = |constraint, value|
    when constraint is
        Equal(expected) -> Ok(quine_value_eq(value, expected))
        NotEqual(expected) -> Ok(!(quine_value_eq(value, expected)))
        Any -> Ok(Bool.true)
        None -> Ok(Bool.false)
        Unconditional -> Ok(Bool.true)
        Regex(_) -> Err(RegexNotSupported)
        ListContains(must_contain) ->
            when value is
                List(items) ->
                    all_present = List.all(must_contain, |needed|
                        List.any(items, |item| quine_value_eq(item, needed))
                    )
                    Ok(all_present)
                _ -> Ok(Bool.false)

## Whether the constraint is satisfied when the property is absent.
satisfied_by_none : ValueConstraint -> Bool
satisfied_by_none = |constraint|
    when constraint is
        Equal(_) -> Bool.false
        NotEqual(_) -> Bool.false
        Any -> Bool.false
        None -> Bool.true
        Unconditional -> Bool.true
        Regex(_) -> Bool.false
        ListContains(_) -> Bool.false

## Check whether a set of labels satisfies the constraint.
check_labels : LabelsConstraint, List Str -> Bool
check_labels = |constraint, labels|
    when constraint is
        Contains(must_contain) ->
            List.all(must_contain, |needed|
                List.contains(labels, needed)
            )
        Unconditional -> Bool.true

# ===== Tests =====

# --- ValueConstraint: Equal ---
expect check_value(Equal(Str("Alice")), Str("Alice")) == Ok(Bool.true)
expect check_value(Equal(Str("Alice")), Str("Bob")) == Ok(Bool.false)
expect check_value(Equal(Integer(42)), Integer(42)) == Ok(Bool.true)
expect check_value(Equal(Integer(42)), Integer(43)) == Ok(Bool.false)

# --- ValueConstraint: NotEqual ---
expect check_value(NotEqual(Str("Alice")), Str("Bob")) == Ok(Bool.true)
expect check_value(NotEqual(Str("Alice")), Str("Alice")) == Ok(Bool.false)

# --- ValueConstraint: Any ---
expect check_value(Any, Str("anything")) == Ok(Bool.true)
expect check_value(Any, Null) == Ok(Bool.true)

# --- ValueConstraint: None ---
expect check_value(None, Str("anything")) == Ok(Bool.false)

# --- ValueConstraint: Unconditional ---
expect check_value(Unconditional, Str("anything")) == Ok(Bool.true)

# --- ValueConstraint: Regex (not supported in Phase 4a) ---
expect check_value(Regex(".*"), Str("test")) == Err(RegexNotSupported)

# --- ValueConstraint: ListContains ---
expect check_value(ListContains([Str("a"), Str("b")]), List([Str("a"), Str("b"), Str("c")])) == Ok(Bool.true)
expect check_value(ListContains([Str("a"), Str("d")]), List([Str("a"), Str("b"), Str("c")])) == Ok(Bool.false)
expect check_value(ListContains([Str("a")]), Str("not a list")) == Ok(Bool.false)
expect check_value(ListContains([]), List([Str("a")])) == Ok(Bool.true)

# --- satisfied_by_none ---
expect satisfied_by_none(Equal(Str("x"))) == Bool.false
expect satisfied_by_none(NotEqual(Str("x"))) == Bool.false
expect satisfied_by_none(Any) == Bool.false
expect satisfied_by_none(None) == Bool.true
expect satisfied_by_none(Unconditional) == Bool.true
expect satisfied_by_none(Regex(".*")) == Bool.false
expect satisfied_by_none(ListContains([Str("a")])) == Bool.false

# --- LabelsConstraint: Contains ---
expect check_labels(Contains(["Person"]), ["Person", "Employee"]) == Bool.true
expect check_labels(Contains(["Person", "Admin"]), ["Person", "Employee"]) == Bool.false
expect check_labels(Contains(["Person"]), []) == Bool.false
expect check_labels(Contains([]), ["Person"]) == Bool.true

# --- LabelsConstraint: Unconditional ---
expect check_labels(Unconditional, ["Person"]) == Bool.true
expect check_labels(Unconditional, []) == Bool.true
