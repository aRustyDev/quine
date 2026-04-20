module [
    Expr,
    MvStandingQuery,
    WatchableEventType,
    query_part_id,
    children,
    relevant_event_types,
    indexable_subqueries,
]

import id.QuineId exposing [QuineId]
import model.HalfEdge exposing [HalfEdge]
import model.EdgeDirection exposing [EdgeDirection]

## StandingQueryPartId is a U64 derived from the hash of an MVSQ subtree.
StandingQueryPartId : U64

## Placeholder expression type. The real Expr package is Phase 4b.
Expr : [ExprPlaceholder]

## The AST for a multi-vertex standing query.
##
## Each variant describes one structural pattern that can be matched
## against graph state. Variants are composed into trees; `children`
## and `indexable_subqueries` traverse these trees.
MvStandingQuery : [
    ## Always matches. Emits a single empty QueryContext.
    UnitSq,
    ## Matches all combinations of child query results (cross-product).
    Cross { queries : List MvStandingQuery, emit_subscriptions_lazily : Bool },
    ## Matches a node property against a constraint.
    LocalProperty { prop_key : Str, constraint : ValueConstraint, aliased_as : Result Str [NoAlias] },
    ## Matches node labels against a constraint.
    Labels { aliased_as : Result Str [NoAlias], constraint : LabelsConstraint },
    ## Matches a node's own ID.
    LocalId { aliased_as : Str, format_as_string : Bool },
    ## Matches all properties on a node as a map.
    AllProperties { aliased_as : Str },
    ## Traverses an edge and matches the remote node against a sub-query.
    SubscribeAcrossEdge { edge_name : Result Str [AnyEdge], edge_direction : Result EdgeDirection [AnyDirection], and_then : MvStandingQuery },
    ## The remote side of a SubscribeAcrossEdge subscription.
    ## Excluded from indexable_subqueries.
    EdgeSubscriptionReciprocal { half_edge : HalfEdge, and_then_id : StandingQueryPartId },
    ## Post-processes a sub-query with a filter and projection.
    FilterMap { condition : Result Expr [NoFilter], to_filter : MvStandingQuery, drop_existing : Bool, to_add : List { alias : Str, expr : Expr } },
]

## A constraint on a property value.
## Inlined here to avoid a circular import with ValueConstraint.roc.
ValueConstraint : [
    Equal QuineValue,
    NotEqual QuineValue,
    Any,
    None,
    Unconditional,
    Regex Str,
    ListContains (List QuineValue),
]

## A constraint on node labels.
LabelsConstraint : [
    Contains (List Str),
    Unconditional,
]

## Placeholder for QuineValue — needed because ValueConstraint holds QuineValue.
## The full type lives in model.QuineValue but we replicate the structure
## for standalone module use.
QuineValue : [
    Str Str,
    Integer I64,
    Floating F64,
    True,
    False,
    Null,
    Bytes (List U8),
    Id QuineId,
    List (List QuineValue),
    Map (Dict Str QuineValue),
]

## Events that a standing query state can watch.
WatchableEventType : [
    ## A specific named property changed.
    PropertyChange Str,
    ## An edge with the given label changed (or any edge if AnyLabel).
    EdgeChange (Result Str [AnyLabel]),
    ## Any property changed.
    AnyPropertyChange,
]

# ===== FNV-1a-64 Helpers =====

fnv_offset_basis : U64
fnv_offset_basis = 14695981039346656037

fnv_prime : U64
fnv_prime = 1099511628211

fnv_mix : U64, U8 -> U64
fnv_mix = |acc, byte|
    Num.bitwise_xor(acc, Num.int_cast(byte))
    |> Num.mul_wrap(fnv_prime)

fnv_bytes : U64, List U8 -> U64
fnv_bytes = |acc, bytes|
    List.walk(bytes, acc, fnv_mix)

fnv_str : U64, Str -> U64
fnv_str = |acc, s|
    fnv_bytes(acc, Str.to_utf8(s))

fnv_bool : U64, Bool -> U64
fnv_bool = |acc, b|
    fnv_mix(acc, if b then 1u8 else 0u8)

fnv_u64 : U64, U64 -> U64
fnv_u64 = |acc, n|
    # Encode n as 8 bytes little-endian
    b0 = Num.bitwise_and(n, 0xFF) |> Num.int_cast
    b1 = Num.shift_right_zf_by(n, 8) |> Num.bitwise_and(0xFF) |> Num.int_cast
    b2 = Num.shift_right_zf_by(n, 16) |> Num.bitwise_and(0xFF) |> Num.int_cast
    b3 = Num.shift_right_zf_by(n, 24) |> Num.bitwise_and(0xFF) |> Num.int_cast
    b4 = Num.shift_right_zf_by(n, 32) |> Num.bitwise_and(0xFF) |> Num.int_cast
    b5 = Num.shift_right_zf_by(n, 40) |> Num.bitwise_and(0xFF) |> Num.int_cast
    b6 = Num.shift_right_zf_by(n, 48) |> Num.bitwise_and(0xFF) |> Num.int_cast
    b7 = Num.shift_right_zf_by(n, 56) |> Num.bitwise_and(0xFF) |> Num.int_cast
    acc
    |> fnv_mix(b0)
    |> fnv_mix(b1)
    |> fnv_mix(b2)
    |> fnv_mix(b3)
    |> fnv_mix(b4)
    |> fnv_mix(b5)
    |> fnv_mix(b6)
    |> fnv_mix(b7)

fnv_result_str_tag : U64, Result Str [AnyEdge] -> U64
fnv_result_str_tag = |acc, r|
    when r is
        Ok(s) -> acc |> fnv_mix(0u8) |> fnv_str(s)
        Err(AnyEdge) -> acc |> fnv_mix(1u8)

fnv_result_str_no_alias : U64, Result Str [NoAlias] -> U64
fnv_result_str_no_alias = |acc, r|
    when r is
        Ok(s) -> acc |> fnv_mix(0u8) |> fnv_str(s)
        Err(NoAlias) -> acc |> fnv_mix(1u8)

fnv_result_edge_direction : U64, Result EdgeDirection [AnyDirection] -> U64
fnv_result_edge_direction = |acc, r|
    when r is
        Ok(Outgoing) -> acc |> fnv_mix(0u8)
        Ok(Incoming) -> acc |> fnv_mix(1u8)
        Ok(Undirected) -> acc |> fnv_mix(2u8)
        Err(AnyDirection) -> acc |> fnv_mix(3u8)

## Compute the canonical FNV-1a-64 hash for an MVSQ subtree.
##
## Tag bytes (unique per variant):
##   0x00 = UnitSq
##   0x01 = Cross
##   0x02 = LocalProperty
##   0x03 = Labels
##   0x04 = LocalId
##   0x05 = AllProperties
##   0x06 = SubscribeAcrossEdge
##   0x07 = EdgeSubscriptionReciprocal
##   0x08 = FilterMap
hash_mvsq : U64, MvStandingQuery -> U64
hash_mvsq = |acc, sq|
    when sq is
        UnitSq ->
            fnv_mix(acc, 0x00u8)

        Cross({ queries, emit_subscriptions_lazily }) ->
            acc
            |> fnv_mix(0x01u8)
            |> fnv_bool(emit_subscriptions_lazily)
            |> |a| List.walk(queries, a, hash_mvsq)

        LocalProperty({ prop_key, constraint, aliased_as }) ->
            acc
            |> fnv_mix(0x02u8)
            |> fnv_str(prop_key)
            |> hash_value_constraint(constraint)
            |> fnv_result_str_no_alias(aliased_as)

        Labels({ aliased_as, constraint }) ->
            acc
            |> fnv_mix(0x03u8)
            |> fnv_result_str_no_alias(aliased_as)
            |> hash_labels_constraint(constraint)

        LocalId({ aliased_as, format_as_string }) ->
            acc
            |> fnv_mix(0x04u8)
            |> fnv_str(aliased_as)
            |> fnv_bool(format_as_string)

        AllProperties({ aliased_as }) ->
            acc
            |> fnv_mix(0x05u8)
            |> fnv_str(aliased_as)

        SubscribeAcrossEdge({ edge_name, edge_direction, and_then }) ->
            acc
            |> fnv_mix(0x06u8)
            |> fnv_result_str_tag(edge_name)
            |> fnv_result_edge_direction(edge_direction)
            |> hash_mvsq(and_then)

        EdgeSubscriptionReciprocal({ half_edge, and_then_id }) ->
            acc
            |> fnv_mix(0x07u8)
            |> fnv_str(half_edge.edge_type)
            |> hash_edge_direction(half_edge.direction)
            |> fnv_bytes(QuineId.to_bytes(half_edge.other))
            |> fnv_u64(and_then_id)

        FilterMap({ condition, to_filter, drop_existing, to_add }) ->
            acc_base =
                acc
                |> fnv_mix(0x08u8)
                |> hash_condition(condition)
                |> hash_mvsq(to_filter)
                |> fnv_bool(drop_existing)
            List.walk(
                to_add,
                acc_base,
                |a, { alias }|
                    # Expr is a placeholder; hash only the alias
                    a |> fnv_str(alias),
            )

hash_edge_direction : U64, EdgeDirection -> U64
hash_edge_direction = |acc, dir|
    when dir is
        Outgoing -> fnv_mix(acc, 0u8)
        Incoming -> fnv_mix(acc, 1u8)
        Undirected -> fnv_mix(acc, 2u8)

hash_condition : U64, Result Expr [NoFilter] -> U64
hash_condition = |acc, c|
    when c is
        Ok(ExprPlaceholder) -> fnv_mix(acc, 0u8)
        Err(NoFilter) -> fnv_mix(acc, 1u8)

hash_value_constraint : U64, ValueConstraint -> U64
hash_value_constraint = |acc, vc|
    when vc is
        Equal(_) -> fnv_mix(acc, 0u8)
        NotEqual(_) -> fnv_mix(acc, 1u8)
        Any -> fnv_mix(acc, 2u8)
        None -> fnv_mix(acc, 3u8)
        Unconditional -> fnv_mix(acc, 4u8)
        Regex(s) -> acc |> fnv_mix(5u8) |> fnv_str(s)
        ListContains(_) -> fnv_mix(acc, 6u8)

hash_labels_constraint : U64, LabelsConstraint -> U64
hash_labels_constraint = |acc, lc|
    when lc is
        Contains(labels) ->
            List.walk(labels, fnv_mix(acc, 0u8), fnv_str)
        Unconditional -> fnv_mix(acc, 1u8)

## Compute the deterministic StandingQueryPartId for an MVSQ subtree.
##
## The result is an FNV-1a-64 hash of the canonical byte encoding.
## Same AST always produces the same ID.
query_part_id : MvStandingQuery -> StandingQueryPartId
query_part_id = |sq|
    hash_mvsq(fnv_offset_basis, sq)

## Return the direct child sub-queries of an MVSQ node.
children : MvStandingQuery -> List MvStandingQuery
children = |sq|
    when sq is
        UnitSq -> []
        Cross({ queries }) -> queries
        LocalProperty(_) -> []
        Labels(_) -> []
        LocalId(_) -> []
        AllProperties(_) -> []
        SubscribeAcrossEdge({ and_then }) -> [and_then]
        EdgeSubscriptionReciprocal(_) -> []
        FilterMap({ to_filter }) -> [to_filter]

## Return the event types that this query variant watches.
##
## `labels_property_key` is the special property key that stores node labels
## (needed by the Labels variant).
relevant_event_types : MvStandingQuery, Str -> List WatchableEventType
relevant_event_types = |sq, labels_property_key|
    when sq is
        UnitSq -> []
        Cross(_) -> []
        LocalProperty({ prop_key }) -> [PropertyChange(prop_key)]
        Labels(_) -> [PropertyChange(labels_property_key)]
        LocalId(_) -> []
        AllProperties(_) -> [AnyPropertyChange]
        SubscribeAcrossEdge({ edge_name }) -> [EdgeChange(Result.map_err(edge_name, |AnyEdge| AnyLabel))]
        EdgeSubscriptionReciprocal({ half_edge }) -> [EdgeChange(Ok(half_edge.edge_type))]
        FilterMap(_) -> []

## Collect all globally-indexable subqueries in this subtree.
##
## Traverses recursively. Excludes EdgeSubscriptionReciprocal nodes.
## Deduplicates by part_id. The query itself is included unless it is
## an EdgeSubscriptionReciprocal.
indexable_subqueries : MvStandingQuery -> List MvStandingQuery
indexable_subqueries = |sq|
    collect_indexable(sq, [])
    |> .result

IndexableAcc : { result : List MvStandingQuery, seen_ids : List StandingQueryPartId }

collect_indexable : MvStandingQuery, List StandingQueryPartId -> IndexableAcc
collect_indexable = |sq, seen|
    when sq is
        EdgeSubscriptionReciprocal(_) ->
            { result: [], seen_ids: seen }
        _ ->
            pid = query_part_id(sq)
            if List.contains(seen, pid) then
                { result: [], seen_ids: seen }
            else
                seen1 = List.append(seen, pid)
                # Recurse into children
                child_acc = List.walk(
                    children(sq),
                    { result: [], seen_ids: seen1 },
                    |acc, child|
                        child_result = collect_indexable(child, acc.seen_ids)
                        {
                            result: List.concat(acc.result, child_result.result),
                            seen_ids: child_result.seen_ids,
                        },
                )
                # Include this node after its children (so leaves come first)
                {
                    result: List.append(child_acc.result, sq),
                    seen_ids: child_acc.seen_ids,
                }

# ===== Tests =====

# --- query_part_id: determinism ---
expect query_part_id(UnitSq) == query_part_id(UnitSq)

expect
    lp = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Err(NoAlias) })
    query_part_id(lp) == query_part_id(lp)

expect
    id1 = query_part_id(UnitSq)
    id2 = query_part_id(AllProperties({ aliased_as: "props" }))
    id1 != id2

# --- children ---
expect List.len(children(UnitSq)) == 0

expect
    c1 = UnitSq
    c2 = LocalId({ aliased_as: "id", format_as_string: Bool.false })
    cross = Cross({ queries: [c1, c2], emit_subscriptions_lazily: Bool.false })
    List.len(children(cross)) == 2

expect
    inner = UnitSq
    sae = SubscribeAcrossEdge({ edge_name: Ok("KNOWS"), edge_direction: Ok(Outgoing), and_then: inner })
    # Can't use == on MvStandingQuery (contains F64 via QuineValue).
    # Verify via part_id equality instead.
    child_ids = List.map(children(sae), query_part_id)
    child_ids == [query_part_id(inner)]

# --- relevant_event_types ---
expect relevant_event_types(UnitSq, "__labels") == []

expect
    lp = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Err(NoAlias) })
    relevant_event_types(lp, "__labels") == [PropertyChange("name")]

expect
    labels_sq = Labels({ aliased_as: Err(NoAlias), constraint: Unconditional })
    relevant_event_types(labels_sq, "__labels") == [PropertyChange("__labels")]

expect
    ap = AllProperties({ aliased_as: "props" })
    relevant_event_types(ap, "__labels") == [AnyPropertyChange]

expect
    sae = SubscribeAcrossEdge({ edge_name: Ok("KNOWS"), edge_direction: Ok(Outgoing), and_then: UnitSq })
    relevant_event_types(sae, "__labels") == [EdgeChange(Ok("KNOWS"))]

# --- indexable_subqueries ---
expect
    subs = indexable_subqueries(UnitSq)
    List.len(subs) == 1

expect
    c1 = UnitSq
    c2 = AllProperties({ aliased_as: "props" })
    cross = Cross({ queries: [c1, c2], emit_subscriptions_lazily: Bool.false })
    subs = indexable_subqueries(cross)
    List.len(subs) == 3

expect
    he = { edge_type: "KNOWS", direction: Outgoing, other: QuineId.from_bytes([0x01]) }
    esr = EdgeSubscriptionReciprocal({ half_edge: he, and_then_id: 42u64 })
    List.len(indexable_subqueries(esr)) == 0
