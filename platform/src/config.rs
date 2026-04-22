// platform/src/config.rs

use serde::{Deserialize, Serialize};

/// Configuration for the platform runtime.
///
/// Loaded via Figment with priority: CLI args > QUINE_* env vars > config file > defaults.
#[derive(Deserialize, Serialize)]
#[serde(default)]
pub struct PlatformConfig {
    pub shard_count: u32,
    pub channel_capacity: usize,
    pub lru_check_interval_ms: u64,
    pub persistence_pool_size: u32,
    pub api_port: u16,
    pub data_dir: String,
}

impl Default for PlatformConfig {
    fn default() -> Self {
        Self {
            shard_count: 4,
            channel_capacity: 4096,
            lru_check_interval_ms: 10_000,
            persistence_pool_size: 2,
            api_port: 8080,
            data_dir: "quine-data".into(),
        }
    }
}
