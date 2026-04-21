app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br",
    id: "../packages/core/id/main.roc",
    model: "../packages/core/model/main.roc",
    shard: "../packages/graph/shard/main.roc",
    types: "../packages/graph/types/main.roc",
    standing_ast: "../packages/graph/standing/ast/main.roc",
    standing_state: "../packages/graph/standing/state/main.roc",
    standing_result: "../packages/graph/standing/result/main.roc",
}

import cli.Stdout
import cli.Arg exposing [Arg]
import id.QuineId
import model.PropertyValue
import model.NodeEvent exposing [NodeChangeEvent]
import types.NodeEntry exposing [empty_node_state]
import types.Config exposing [default_config]
import shard.SqDispatch
import shard.ShardState
import standing_ast.MvStandingQuery exposing [MvStandingQuery]
import standing_result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId]
import standing_state.SqPartState exposing [SqMsgSubscriber]

main! : List Arg => Result {} _
main! = |_args|
    Stdout.line!("=== Phase 4 Standing Query Smoke Test ===")?
    Stdout.line!("")?

    # Scenario 1: Single-node property match
    Stdout.line!("--- Scenario 1: Single-node property match ---")?
    qid = QuineId.from_bytes([0x01, 0x02, 0x03])
    node0 = empty_node_state(qid)

    query : MvStandingQuery
    query = LocalProperty({ prop_key: "name", constraint: Any, aliased_as: Ok("n") })
    pid : StandingQueryPartId
    pid = MvStandingQuery.query_part_id(query)
    global_id : StandingQueryId
    global_id = 1u128

    lookup = |p| if p == pid then Ok(query) else Err(NotFound)

    # Create subscription
    subscriber : SqMsgSubscriber
    subscriber = GlobalSubscriber({ global_id })
    create_result = SqDispatch.handle_sq_command(
        node0,
        CreateSqSubscription({ subscriber, query, global_id }),
        lookup)
    sq_count = Dict.len(create_result.state.sq_states)
    Stdout.line!("  Created subscription: $(Num.to_str(sq_count)) SQ state(s)")?
    effects1_count = List.len(create_result.effects)
    Stdout.line!("  Initial effects: $(Num.to_str(effects1_count))")?

    # Set property
    pv = PropertyValue.from_value(Str("Alice"))
    events : List NodeChangeEvent
    events = [PropertySet({ key: "name", value: pv })]
    dispatch_result = SqDispatch.dispatch_sq_events(create_result.state, events, lookup)
    emit_count = List.count_if(dispatch_result.effects, |e|
        when e is
            EmitSqResult(_) -> Bool.true
            _ -> Bool.false)
    Stdout.line!("  After SetProp: $(Num.to_str(emit_count)) EmitSqResult effect(s)")?

    if emit_count > 0 then
        Stdout.line!("  PASS: SQ result emitted for property match")?
    else
        Stdout.line!("  FAIL: No SQ result emitted")?

    Stdout.line!("")?

    # Scenario 2: SQ registration on shard with broadcast
    Stdout.line!("--- Scenario 2: Shard-level SQ registration ---")?
    shard0 = ShardState.new(0, 4, default_config)
    shard1 = ShardState.register_standing_query(shard0, 1u128, query, Bool.true)
    lookup_result = ShardState.lookup_query(shard1, pid)
    registered = when lookup_result is
        Ok(_) -> "yes"
        Err(_) -> "no"
    Stdout.line!("  Query registered in part_index: $(registered)")?

    if registered == "yes" then
        Stdout.line!("  PASS: SQ registered in shard")?
    else
        Stdout.line!("  FAIL: SQ not found in shard")?

    Stdout.line!("")?
    Stdout.line!("=== Smoke test complete ===")?
    Ok({})
