module [
    Graph,
    GraphErr,
    new_graph,
]

import types.Config exposing [ShardConfig, default_config]

## Opaque handle to the graph runtime.
##
## Holds the shard topology and configuration that will be used to route
## operations once the platform ABI (Phase 3a) is complete.  Currently
## constructed and inspected by tests; real dispatch is wired in Phase 3a.
Graph := {
    shard_count : U32,
    config : ShardConfig,
}

## Error type for all graph operations. Includes distribution-forward variants.
##
## `NotLeader`, `Unavailable`, and nested `PersistenceErr` variants are unused
## in Phase 3 (single-node, in-process) but are present so callers handle them
## from day one.  When distribution lands the variants will start firing and no
## signature changes are required.
GraphErr : [
    Timeout,
    Unavailable,
    NotLeader,
    PersistenceErr [Unavailable, Timeout],
]

## Create a new graph handle.
##
## `shard_count` must be >= 1.  A typical value for a 4-core host is 4.
new_graph : U32, ShardConfig -> Graph
new_graph = |shard_count, config|
    @Graph({ shard_count, config })

# NOTE: The actual effectful operations (get_props!, set_prop!, add_edge!, etc.)
# depend on the platform's send_to_shard! effect. They will be wired up once
# the platform ABI (Phase 3a) is complete. The signatures are:
#
# get_props!  : Graph, NamespaceId, QuineId => Result (Dict Str PropertyValue) GraphErr
# set_prop!   : Graph, NamespaceId, QuineId, Str, PropertyValue => Result {} GraphErr
# add_edge!   : Graph, NamespaceId, QuineId, QuineId, Str => Result {} GraphErr
# remove_edge!: Graph, NamespaceId, QuineId, QuineId, Str => Result {} GraphErr
# del_node!   : Graph, NamespaceId, QuineId => Result {} GraphErr

# ===== Tests =====

expect
    g = new_graph(4, default_config)
    when g is
        @Graph({ shard_count: 4 }) -> Bool.true
        _ -> Bool.false

expect
    # shard_count is preserved verbatim
    g = new_graph(8, default_config)
    when g is
        @Graph({ shard_count: 8 }) -> Bool.true
        _ -> Bool.false

expect
    # config is preserved verbatim
    g = new_graph(4, default_config)
    when g is
        @Graph({ config }) -> config.soft_limit == 10_000
