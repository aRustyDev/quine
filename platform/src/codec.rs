// platform/src/codec.rs
//
// Rust-side encoder for shard envelope wire format, matching Roc Codec.roc.
// Used by the ingest pipeline to produce messages that Roc can decode.

use crate::channels::TAG_SHARD_MSG;

// LiteralCommand tag bytes (must match Codec.roc encode_literal_cmd)
const TAG_SET_PROP: u8 = 0x02;
const TAG_REMOVE_PROP: u8 = 0x03;
const TAG_ADD_EDGE: u8 = 0x04;
const TAG_REMOVE_EDGE: u8 = 0x05;

// QuineValue tag bytes (must match Codec.roc encode_quine_value)
const QV_STR: u8 = 0x01;
const QV_INTEGER: u8 = 0x02;
const QV_FLOATING: u8 = 0x03;
const QV_TRUE: u8 = 0x04;
const QV_FALSE: u8 = 0x05;
const QV_NULL: u8 = 0x06;

// EdgeDirection bytes (must match EdgeDirection.roc encode_direction)
const DIR_OUTGOING: u8 = 0x01;
const DIR_INCOMING: u8 = 0x02;

/// A parsed JSONL mutation, ready to be encoded as a shard envelope.
pub enum Mutation {
    SetProp {
        key: String,
        value: JsonValue,
    },
    RemoveProp {
        key: String,
    },
    AddEdge {
        edge_type: String,
        direction: Direction,
        other_id: [u8; 16],
    },
    RemoveEdge {
        edge_type: String,
        direction: Direction,
        other_id: [u8; 16],
    },
}

pub enum Direction {
    Outgoing,
    Incoming,
}

/// A JSON value mapped to QuineValue encoding.
pub enum JsonValue {
    Str(String),
    Integer(i64),
    Floating(f64),
    Bool(bool),
    Null,
    #[allow(dead_code)]
    List(Vec<JsonValue>),
    #[allow(dead_code)]
    Map(Vec<(String, JsonValue)>),
}

/// Encode a mutation as a complete shard channel message.
///
/// Format: [TAG_SHARD_MSG] [qid_len:U16LE] [qid_bytes...] [cmd_tag] [cmd_fields...]
pub fn encode_shard_message(qid: &[u8; 16], mutation: &Mutation) -> Vec<u8> {
    let envelope = encode_shard_envelope(qid, mutation);
    let mut msg = Vec::with_capacity(1 + envelope.len());
    msg.push(TAG_SHARD_MSG);
    msg.extend_from_slice(&envelope);
    msg
}

/// Encode the shard envelope (without the channel tag prefix).
///
/// Format: [qid_len:U16LE] [qid_bytes...] [cmd_tag] [cmd_fields...]
fn encode_shard_envelope(qid: &[u8; 16], mutation: &Mutation) -> Vec<u8> {
    let mut buf = Vec::with_capacity(64);
    encode_bytes(&mut buf, qid);
    encode_mutation(&mut buf, mutation);
    buf
}

fn encode_mutation(buf: &mut Vec<u8>, mutation: &Mutation) {
    match mutation {
        Mutation::SetProp { key, value } => {
            buf.push(TAG_SET_PROP);
            encode_u64(buf, 0); // reply_to = 0 (no reply expected from ingest)
            encode_str(buf, key);
            encode_json_value(buf, value);
        }
        Mutation::RemoveProp { key } => {
            buf.push(TAG_REMOVE_PROP);
            encode_u64(buf, 0);
            encode_str(buf, key);
        }
        Mutation::AddEdge {
            edge_type,
            direction,
            other_id,
        } => {
            buf.push(TAG_ADD_EDGE);
            encode_u64(buf, 0); // reply_to = 0 (no reply expected from ingest)
            buf.push(0x00);     // is_reciprocal = false (ingest creates originating edges)
            encode_half_edge(buf, edge_type, direction, other_id);
        }
        Mutation::RemoveEdge {
            edge_type,
            direction,
            other_id,
        } => {
            buf.push(TAG_REMOVE_EDGE);
            encode_u64(buf, 0);
            buf.push(0x00); // is_reciprocal = false
            encode_half_edge(buf, edge_type, direction, other_id);
        }
    }
}

/// Encode a HalfEdge: [edge_type:str] [direction:U8] [other_qid:bytes]
fn encode_half_edge(
    buf: &mut Vec<u8>,
    edge_type: &str,
    direction: &Direction,
    other_id: &[u8; 16],
) {
    encode_str(buf, edge_type);
    buf.push(match direction {
        Direction::Outgoing => DIR_OUTGOING,
        Direction::Incoming => DIR_INCOMING,
    });
    encode_bytes(buf, other_id);
}

/// Encode a JSON value as a QuineValue (PropertyValue Deserialized variant).
fn encode_json_value(buf: &mut Vec<u8>, value: &JsonValue) {
    match value {
        JsonValue::Str(s) => {
            buf.push(QV_STR);
            let bytes = s.as_bytes();
            buf.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
            buf.extend_from_slice(bytes);
        }
        JsonValue::Integer(n) => {
            buf.push(QV_INTEGER);
            buf.extend_from_slice(&(*n as u64).to_le_bytes());
        }
        JsonValue::Floating(f) => {
            buf.push(QV_FLOATING);
            buf.extend_from_slice(&f.to_bits().to_le_bytes());
        }
        JsonValue::Bool(true) => buf.push(QV_TRUE),
        JsonValue::Bool(false) => buf.push(QV_FALSE),
        JsonValue::Null => buf.push(QV_NULL),
        // List and Map encode as Null for now (matching Roc deferred encoding)
        JsonValue::List(_) | JsonValue::Map(_) => buf.push(QV_NULL),
    }
}

/// Encode a length-prefixed byte slice: [len:U16LE] [bytes...]
fn encode_bytes(buf: &mut Vec<u8>, bytes: &[u8]) {
    buf.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
    buf.extend_from_slice(bytes);
}

/// Encode a length-prefixed UTF-8 string: [len:U16LE] [utf8...]
fn encode_str(buf: &mut Vec<u8>, s: &str) {
    encode_bytes(buf, s.as_bytes());
}

/// Encode a U64 in little-endian.
fn encode_u64(buf: &mut Vec<u8>, n: u64) {
    buf.extend_from_slice(&n.to_le_bytes());
}

/// Convert a serde_json::Value to our JsonValue type.
pub fn json_to_value(v: &serde_json::Value) -> JsonValue {
    match v {
        serde_json::Value::Null => JsonValue::Null,
        serde_json::Value::Bool(b) => JsonValue::Bool(*b),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                JsonValue::Integer(i)
            } else if let Some(f) = n.as_f64() {
                JsonValue::Floating(f)
            } else {
                JsonValue::Null
            }
        }
        serde_json::Value::String(s) => JsonValue::Str(s.clone()),
        serde_json::Value::Array(arr) => {
            JsonValue::List(arr.iter().map(json_to_value).collect())
        }
        serde_json::Value::Object(obj) => {
            JsonValue::Map(obj.iter().map(|(k, v)| (k.clone(), json_to_value(v))).collect())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_prop_envelope_starts_with_tag() {
        let qid = [0u8; 16];
        let msg = encode_shard_message(
            &qid,
            &Mutation::SetProp {
                key: "name".into(),
                value: JsonValue::Str("Alice".into()),
            },
        );
        assert_eq!(msg[0], TAG_SHARD_MSG);
    }

    #[test]
    fn set_prop_envelope_has_qid() {
        let qid = [0xAB; 16];
        let msg = encode_shard_message(
            &qid,
            &Mutation::SetProp {
                key: "k".into(),
                value: JsonValue::Null,
            },
        );
        // After TAG_SHARD_MSG: [qid_len:U16LE=16,0] [16 bytes of 0xAB]
        assert_eq!(msg[1], 16); // len low byte
        assert_eq!(msg[2], 0);  // len high byte
        assert_eq!(&msg[3..19], &[0xAB; 16]);
    }

    #[test]
    fn set_prop_envelope_has_cmd_tag() {
        let qid = [0u8; 16];
        let msg = encode_shard_message(
            &qid,
            &Mutation::SetProp {
                key: "k".into(),
                value: JsonValue::Null,
            },
        );
        // TAG_SHARD_MSG(1) + qid_len(2) + qid(16) = offset 19
        assert_eq!(msg[19], TAG_SET_PROP);
    }

    #[test]
    fn integer_encoding() {
        let mut buf = Vec::new();
        encode_json_value(&mut buf, &JsonValue::Integer(42));
        assert_eq!(buf[0], QV_INTEGER);
        let val = u64::from_le_bytes(buf[1..9].try_into().unwrap());
        assert_eq!(val, 42);
    }

    #[test]
    fn string_encoding() {
        let mut buf = Vec::new();
        encode_json_value(&mut buf, &JsonValue::Str("hi".into()));
        assert_eq!(buf[0], QV_STR);
        assert_eq!(u16::from_le_bytes([buf[1], buf[2]]), 2);
        assert_eq!(&buf[3..5], b"hi");
    }

    #[test]
    fn edge_encoding_has_direction() {
        let qid = [0u8; 16];
        let msg = encode_shard_message(
            &qid,
            &Mutation::AddEdge {
                edge_type: "KNOWS".into(),
                direction: Direction::Outgoing,
                other_id: [1u8; 16],
            },
        );
        // TAG_SHARD_MSG(1) + qid(18) + TAG_ADD_EDGE(1) + reply_to(8) + is_reciprocal(1) = offset 29
        // Then edge_type: len(2) + "KNOWS"(5) = 7 bytes
        // Direction at offset 29 + 7 = 36
        assert_eq!(msg[19], TAG_ADD_EDGE);
        assert_eq!(msg[28], 0x00); // is_reciprocal = false
        assert_eq!(msg[36], DIR_OUTGOING);
    }
}
