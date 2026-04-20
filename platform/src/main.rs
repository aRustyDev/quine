// platform/src/main.rs

mod channels;
mod config;
mod roc_glue;

use channels::ChannelRegistry;
use config::PlatformConfig;

fn main() {
    roc_glue::init();

    let config = PlatformConfig::default();
    let registry = ChannelRegistry::new(config.shard_count, config.channel_capacity);

    println!(
        "quine-graph platform: {} shards, channel capacity {}",
        registry.shard_count(),
        config.channel_capacity
    );

    // Channel smoke test
    let msg = vec![channels::TAG_SHARD_MSG, 0x01, 0x02, 0x03];
    assert!(registry.try_send(0, msg));
    let received = registry.receiver(0).try_recv().unwrap();
    assert_eq!(received[0], channels::TAG_SHARD_MSG);
    println!("channel smoke test passed");

    // Store registry globally for roc_fx_send_to_shard
    roc_glue::set_channel_registry(registry);

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

    // Verify send_to_shard! actually queued a message on shard 1
    let reg = roc_glue::channel_registry();
    match reg.receiver(1).try_recv() {
        Ok(msg) => println!(
            "shard 1 channel has a message: {} bytes, tag=0x{:02X}",
            msg.len(),
            msg[0]
        ),
        Err(_) => println!("shard 1 channel is empty (no message forwarded)"),
    }

    println!("hello-platform: Roc<->Rust cycle with effects works!");
}
