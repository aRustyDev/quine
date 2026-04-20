// platform/src/main.rs

mod config;
mod roc_glue;

use config::PlatformConfig;

fn main() {
    let config = PlatformConfig::default();
    println!(
        "quine-graph platform starting with {} shards",
        config.shard_count
    );

    // Initialize one shard as a smoke test
    let state = roc_glue::call_init_shard(0);
    println!("shard 0 initialized, state ptr: {:?}", state);

    // Send a dummy message
    let msg = b"hello";
    let state2 = roc_glue::call_handle_message(state, msg);
    println!("shard 0 after message, state ptr: {:?}", state2);

    // Fire a timer tick
    let state3 = roc_glue::call_on_timer(state2, 0);
    println!("shard 0 after timer, state ptr: {:?}", state3);

    println!("hello-platform: Roc<->Rust cycle works!");
}
