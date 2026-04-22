// platform/src/cypher/plan.rs
//
// Rust-side QueryPlan types and decoder matching Roc PlanCodec.roc.
// Decodes the binary format produced by the Roc Cypher planner.

use super::expr::{self, DecodeError, QuineValue};

// ===== Types =====

#[derive(Debug, Clone, PartialEq)]
pub struct QueryPlan {
    pub steps: Vec<PlanStep>,
    pub aliases: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PlanStep {
    ScanSeeds {
        alias_idx: usize,
        label: Option<String>,
        inline_props: Vec<(String, QuineValue)>,
        node_ids: Vec<[u8; 16]>,
    },
    Traverse {
        from_alias_idx: usize,
        to_alias_idx: usize,
        direction: Direction,
        edge_type: Option<String>,
        to_label: Option<String>,
    },
    Filter {
        expr_bytes: Vec<u8>,
    },
    Project {
        items: Vec<ProjectItem>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Direction {
    Outgoing,
    Incoming,
    Undirected,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ProjectItem {
    WholeNode(usize),
    NodeProperty {
        alias_idx: usize,
        prop: String,
        output_name: String,
    },
}

// ===== Step Tag Constants (must match PlanCodec.roc) =====

const TAG_SCAN_SEEDS: u8 = 0x30;
const TAG_TRAVERSE: u8 = 0x31;
const TAG_FILTER: u8 = 0x32;
const TAG_PROJECT: u8 = 0x33;

// ===== Project Item Tag Constants =====

const TAG_WHOLE_NODE: u8 = 0x00;
const TAG_NODE_PROPERTY: u8 = 0x01;

// ===== Direction Constants =====

const DIR_OUTGOING: u8 = 0x00;
const DIR_INCOMING: u8 = 0x01;
const DIR_UNDIRECTED: u8 = 0x02;

// ===== Label/EdgeType Option Constants =====

const LABEL_NONE: u8 = 0x00;
const LABEL_SOME: u8 = 0x01;

const EDGE_TYPE_NONE: u8 = 0x00;
const EDGE_TYPE_SOME: u8 = 0x01;

// ===== Primitive Decoders =====

fn decode_u16(buf: &[u8], offset: usize) -> Result<(u16, usize), DecodeError> {
    if offset + 2 > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let val = u16::from_le_bytes([buf[offset], buf[offset + 1]]);
    Ok((val, offset + 2))
}

fn decode_u32(buf: &[u8], offset: usize) -> Result<(u32, usize), DecodeError> {
    if offset + 4 > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let val = u32::from_le_bytes([buf[offset], buf[offset + 1], buf[offset + 2], buf[offset + 3]]);
    Ok((val, offset + 4))
}

fn decode_string(buf: &[u8], offset: usize) -> Result<(String, usize), DecodeError> {
    let (len, data_start) = decode_u16(buf, offset)?;
    let len = len as usize;
    if data_start + len > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let s = std::str::from_utf8(&buf[data_start..data_start + len])
        .map_err(|_| DecodeError::BadUtf8)?;
    Ok((s.to_owned(), data_start + len))
}

// ===== Plan Decoder =====

/// Decode a QueryPlan from a byte buffer.
///
/// Wire format:
/// [step_count : U16LE]
/// [alias_count : U16LE]
/// [aliases... : (len:U16LE, utf8)*]
/// [steps... : (tag:U8, payload)*]
pub fn decode_plan(buf: &[u8]) -> Result<QueryPlan, DecodeError> {
    if buf.is_empty() {
        return Err(DecodeError::OutOfBounds);
    }

    // Step count
    let (step_count, offset) = decode_u16(buf, 0)?;
    let step_count = step_count as usize;

    // Alias count
    let (alias_count, mut offset) = decode_u16(buf, offset)?;
    let alias_count = alias_count as usize;

    // Decode aliases
    let mut aliases = Vec::with_capacity(alias_count);
    for _ in 0..alias_count {
        let (alias, next) = decode_string(buf, offset)?;
        aliases.push(alias);
        offset = next;
    }

    // Decode steps
    let mut steps = Vec::with_capacity(step_count);
    for _ in 0..step_count {
        let (step, next) = decode_step(buf, offset)?;
        steps.push(step);
        offset = next;
    }

    Ok(QueryPlan { steps, aliases })
}

// ===== Step Decoder =====

fn decode_step(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    if offset >= buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let tag = buf[offset];
    let data_start = offset + 1;
    match tag {
        TAG_SCAN_SEEDS => decode_scan_seeds(buf, data_start),
        TAG_TRAVERSE => decode_traverse(buf, data_start),
        TAG_FILTER => decode_filter(buf, data_start),
        TAG_PROJECT => decode_project(buf, data_start),
        _ => Err(DecodeError::InvalidTag(tag)),
    }
}

// ===== ScanSeeds Decoder =====

fn decode_scan_seeds(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    // alias_idx
    let (alias_idx, offset) = decode_u16(buf, offset)?;
    let alias_idx = alias_idx as usize;

    // label (tag + optional string)
    if offset >= buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let label_tag = buf[offset];
    let (label, offset) = match label_tag {
        LABEL_NONE => (None, offset + 1),
        LABEL_SOME => {
            let (lbl, next) = decode_string(buf, offset + 1)?;
            (Some(lbl), next)
        }
        _ => return Err(DecodeError::InvalidTag(label_tag)),
    };

    // inline prop count
    let (prop_count, mut offset) = decode_u16(buf, offset)?;
    let prop_count = prop_count as usize;

    // inline props: (key:str, value:QuineValue)*
    let mut inline_props = Vec::with_capacity(prop_count);
    for _ in 0..prop_count {
        let (key, next) = decode_string(buf, offset)?;
        let (value, next) = expr::decode_quine_value_from_buf(buf, next)?;
        inline_props.push((key, value));
        offset = next;
    }

    // node_id count
    let (id_count, mut offset) = decode_u16(buf, offset)?;
    let id_count = id_count as usize;

    // node_ids: 16 bytes each
    let mut node_ids = Vec::with_capacity(id_count);
    for _ in 0..id_count {
        if offset + 16 > buf.len() {
            return Err(DecodeError::OutOfBounds);
        }
        let mut id = [0u8; 16];
        id.copy_from_slice(&buf[offset..offset + 16]);
        node_ids.push(id);
        offset += 16;
    }

    Ok((
        PlanStep::ScanSeeds {
            alias_idx,
            label,
            inline_props,
            node_ids,
        },
        offset,
    ))
}

// ===== Traverse Decoder =====

fn decode_traverse(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    // from_alias_idx
    let (from_idx, offset) = decode_u16(buf, offset)?;
    let from_alias_idx = from_idx as usize;

    // to_alias_idx
    let (to_idx, offset) = decode_u16(buf, offset)?;
    let to_alias_idx = to_idx as usize;

    // direction
    if offset >= buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let direction = match buf[offset] {
        DIR_OUTGOING => Direction::Outgoing,
        DIR_INCOMING => Direction::Incoming,
        DIR_UNDIRECTED => Direction::Undirected,
        b => return Err(DecodeError::InvalidTag(b)),
    };
    let offset = offset + 1;

    // edge type (tag + optional string)
    if offset >= buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let edge_type_tag = buf[offset];
    let (edge_type, offset) = match edge_type_tag {
        EDGE_TYPE_NONE => (None, offset + 1),
        EDGE_TYPE_SOME => {
            let (t, next) = decode_string(buf, offset + 1)?;
            (Some(t), next)
        }
        _ => return Err(DecodeError::InvalidTag(edge_type_tag)),
    };

    // to_label (tag + optional string)
    if offset >= buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let to_label_tag = buf[offset];
    let (to_label, offset) = match to_label_tag {
        LABEL_NONE => (None, offset + 1),
        LABEL_SOME => {
            let (lbl, next) = decode_string(buf, offset + 1)?;
            (Some(lbl), next)
        }
        _ => return Err(DecodeError::InvalidTag(to_label_tag)),
    };

    Ok((
        PlanStep::Traverse {
            from_alias_idx,
            to_alias_idx,
            direction,
            edge_type,
            to_label,
        },
        offset,
    ))
}

// ===== Filter Decoder =====

fn decode_filter(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    // expr_len : U32LE
    let (expr_len, expr_start) = decode_u32(buf, offset)?;
    let expr_len = expr_len as usize;

    if expr_start + expr_len > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }

    // Capture raw expr bytes — do NOT decode the Expr here.
    let expr_bytes = buf[expr_start..expr_start + expr_len].to_vec();

    Ok((PlanStep::Filter { expr_bytes }, expr_start + expr_len))
}

// ===== Project Decoder =====

fn decode_project(buf: &[u8], offset: usize) -> Result<(PlanStep, usize), DecodeError> {
    // item_count : U16LE
    let (item_count, mut offset) = decode_u16(buf, offset)?;
    let item_count = item_count as usize;

    let mut items = Vec::with_capacity(item_count);
    for _ in 0..item_count {
        if offset >= buf.len() {
            return Err(DecodeError::OutOfBounds);
        }
        let tag = buf[offset];
        let data_start = offset + 1;
        match tag {
            TAG_WHOLE_NODE => {
                let (idx, next) = decode_u16(buf, data_start)?;
                items.push(ProjectItem::WholeNode(idx as usize));
                offset = next;
            }
            TAG_NODE_PROPERTY => {
                let (idx, next) = decode_u16(buf, data_start)?;
                let (prop, next) = decode_string(buf, next)?;
                let (output_name, next) = decode_string(buf, next)?;
                items.push(ProjectItem::NodeProperty {
                    alias_idx: idx as usize,
                    prop,
                    output_name,
                });
                offset = next;
            }
            _ => return Err(DecodeError::InvalidTag(tag)),
        }
    }

    Ok((PlanStep::Project { items }, offset))
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: encode a U16 in little-endian.
    fn le16(n: u16) -> [u8; 2] {
        n.to_le_bytes()
    }

    /// Helper: encode a U32 in little-endian.
    fn le32(n: u32) -> [u8; 4] {
        n.to_le_bytes()
    }

    /// Helper: build a length-prefixed string.
    fn prefixed_str(s: &str) -> Vec<u8> {
        let bytes = s.as_bytes();
        let mut buf = Vec::new();
        buf.extend_from_slice(&le16(bytes.len() as u16));
        buf.extend_from_slice(bytes);
        buf
    }

    #[test]
    fn decode_minimal_scan() {
        // Plan: 1 step, 1 alias "n", ScanSeeds with unlabeled, no inline props, 1 node_id
        let mut buf = Vec::new();
        buf.extend_from_slice(&le16(1)); // step_count = 1
        buf.extend_from_slice(&le16(1)); // alias_count = 1
        buf.extend_from_slice(&prefixed_str("n")); // alias "n"

        // ScanSeeds step
        buf.push(TAG_SCAN_SEEDS);
        buf.extend_from_slice(&le16(0)); // alias_idx = 0
        buf.push(LABEL_NONE); // unlabeled
        buf.extend_from_slice(&le16(0)); // prop_count = 0
        buf.extend_from_slice(&le16(1)); // node_id_count = 1
        buf.extend_from_slice(&[0xAB; 16]); // node_id

        let plan = decode_plan(&buf).unwrap();
        assert_eq!(plan.aliases, vec!["n"]);
        assert_eq!(plan.steps.len(), 1);
        match &plan.steps[0] {
            PlanStep::ScanSeeds {
                alias_idx,
                label,
                inline_props,
                node_ids,
            } => {
                assert_eq!(*alias_idx, 0);
                assert_eq!(*label, None);
                assert!(inline_props.is_empty());
                assert_eq!(node_ids.len(), 1);
                assert_eq!(node_ids[0], [0xAB; 16]);
            }
            _ => panic!("expected ScanSeeds"),
        }
    }

    #[test]
    fn decode_traverse_step() {
        // Plan: 1 Traverse step, 2 aliases "a" and "b"
        let mut buf = Vec::new();
        buf.extend_from_slice(&le16(1)); // step_count = 1
        buf.extend_from_slice(&le16(2)); // alias_count = 2
        buf.extend_from_slice(&prefixed_str("a"));
        buf.extend_from_slice(&prefixed_str("b"));

        // Traverse step
        buf.push(TAG_TRAVERSE);
        buf.extend_from_slice(&le16(0)); // from_alias_idx = 0 ("a")
        buf.extend_from_slice(&le16(1)); // to_alias_idx = 1 ("b")
        buf.push(DIR_OUTGOING); // direction
        buf.push(EDGE_TYPE_SOME); // typed edge
        buf.extend_from_slice(&prefixed_str("KNOWS")); // edge type
        buf.push(LABEL_NONE); // to_label = unlabeled

        let plan = decode_plan(&buf).unwrap();
        match &plan.steps[0] {
            PlanStep::Traverse {
                from_alias_idx,
                to_alias_idx,
                direction,
                edge_type,
                to_label,
            } => {
                assert_eq!(*from_alias_idx, 0);
                assert_eq!(*to_alias_idx, 1);
                assert_eq!(*direction, Direction::Outgoing);
                assert_eq!(edge_type.as_deref(), Some("KNOWS"));
                assert_eq!(*to_label, None);
            }
            _ => panic!("expected Traverse"),
        }
    }

    #[test]
    fn decode_filter_step() {
        // Plan: 1 Filter step, 1 alias
        let mut buf = Vec::new();
        buf.extend_from_slice(&le16(1)); // step_count = 1
        buf.extend_from_slice(&le16(1)); // alias_count = 1
        buf.extend_from_slice(&prefixed_str("n"));

        // Build expr bytes: Literal(True) = [0x40, 0x04]
        let expr_bytes = vec![0x40u8, 0x04];

        // Filter step
        buf.push(TAG_FILTER);
        buf.extend_from_slice(&le32(expr_bytes.len() as u32)); // expr_len
        buf.extend_from_slice(&expr_bytes); // raw expr bytes

        let plan = decode_plan(&buf).unwrap();
        match &plan.steps[0] {
            PlanStep::Filter {
                expr_bytes: decoded_bytes,
            } => {
                assert_eq!(decoded_bytes, &expr_bytes);
            }
            _ => panic!("expected Filter"),
        }
    }

    #[test]
    fn decode_project_whole_node() {
        // Plan: 1 Project step with WholeNode, 1 alias
        let mut buf = Vec::new();
        buf.extend_from_slice(&le16(1)); // step_count = 1
        buf.extend_from_slice(&le16(1)); // alias_count = 1
        buf.extend_from_slice(&prefixed_str("n"));

        // Project step
        buf.push(TAG_PROJECT);
        buf.extend_from_slice(&le16(1)); // item_count = 1
        buf.push(TAG_WHOLE_NODE);
        buf.extend_from_slice(&le16(0)); // alias_idx = 0

        let plan = decode_plan(&buf).unwrap();
        match &plan.steps[0] {
            PlanStep::Project { items } => {
                assert_eq!(items.len(), 1);
                assert_eq!(items[0], ProjectItem::WholeNode(0));
            }
            _ => panic!("expected Project"),
        }
    }

    #[test]
    fn decode_project_node_property() {
        // Plan: 1 Project step with NodeProperty, 1 alias
        let mut buf = Vec::new();
        buf.extend_from_slice(&le16(1)); // step_count = 1
        buf.extend_from_slice(&le16(1)); // alias_count = 1
        buf.extend_from_slice(&prefixed_str("n"));

        // Project step
        buf.push(TAG_PROJECT);
        buf.extend_from_slice(&le16(1)); // item_count = 1
        buf.push(TAG_NODE_PROPERTY);
        buf.extend_from_slice(&le16(0)); // alias_idx = 0
        buf.extend_from_slice(&prefixed_str("name")); // prop
        buf.extend_from_slice(&prefixed_str("full_name")); // output_name

        let plan = decode_plan(&buf).unwrap();
        match &plan.steps[0] {
            PlanStep::Project { items } => {
                assert_eq!(items.len(), 1);
                assert_eq!(
                    items[0],
                    ProjectItem::NodeProperty {
                        alias_idx: 0,
                        prop: "name".into(),
                        output_name: "full_name".into(),
                    }
                );
            }
            _ => panic!("expected Project"),
        }
    }

    #[test]
    fn decode_empty_buffer_errors() {
        let result = decode_plan(&[]);
        assert!(matches!(result, Err(DecodeError::OutOfBounds)));
    }

    #[test]
    fn decode_unknown_step_tag_errors() {
        // Plan header: 1 step, 0 aliases, then unknown tag
        let mut buf = Vec::new();
        buf.extend_from_slice(&le16(1)); // step_count = 1
        buf.extend_from_slice(&le16(0)); // alias_count = 0
        buf.push(0xFF); // unknown step tag

        let result = decode_plan(&buf);
        assert!(matches!(result, Err(DecodeError::InvalidTag(0xFF))));
    }
}
