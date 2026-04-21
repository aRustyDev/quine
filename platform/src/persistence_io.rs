// platform/src/persistence_io.rs

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};

use crossbeam_channel::{Receiver, Sender};

use crate::channels::{ShardMsg, TAG_PERSIST_RESULT};

/// A command sent from a shard worker to the persistence pool.
pub struct PersistCommand {
    pub request_id: u64,
    pub shard_id: u32,
    pub payload: Vec<u8>,
}

/// Global atomic counter for generating unique request IDs.
static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(1);

/// Generate a monotonically increasing request ID.
pub fn next_request_id() -> u64 {
    REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// Start the in-memory persistence pool.
///
/// Receives PersistCommands on a crossbeam channel, stores/loads snapshots
/// in a HashMap, and sends results back to the requesting shard.
///
/// Returns the command sender for callers to submit persist operations.
pub fn start_persistence_pool(
    shard_senders: Vec<Sender<ShardMsg>>,
    rt: &tokio::runtime::Runtime,
) -> Sender<PersistCommand> {
    let (cmd_tx, cmd_rx) = crossbeam_channel::bounded::<PersistCommand>(4096);

    rt.spawn(async move {
        run_persistence_loop(cmd_rx, shard_senders);
    });

    cmd_tx
}

/// The persistence loop: blocks on the command receiver, processes each command.
fn run_persistence_loop(
    cmd_rx: Receiver<PersistCommand>,
    shard_senders: Vec<Sender<ShardMsg>>,
) {
    let mut store: HashMap<Vec<u8>, Vec<u8>> = HashMap::new();

    loop {
        match cmd_rx.recv() {
            Ok(cmd) => process_command(&mut store, &shard_senders, cmd),
            Err(_) => {
                eprintln!("persistence pool: command channel closed, shutting down");
                break;
            }
        }
    }
}

/// Process a single persist command.
///
/// Wire format (from Roc encode_persist_command):
///   PersistSnapshot: [0x01][id_len:U16LE][id_bytes...][snapshot_bytes...]
///   LoadSnapshot:    [0x02][id_len:U16LE][id_bytes...]
fn process_command(
    store: &mut HashMap<Vec<u8>, Vec<u8>>,
    shard_senders: &[Sender<ShardMsg>],
    cmd: PersistCommand,
) {
    if cmd.payload.is_empty() {
        eprintln!("persistence pool: empty payload, ignoring");
        return;
    }

    match cmd.payload[0] {
        0x01 => handle_persist_snapshot(store, &cmd.payload),
        0x02 => handle_load_snapshot(store, shard_senders, cmd.shard_id, &cmd.payload),
        tag => {
            eprintln!("persistence pool: unknown command tag 0x{:02X}", tag);
        }
    }
}

/// PersistSnapshot: parse QuineId, store snapshot bytes.
fn handle_persist_snapshot(store: &mut HashMap<Vec<u8>, Vec<u8>>, payload: &[u8]) {
    if payload.len() < 3 {
        eprintln!("persistence pool: PersistSnapshot payload too short");
        return;
    }
    let id_len = u16::from_le_bytes([payload[1], payload[2]]) as usize;
    let id_end = 3 + id_len;
    if payload.len() < id_end {
        eprintln!("persistence pool: PersistSnapshot truncated id");
        return;
    }
    let id_bytes = &payload[3..id_end];
    let snapshot_bytes = &payload[id_end..];

    store.insert(id_bytes.to_vec(), snapshot_bytes.to_vec());
}

/// LoadSnapshot: look up QuineId, send result back to requesting shard.
///
/// Result format sent to shard channel:
///   Found:     [TAG_PERSIST_RESULT][0x01][id_len:U16LE][id_bytes...][snap_len:U32LE][snapshot_bytes...]
///   Not found: [TAG_PERSIST_RESULT][0x00][id_len:U16LE][id_bytes...]
fn handle_load_snapshot(
    store: &HashMap<Vec<u8>, Vec<u8>>,
    shard_senders: &[Sender<ShardMsg>],
    shard_id: u32,
    payload: &[u8],
) {
    if payload.len() < 3 {
        eprintln!("persistence pool: LoadSnapshot payload too short");
        return;
    }
    let id_len = u16::from_le_bytes([payload[1], payload[2]]) as usize;
    let id_end = 3 + id_len;
    if payload.len() < id_end {
        eprintln!("persistence pool: LoadSnapshot truncated id");
        return;
    }
    let id_bytes = &payload[3..id_end];

    let result_msg = match store.get(id_bytes) {
        Some(snapshot) => {
            let snap_len = snapshot.len() as u32;
            let mut msg = Vec::with_capacity(1 + 1 + 2 + id_len + 4 + snapshot.len());
            msg.push(TAG_PERSIST_RESULT);
            msg.push(0x01); // found
            msg.extend_from_slice(&(id_len as u16).to_le_bytes());
            msg.extend_from_slice(id_bytes);
            msg.extend_from_slice(&snap_len.to_le_bytes());
            msg.extend_from_slice(snapshot);
            msg
        }
        None => {
            let mut msg = Vec::with_capacity(1 + 1 + 2 + id_len);
            msg.push(TAG_PERSIST_RESULT);
            msg.push(0x00); // not found
            msg.extend_from_slice(&(id_len as u16).to_le_bytes());
            msg.extend_from_slice(id_bytes);
            msg
        }
    };

    if let Some(sender) = shard_senders.get(shard_id as usize) {
        if sender.send(result_msg).is_err() {
            eprintln!(
                "persistence pool: failed to send result to shard {}",
                shard_id
            );
        }
    } else {
        eprintln!("persistence pool: invalid shard_id {}", shard_id);
    }
}
