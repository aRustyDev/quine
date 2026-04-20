// platform/src/channels.rs

use crossbeam_channel::{bounded, Receiver, Sender, TrySendError};

/// Message tag bytes -- shard workers use these to distinguish message types
/// on the shared channel.
pub const TAG_SHARD_MSG: u8 = 0x01;
pub const TAG_TIMER: u8 = 0xFF;
pub const TAG_PERSIST_RESULT: u8 = 0xFE;

/// A tagged message on a shard's channel. The first byte is a tag
/// distinguishing shard messages from timer ticks and persist results.
pub type ShardMsg = Vec<u8>;

/// Registry of all shard channels, indexed by shard ID.
pub struct ChannelRegistry {
    senders: Vec<Sender<ShardMsg>>,
    receivers: Vec<Receiver<ShardMsg>>,
}

impl ChannelRegistry {
    pub fn new(shard_count: u32, capacity: usize) -> Self {
        let mut senders = Vec::with_capacity(shard_count as usize);
        let mut receivers = Vec::with_capacity(shard_count as usize);

        for _ in 0..shard_count {
            let (tx, rx) = bounded(capacity);
            senders.push(tx);
            receivers.push(rx);
        }

        Self { senders, receivers }
    }

    pub fn sender(&self, shard_id: u32) -> &Sender<ShardMsg> {
        &self.senders[shard_id as usize]
    }

    pub fn receiver(&self, shard_id: u32) -> &Receiver<ShardMsg> {
        &self.receivers[shard_id as usize]
    }

    /// Try to send a message to a shard. Returns false if the channel is full.
    pub fn try_send(&self, shard_id: u32, msg: ShardMsg) -> bool {
        match self.senders[shard_id as usize].try_send(msg) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) => false,
            Err(TrySendError::Disconnected(_)) => false,
        }
    }

    pub fn shard_count(&self) -> u32 {
        self.senders.len() as u32
    }
}
