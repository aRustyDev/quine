// platform/src/persistence_io.rs

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crossbeam_channel::{Receiver, Sender};
use redb::{Database, ReadableTable, TableDefinition};

use crate::channels::{ShardMsg, TAG_PERSIST_RESULT};

/// redb table: QuineId bytes → snapshot bytes.
const SNAPSHOTS: TableDefinition<&[u8], &[u8]> = TableDefinition::new("snapshots");

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

/// Open (or create) the redb database at the given path.
pub fn open_database(path: &Path) -> Arc<Database> {
    let db = Database::create(path).expect("Failed to open redb database");
    // Ensure the snapshots table exists by running an empty write txn.
    {
        let txn = db.begin_write().expect("Failed to begin initial write txn");
        txn.open_table(SNAPSHOTS).expect("Failed to create snapshots table");
        txn.commit().expect("Failed to commit initial txn");
    }
    Arc::new(db)
}

/// Start the persistence pool backed by redb.
///
/// Receives PersistCommands on a crossbeam channel, stores/loads snapshots
/// via redb, and sends results back to the requesting shard.
///
/// Returns the command sender for callers to submit persist operations.
pub fn start_persistence_pool(
    shard_senders: Vec<Sender<ShardMsg>>,
    rt: &tokio::runtime::Runtime,
    db: Arc<Database>,
) -> Sender<PersistCommand> {
    let (cmd_tx, cmd_rx) = crossbeam_channel::bounded::<PersistCommand>(4096);

    rt.spawn(async move {
        run_persistence_loop(cmd_rx, shard_senders, db);
    });

    cmd_tx
}

/// The persistence loop: blocks on the command receiver, processes each command.
fn run_persistence_loop(
    cmd_rx: Receiver<PersistCommand>,
    shard_senders: Vec<Sender<ShardMsg>>,
    db: Arc<Database>,
) {
    loop {
        match cmd_rx.recv() {
            Ok(cmd) => process_command(&db, &shard_senders, cmd),
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
    db: &Database,
    shard_senders: &[Sender<ShardMsg>],
    cmd: PersistCommand,
) {
    if cmd.payload.is_empty() {
        eprintln!("persistence pool: empty payload, ignoring");
        return;
    }

    match cmd.payload[0] {
        0x01 => handle_persist_snapshot(db, &cmd.payload),
        0x02 => handle_load_snapshot(db, shard_senders, cmd.shard_id, &cmd.payload),
        tag => {
            eprintln!("persistence pool: unknown command tag 0x{:02X}", tag);
        }
    }
}

/// PersistSnapshot: parse QuineId, write snapshot to redb.
fn handle_persist_snapshot(db: &Database, payload: &[u8]) {
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

    let txn = match db.begin_write() {
        Ok(txn) => txn,
        Err(e) => {
            eprintln!("persistence pool: begin_write failed: {}", e);
            return;
        }
    };
    {
        let mut table = match txn.open_table(SNAPSHOTS) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("persistence pool: open_table failed: {}", e);
                return;
            }
        };
        // Map Ok to () to drop the AccessGuard before table goes out of scope.
        if let Err(e) = table.insert(id_bytes, snapshot_bytes).map(|_| ()) {
            eprintln!("persistence pool: insert failed: {}", e);
            return;
        }
    }
    if let Err(e) = txn.commit() {
        eprintln!("persistence pool: commit failed: {}", e);
    }
}

/// LoadSnapshot: look up QuineId in redb, send result back to requesting shard.
///
/// Result format sent to shard channel:
///   Found:     [TAG_PERSIST_RESULT][0x01][id_len:U16LE][id_bytes...][snap_len:U32LE][snapshot_bytes...]
///   Not found: [TAG_PERSIST_RESULT][0x00][id_len:U16LE][id_bytes...]
fn handle_load_snapshot(
    db: &Database,
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

    // Read snapshot from redb. Copy data out before dropping the transaction.
    let txn = match db.begin_read() {
        Ok(txn) => txn,
        Err(e) => {
            eprintln!("persistence pool: begin_read failed: {}", e);
            return;
        }
    };
    let table = match txn.open_table(SNAPSHOTS) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("persistence pool: open_table for read failed: {}", e);
            return;
        }
    };
    let snapshot_data: Option<Vec<u8>> = match table.get(id_bytes) {
        Ok(Some(guard)) => Some(guard.value().to_vec()),
        Ok(None) => None,
        Err(e) => {
            eprintln!("persistence pool: get failed: {}", e);
            return;
        }
    };

    let result_msg = match snapshot_data {
        Some(snapshot) => {
            let snap_len = snapshot.len() as u32;
            let mut msg = Vec::with_capacity(1 + 1 + 2 + id_len + 4 + snapshot.len());
            msg.push(TAG_PERSIST_RESULT);
            msg.push(0x01); // found
            msg.extend_from_slice(&(id_len as u16).to_le_bytes());
            msg.extend_from_slice(id_bytes);
            msg.extend_from_slice(&snap_len.to_le_bytes());
            msg.extend_from_slice(&snapshot);
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

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_db() -> (tempfile::TempDir, Arc<Database>) {
        let dir = tempfile::tempdir().unwrap();
        let db = open_database(&dir.path().join("test.redb"));
        (dir, db)
    }

    #[test]
    fn persist_and_load_roundtrip() {
        let (_dir, db) = temp_db();
        let (tx, rx) = crossbeam_channel::bounded(16);
        let shard_senders = vec![tx];

        // PersistSnapshot: [0x01][id_len:2][id:0xAB,0xCD][snapshot:0x01,0x02,0x03]
        let persist_payload = vec![0x01, 2, 0, 0xAB, 0xCD, 0x01, 0x02, 0x03];
        process_command(&db, &shard_senders, PersistCommand {
            request_id: 1,
            shard_id: 0,
            payload: persist_payload,
        });

        // LoadSnapshot: [0x02][id_len:2][id:0xAB,0xCD]
        let load_payload = vec![0x02, 2, 0, 0xAB, 0xCD];
        process_command(&db, &shard_senders, PersistCommand {
            request_id: 2,
            shard_id: 0,
            payload: load_payload,
        });

        let result = rx.recv().unwrap();
        assert_eq!(result[0], TAG_PERSIST_RESULT);
        assert_eq!(result[1], 0x01); // found
        // id_len = 2
        assert_eq!(u16::from_le_bytes([result[2], result[3]]), 2);
        // id bytes
        assert_eq!(&result[4..6], &[0xAB, 0xCD]);
        // snap_len = 3
        assert_eq!(u32::from_le_bytes(result[6..10].try_into().unwrap()), 3);
        // snapshot bytes
        assert_eq!(&result[10..13], &[0x01, 0x02, 0x03]);
    }

    #[test]
    fn load_not_found() {
        let (_dir, db) = temp_db();
        let (tx, rx) = crossbeam_channel::bounded(16);
        let shard_senders = vec![tx];

        let load_payload = vec![0x02, 1, 0, 0xFF];
        process_command(&db, &shard_senders, PersistCommand {
            request_id: 1,
            shard_id: 0,
            payload: load_payload,
        });

        let result = rx.recv().unwrap();
        assert_eq!(result[0], TAG_PERSIST_RESULT);
        assert_eq!(result[1], 0x00); // not found
    }

    #[test]
    fn persist_overwrites() {
        let (_dir, db) = temp_db();
        let (tx, rx) = crossbeam_channel::bounded(16);
        let shard_senders = vec![tx];

        // Write version 1
        let persist1 = vec![0x01, 1, 0, 0x01, 0xAA];
        process_command(&db, &shard_senders, PersistCommand {
            request_id: 1,
            shard_id: 0,
            payload: persist1,
        });

        // Overwrite with version 2
        let persist2 = vec![0x01, 1, 0, 0x01, 0xBB, 0xCC];
        process_command(&db, &shard_senders, PersistCommand {
            request_id: 2,
            shard_id: 0,
            payload: persist2,
        });

        // Load should return version 2
        let load = vec![0x02, 1, 0, 0x01];
        process_command(&db, &shard_senders, PersistCommand {
            request_id: 3,
            shard_id: 0,
            payload: load,
        });

        let result = rx.recv().unwrap();
        assert_eq!(result[1], 0x01); // found
        let snap_len = u32::from_le_bytes(result[5..9].try_into().unwrap()) as usize;
        assert_eq!(snap_len, 2);
        assert_eq!(&result[9..11], &[0xBB, 0xCC]);
    }

    #[test]
    fn database_survives_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("reopen.redb");

        // Write a snapshot
        {
            let db = open_database(&db_path);
            let persist = vec![0x01, 1, 0, 0x42, 0xDE, 0xAD];
            let (tx, _rx) = crossbeam_channel::bounded(16);
            process_command(&db, &[tx], PersistCommand {
                request_id: 1,
                shard_id: 0,
                payload: persist,
            });
        }

        // Reopen and load
        {
            let db = open_database(&db_path);
            let (tx, rx) = crossbeam_channel::bounded(16);
            let load = vec![0x02, 1, 0, 0x42];
            process_command(&db, &[tx], PersistCommand {
                request_id: 2,
                shard_id: 0,
                payload: load,
            });

            let result = rx.recv().unwrap();
            assert_eq!(result[1], 0x01); // found
            let snap_start = 5 + 4; // tag + found + id_len(2) + id(1) + snap_len(4)
            assert_eq!(&result[snap_start..snap_start + 2], &[0xDE, 0xAD]);
        }
    }
}
