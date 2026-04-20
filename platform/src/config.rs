// platform/src/config.rs

/// Configuration for the platform runtime.
pub struct PlatformConfig {
    pub shard_count: u32,
    pub channel_capacity: usize,
    pub lru_check_interval_ms: u64,
    pub persistence_pool_size: u32,
}

impl Default for PlatformConfig {
    fn default() -> Self {
        Self {
            shard_count: 4,
            channel_capacity: 4096,
            lru_check_interval_ms: 10_000,
            persistence_pool_size: 2,
        }
    }
}
