module [
    ShardConfig,
    default_config,
    SqConfig,
    default_sq_config,
]

## Tuning knobs for a shard actor.
##
## The shard uses these values to decide when to put nodes to sleep, how
## aggressively to enforce node count limits, and how long to wait for
## node responses before timing out.
##
## All time values are in milliseconds.
ShardConfig : {
    ## Target maximum number of awake nodes. Above this the shard begins
    ## considering nodes for sleep (soft eviction pressure).
    soft_limit : U32,
    ## Absolute maximum awake nodes. Above this the shard declines new
    ## work until nodes sleep (hard back-pressure).
    hard_limit : U32,
    ## How often the shard wakes up to check the LRU list for sleep candidates.
    lru_check_interval_ms : U64,
    ## How long the shard waits for a node to respond to a message.
    ask_timeout_ms : U64,
    ## Do not sleep a node if it was written to within this many milliseconds.
    decline_sleep_when_write_within_ms : U64,
    ## Do not sleep a node if it was accessed within this many milliseconds.
    ## Zero means any access is OK to sleep after (only writes block sleep).
    decline_sleep_when_access_within_ms : U64,
    ## Maximum time a node may spend in ConsideringSleep before being forced
    ## to sleep or return to Awake.
    sleep_deadline_ms : U64,
    ## Log a warning when any node's edge count exceeds this threshold.
    max_edges_warning_threshold : U64,
}

## Default production-like shard configuration.
##
## Values mirror the Scala Quine defaults, scaled for the Roc port.
default_config : ShardConfig
default_config = {
    soft_limit: 10_000,
    hard_limit: 50_000,
    lru_check_interval_ms: 10_000,
    ask_timeout_ms: 5_000,
    decline_sleep_when_write_within_ms: 100,
    decline_sleep_when_access_within_ms: 0,
    sleep_deadline_ms: 3_000,
    max_edges_warning_threshold: 100_000,
}

## Standing query configuration.
SqConfig : {
    ## Maximum number of buffered SQ results before backpressure is emitted.
    result_buffer_size : U32,
    ## Buffer fill level at which backpressure is emitted (typically 75%).
    backpressure_threshold : U32,
    ## Whether to emit cancellation results when a match no longer holds.
    include_cancellations : Bool,
}

## Default standing query configuration.
default_sq_config : SqConfig
default_sq_config = {
    result_buffer_size: 1024,
    backpressure_threshold: 768,
    include_cancellations: Bool.true,
}

# ===== Tests =====

expect
    default_config.soft_limit == 10_000

expect
    default_config.hard_limit == 50_000

expect
    # soft limit is always less than hard limit
    default_config.soft_limit < default_config.hard_limit

expect
    default_config.lru_check_interval_ms == 10_000

expect
    default_config.ask_timeout_ms == 5_000

expect
    default_config.sleep_deadline_ms == 3_000

expect
    default_config.max_edges_warning_threshold == 100_000
