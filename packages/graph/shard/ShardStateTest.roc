module []

import id.QuineId
import types.Config exposing [default_config]
import types.NodeEntry exposing [NodeEntry, empty_node_state]
import model.PropertyValue
import ShardState

# ===== Tests =====

expect
    # Test 1: Message to unknown node triggers Waking state.
    #
    # Send a SetProp to a QuineId that is not yet in the shard. The shard
    # calls start_wake, which inserts a Waking entry with the message queued.
    shard = ShardState.new(0, 4, default_config)
    qid = QuineId.from_bytes([0xAA])
    pv = PropertyValue.from_value(Str("hello"))
    msg = LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 1 }))
    result = ShardState.handle_message(shard, qid, msg, 1000)
    when ShardState.node_entry(result, qid) is
        Ok(Waking(_)) -> Bool.true
        _ -> Bool.false

expect
    # Test 2: Awake node dispatch — SetProp followed by GetProps returns the stored value.
    #
    # Manually insert an Awake entry, send SetProp, then GetProps. The
    # pending_effects after GetProps must include a Props reply containing
    # the key that was written.
    qid = QuineId.from_bytes([0xBB])
    ns = empty_node_state(qid)
    awake_entry : NodeEntry
    awake_entry = Awake({
        state: ns,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: 100,
        last_access: 100,
    })
    shard = ShardState.new(0, 4, default_config)
    shard_with_node = ShardState.with_awake_node(shard, qid, awake_entry)
    pv = PropertyValue.from_value(Str("alice"))
    set_msg = LiteralCmd(SetProp({ key: "name", value: pv, reply_to: 10 }))
    after_set = ShardState.handle_message(shard_with_node, qid, set_msg, 200)
    get_msg = LiteralCmd(GetProps({ reply_to: 11 }))
    after_get = ShardState.handle_message(after_set, qid, get_msg, 300)
    List.any(
        ShardState.pending_effects(after_get),
        |e|
            when e is
                Reply({ payload: Props(props) }) -> Dict.contains(props, "name")
                _ -> Bool.false,
    )

expect
    # Test 3: LRU eviction on_timer emits Persist effects for excess awake nodes.
    #
    # Build a shard with soft_limit=1 and two awake nodes with old timestamps
    # so should_decline_sleep does not block them. Also insert matching LRU
    # entries. Call on_timer; pending_effects must include at least one Persist
    # effect, confirming begin_sleep ran for the excess node.
    small_config = { default_config & soft_limit: 1 }
    qid_a = QuineId.from_bytes([0xCC])
    qid_b = QuineId.from_bytes([0xDD])
    ns_a = empty_node_state(qid_a)
    ns_b = empty_node_state(qid_b)
    # last_write=0, now=100_000 => diff 100_000 >= default decline_sleep_when_write_within_ms (100)
    # => not a recent write => OK to sleep.
    old_ts = 0u64
    awake_a : NodeEntry
    awake_a = Awake({
        state: ns_a,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: old_ts,
        last_access: old_ts,
    })
    awake_b : NodeEntry
    awake_b = Awake({
        state: ns_b,
        wakeful: Awake,
        cost_to_sleep: 0,
        last_write: old_ts,
        last_access: old_ts,
    })
    shard = ShardState.new(0, 4, small_config)
    shard_with_nodes =
        ShardState.with_awake_node(shard, qid_a, awake_a)
        |> ShardState.with_awake_node(qid_b, awake_b)
        |> ShardState.with_lru_entry(qid_a, old_ts, 0)
        |> ShardState.with_lru_entry(qid_b, old_ts, 0)
    now = 100_000u64
    result = ShardState.on_timer(shard_with_nodes, now)
    List.any(
        ShardState.pending_effects(result),
        |e|
            when e is
                Persist(_) -> Bool.true
                _ -> Bool.false,
    )
