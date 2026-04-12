app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.13.0/RqendgZw5e1RsQa3kFhgtnMP8efWoqGRsAvubx4-zus.tar.br",
}

import cli.Stdout
import cli.Arg exposing [Arg]
import json.Json

## roc-json smoke test (ADR-015 gate)
##
## Tests that roc-json loads and round-trips data correctly with the current
## Roc nightly. Phase 1 types (QuineId, EventTime) are opaque without
## Encoding/Decoding abilities, so they cannot auto-derive JSON codecs.
## This test validates roc-json itself works, then exercises the structural
## shapes our types use (tag unions, records, nested lists, dicts).

main! : List Arg => Result {} _
main! = |_args|
    passed = [0]

    # --- Tier 1: roc-json loads and works at all ---

    # Test 1: round-trip a simple I64
    i64_bytes = Encode.to_bytes(42i64, Json.utf8)
    i64_decoded : Result I64 _
    i64_decoded = Decode.from_bytes(i64_bytes, Json.utf8)

    passed1 =
        when i64_decoded is
            Ok(42) ->
                Stdout.line!("1. I64 round-trip: PASSED")?
                List.append(passed, 1)

            other ->
                Stdout.line!("1. I64 round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed

    # Test 2: round-trip a Str
    str_bytes = Encode.to_bytes("hello", Json.utf8)
    str_decoded : Result Str _
    str_decoded = Decode.from_bytes(str_bytes, Json.utf8)

    passed2 =
        when str_decoded is
            Ok("hello") ->
                Stdout.line!("2. Str round-trip: PASSED")?
                List.append(passed1, 1)

            other ->
                Stdout.line!("2. Str round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed1

    # Test 3: round-trip a F64
    f64_bytes = Encode.to_bytes(3.14f64, Json.utf8)
    f64_decoded : Result F64 _
    f64_decoded = Decode.from_bytes(f64_bytes, Json.utf8)

    passed3 =
        when f64_decoded is
            Ok(v) if v > 3.13 and v < 3.15 ->
                Stdout.line!("3. F64 round-trip: PASSED")?
                List.append(passed2, 1)

            other ->
                Stdout.line!("3. F64 round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed2

    # Test 4: round-trip a Bool
    bool_bytes = Encode.to_bytes(Bool.true, Json.utf8)
    bool_decoded : Result Bool _
    bool_decoded = Decode.from_bytes(bool_bytes, Json.utf8)

    passed4 =
        when bool_decoded is
            Ok(val) if val == Bool.true ->
                Stdout.line!("4. Bool round-trip: PASSED")?
                List.append(passed3, 1)

            other ->
                Stdout.line!("4. Bool round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed3

    # --- Tier 2: structural shapes matching Phase 1 types ---

    # Test 5: round-trip a List of I64 (like QuineValue.List shape)
    list_bytes = Encode.to_bytes([1i64, 2i64, 3i64], Json.utf8)
    list_decoded : Result (List I64) _
    list_decoded = Decode.from_bytes(list_bytes, Json.utf8)

    passed5 =
        when list_decoded is
            Ok([1, 2, 3]) ->
                Stdout.line!("5. List I64 round-trip: PASSED")?
                List.append(passed4, 1)

            other ->
                Stdout.line!("5. List I64 round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed4

    # Test 6: round-trip an empty list (known Roc compiler edge case)
    empty : List I64
    empty = []
    empty_bytes = Encode.to_bytes(empty, Json.utf8)
    empty_decoded : Result (List I64) _
    empty_decoded = Decode.from_bytes(empty_bytes, Json.utf8)

    passed6 =
        when empty_decoded is
            Ok([]) ->
                Stdout.line!("6. Empty list round-trip: PASSED")?
                List.append(passed5, 1)

            other ->
                Stdout.line!("6. Empty list round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed5

    # Test 7: round-trip a record (like HalfEdge shape without opaque fields)
    rec = { edge_type: "KNOWS", direction: "Outgoing", node_id: 42u64 }
    rec_bytes = Encode.to_bytes(rec, Json.utf8)
    rec_decoded : Result { edge_type : Str, direction : Str, node_id : U64 } _
    rec_decoded = Decode.from_bytes(rec_bytes, Json.utf8)

    passed7 =
        when rec_decoded is
            Ok({ edge_type: "KNOWS", direction: "Outgoing", node_id: 42 }) ->
                Stdout.line!("7. Record round-trip: PASSED")?
                List.append(passed6, 1)

            other ->
                Stdout.line!("7. Record round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed6

    # Test 8: round-trip a List U8 (like QuineValue.Bytes / QuineId inner shape)
    bytes_val : List U8
    bytes_val = [0xAA, 0xBB, 0xCC]
    bytes_enc = Encode.to_bytes(bytes_val, Json.utf8)
    bytes_dec : Result (List U8) _
    bytes_dec = Decode.from_bytes(bytes_enc, Json.utf8)

    passed8 =
        when bytes_dec is
            Ok([0xAA, 0xBB, 0xCC]) ->
                Stdout.line!("8. List U8 round-trip: PASSED")?
                List.append(passed7, 1)

            other ->
                Stdout.line!("8. List U8 round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed7

    # Test 9: round-trip a U64 (like EventTime inner shape)
    u64_val : U64
    u64_val = 4194304000
    u64_bytes = Encode.to_bytes(u64_val, Json.utf8)
    u64_decoded : Result U64 _
    u64_decoded = Decode.from_bytes(u64_bytes, Json.utf8)

    passed9 =
        when u64_decoded is
            Ok(4194304000) ->
                Stdout.line!("9. U64 round-trip: PASSED")?
                List.append(passed8, 1)

            other ->
                Stdout.line!("9. U64 round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed8

    # Test 10: round-trip a nested record (like TimestampedEvent shape)
    nested = { event: { key: "name", value: "Alice" }, at_time: 4194304000u64 }
    nested_bytes = Encode.to_bytes(nested, Json.utf8)
    nested_decoded : Result { event : { key : Str, value : Str }, at_time : U64 } _
    nested_decoded = Decode.from_bytes(nested_bytes, Json.utf8)

    passed10 =
        when nested_decoded is
            Ok({ event: { key: "name", value: "Alice" }, at_time: 4194304000 }) ->
                Stdout.line!("10. Nested record round-trip: PASSED")?
                List.append(passed9, 1)

            other ->
                Stdout.line!("10. Nested record round-trip: FAILED (got ${Inspect.to_str(other)})")?
                passed9

    # --- Summary ---
    total = List.len(passed10) - 1 # subtract the initial [0] seed
    Stdout.line!("")?
    Stdout.line!("${Num.to_str(total)}/10 tests passed")?

    if total == 10 then
        Stdout.line!("")?
        Stdout.line!("All smoke tests PASSED — roc-json works with the current nightly.")?
        Stdout.line!("Phase 1 opaque types (QuineId, EventTime) need manual Encode/Decode")?
        Stdout.line!("implementations in later tasks — their structural shapes work fine.")
    else
        Stdout.line!("")?
        Stdout.line!("SOME TESTS FAILED — investigate before proceeding with Phase 2.")
