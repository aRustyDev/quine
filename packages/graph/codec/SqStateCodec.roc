module [encode_sq_part_state, decode_sq_part_state]

import standing_state.SqPartState exposing [SqPartState]
import standing_result.StandingQueryResult exposing [StandingQueryPartId]
import id.QuineId

# Tag bytes for SqPartState variants (0x20-0x28, no collision with Codec.roc 0x01-0x13)
tag_unit : U8
tag_unit = 0x20

tag_cross : U8
tag_cross = 0x21

tag_local_property : U8
tag_local_property = 0x22

tag_labels : U8
tag_labels = 0x23

tag_local_id : U8
tag_local_id = 0x24

tag_all_properties : U8
tag_all_properties = 0x25

tag_subscribe_across_edge : U8
tag_subscribe_across_edge = 0x26

tag_edge_subscription_reciprocal : U8
tag_edge_subscription_reciprocal = 0x27

tag_filter_map : U8
tag_filter_map = 0x28

## Encode an SqPartState to bytes for NodeSnapshot persistence.
## Only encodes tag + query_part_id. On wake, state is rehydrated via re-initialization.
encode_sq_part_state : SqPartState -> List U8
encode_sq_part_state = |state|
    when state is
        UnitState -> [tag_unit]
        CrossState({ query_part_id }) -> [tag_cross] |> List.concat(encode_u64_le(query_part_id))
        LocalPropertyState({ query_part_id }) -> [tag_local_property] |> List.concat(encode_u64_le(query_part_id))
        LabelsState({ query_part_id }) -> [tag_labels] |> List.concat(encode_u64_le(query_part_id))
        LocalIdState({ query_part_id }) -> [tag_local_id] |> List.concat(encode_u64_le(query_part_id))
        AllPropertiesState({ query_part_id }) -> [tag_all_properties] |> List.concat(encode_u64_le(query_part_id))
        SubscribeAcrossEdgeState({ query_part_id }) -> [tag_subscribe_across_edge] |> List.concat(encode_u64_le(query_part_id))
        EdgeSubscriptionReciprocalState({ query_part_id }) -> [tag_edge_subscription_reciprocal] |> List.concat(encode_u64_le(query_part_id))
        FilterMapState({ query_part_id }) -> [tag_filter_map] |> List.concat(encode_u64_le(query_part_id))

## Decode an SqPartState from bytes. Returns skeleton state for re-initialization on wake.
decode_sq_part_state : List U8, U64 -> Result { state : SqPartState, next : U64 } [OutOfBounds, InvalidTag]
decode_sq_part_state = |buf, offset|
    when List.get(buf, offset) is
        Err(_) -> Err(OutOfBounds)
        Ok(tag) ->
            if tag == tag_unit then
                Ok({ state: UnitState, next: offset + 1 })
            else if tag == tag_cross then
                decode_with_part_id(buf, offset + 1, |pid|
                    CrossState({ query_part_id: pid, results_accumulator: Dict.empty({}) }))
            else if tag == tag_local_property then
                decode_with_part_id(buf, offset + 1, |pid|
                    LocalPropertyState({ query_part_id: pid, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) }))
            else if tag == tag_labels then
                decode_with_part_id(buf, offset + 1, |pid|
                    LabelsState({ query_part_id: pid, last_reported_labels: Err(NeverReported), last_report_was_match: Err(NeverReported) }))
            else if tag == tag_local_id then
                decode_with_part_id(buf, offset + 1, |pid|
                    LocalIdState({ query_part_id: pid, result: [] }))
            else if tag == tag_all_properties then
                decode_with_part_id(buf, offset + 1, |pid|
                    AllPropertiesState({ query_part_id: pid, last_reported_properties: Err(NeverReported) }))
            else if tag == tag_subscribe_across_edge then
                decode_with_part_id(buf, offset + 1, |pid|
                    SubscribeAcrossEdgeState({ query_part_id: pid, edge_results: Dict.empty({}), edge_map: Dict.empty({}) }))
            else if tag == tag_edge_subscription_reciprocal then
                decode_with_part_id(buf, offset + 1, |pid|
                    EdgeSubscriptionReciprocalState({ query_part_id: pid, half_edge: { edge_type: "", direction: Outgoing, other: QuineId.from_bytes([0]) }, and_then_id: 0, currently_matching: Bool.false, cached_result: Err(NoCachedResult) }))
            else if tag == tag_filter_map then
                decode_with_part_id(buf, offset + 1, |pid|
                    FilterMapState({ query_part_id: pid, kept_results: Err(NoCachedResult) }))
            else
                Err(InvalidTag)

## Helper: decode a U64 part_id then apply a constructor.
decode_with_part_id : List U8, U64, (StandingQueryPartId -> SqPartState) -> Result { state : SqPartState, next : U64 } [OutOfBounds, InvalidTag]
decode_with_part_id = |buf, offset, constructor|
    when decode_u64_le(buf, offset) is
        Ok({ val, next }) -> Ok({ state: constructor(val), next })
        Err(_) -> Err(OutOfBounds)

encode_u64_le : U64 -> List U8
encode_u64_le = |n|
    List.range({ start: At(0), end: Before(8) })
    |> List.map(|i|
        Num.int_cast(Num.shift_right_zf_by(n, Num.int_cast(i) * 8) |> Num.bitwise_and(0xFF)))

decode_u64_le : List U8, U64 -> Result { val : U64, next : U64 } [OutOfBounds]
decode_u64_le = |buf, offset|
    if offset + 8 > List.len(buf) then
        Err(OutOfBounds)
    else
        val = List.walk(
            List.range({ start: At(0), end: Before(8) }),
            0u64,
            |acc, i|
                byte_offset = offset + i
                when List.get(buf, byte_offset) is
                    Ok(byte) ->
                        shifted : U64
                        shifted = Num.shift_left_by(Num.int_cast(byte), Num.int_cast(i) * 8)
                        Num.bitwise_or(acc, shifted)
                    Err(_) -> acc,
        )
        Ok({ val, next: offset + 8 })

# ===== Tests =====

# UnitState roundtrip
expect
    encoded = encode_sq_part_state(UnitState)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: UnitState }) -> Bool.true
        _ -> Bool.false

# LocalPropertyState roundtrip preserves part_id
expect
    original = LocalPropertyState({ query_part_id: 42u64, value_at_last_report: Err(NeverReported), last_report_was_match: Err(NeverReported) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: LocalPropertyState({ query_part_id: 42u64 }) }) -> Bool.true
        _ -> Bool.false

# CrossState roundtrip preserves part_id
expect
    original = CrossState({ query_part_id: 99u64, results_accumulator: Dict.empty({}) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: CrossState({ query_part_id: 99u64 }) }) -> Bool.true
        _ -> Bool.false

# LabelsState roundtrip
expect
    original = LabelsState({ query_part_id: 7u64, last_reported_labels: Err(NeverReported), last_report_was_match: Err(NeverReported) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: LabelsState({ query_part_id: 7u64 }) }) -> Bool.true
        _ -> Bool.false

# LocalIdState roundtrip
expect
    original = LocalIdState({ query_part_id: 55u64, result: [] })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: LocalIdState({ query_part_id: 55u64 }) }) -> Bool.true
        _ -> Bool.false

# AllPropertiesState roundtrip
expect
    original = AllPropertiesState({ query_part_id: 33u64, last_reported_properties: Err(NeverReported) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: AllPropertiesState({ query_part_id: 33u64 }) }) -> Bool.true
        _ -> Bool.false

# SubscribeAcrossEdgeState roundtrip
expect
    original = SubscribeAcrossEdgeState({ query_part_id: 77u64, edge_results: Dict.empty({}), edge_map: Dict.empty({}) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: SubscribeAcrossEdgeState({ query_part_id: 77u64 }) }) -> Bool.true
        _ -> Bool.false

# FilterMapState roundtrip
expect
    original = FilterMapState({ query_part_id: 11u64, kept_results: Err(NoCachedResult) })
    encoded = encode_sq_part_state(original)
    result = decode_sq_part_state(encoded, 0)
    when result is
        Ok({ state: FilterMapState({ query_part_id: 11u64 }) }) -> Bool.true
        _ -> Bool.false

# Invalid tag returns error
expect
    result = decode_sq_part_state([0xFF], 0)
    when result is
        Err(InvalidTag) -> Bool.true
        _ -> Bool.false

# Empty buffer returns OutOfBounds
expect
    result = decode_sq_part_state([], 0)
    when result is
        Err(OutOfBounds) -> Bool.true
        _ -> Bool.false
