// platform/src/cypher/expr.rs
//
// Rust-side Expr types and decoder matching Roc ExprCodec.roc.
// Decodes the binary format produced by the Roc Cypher planner.

use std::fmt;

// ===== Types =====

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Literal(QuineValue),
    Variable(String),
    Property { expr: Box<Expr>, key: String },
    Comparison { left: Box<Expr>, op: CompOp, right: Box<Expr> },
    BoolOp { left: Box<Expr>, op: BoolLogic, right: Box<Expr> },
    Not(Box<Expr>),
    IsNull(Box<Expr>),
    InList { elem: Box<Expr>, list: Box<Expr> },
    FnCall { name: String, args: Vec<Expr> },
}

#[derive(Debug, Clone, PartialEq)]
pub enum QuineValue {
    Str(String),
    Integer(i64),
    True,
    False,
    Null,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CompOp {
    Eq,
    Neq,
    Lt,
    Gt,
    Lte,
    Gte,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BoolLogic {
    And,
    Or,
}

#[derive(Debug)]
pub enum DecodeError {
    OutOfBounds,
    BadUtf8,
    InvalidTag(u8),
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::OutOfBounds => write!(f, "unexpected end of buffer"),
            DecodeError::BadUtf8 => write!(f, "invalid UTF-8 in string"),
            DecodeError::InvalidTag(tag) => write!(f, "unknown tag byte: 0x{:02x}", tag),
        }
    }
}

// ===== Expr Tag Constants (must match ExprCodec.roc) =====

const TAG_LITERAL: u8 = 0x40;
const TAG_VARIABLE: u8 = 0x41;
const TAG_PROPERTY: u8 = 0x42;
const TAG_COMPARISON: u8 = 0x43;
const TAG_BOOL_OP: u8 = 0x44;
const TAG_NOT: u8 = 0x45;
const TAG_IS_NULL: u8 = 0x46;
const TAG_IN_LIST: u8 = 0x47;
const TAG_FN_CALL: u8 = 0x48;

// ===== QuineValue Tag Constants (must match ExprCodec.roc) =====

const QV_STR: u8 = 0x01;
const QV_INTEGER: u8 = 0x02;
const QV_TRUE: u8 = 0x04;
const QV_FALSE: u8 = 0x05;
const QV_NULL: u8 = 0x06;

// ===== CompOp Constants =====

const CMP_EQ: u8 = 0x00;
const CMP_NEQ: u8 = 0x01;
const CMP_LT: u8 = 0x02;
const CMP_GT: u8 = 0x03;
const CMP_LTE: u8 = 0x04;
const CMP_GTE: u8 = 0x05;

// ===== BoolLogic Constants =====

const BOOL_AND: u8 = 0x00;
const BOOL_OR: u8 = 0x01;

// ===== Primitive Decoders =====

fn decode_u16(buf: &[u8], offset: usize) -> Result<(u16, usize), DecodeError> {
    if offset + 2 > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let val = u16::from_le_bytes([buf[offset], buf[offset + 1]]);
    Ok((val, offset + 2))
}

fn decode_u64(buf: &[u8], offset: usize) -> Result<(u64, usize), DecodeError> {
    if offset + 8 > buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let bytes: [u8; 8] = buf[offset..offset + 8].try_into().unwrap();
    let val = u64::from_le_bytes(bytes);
    Ok((val, offset + 8))
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

// ===== QuineValue Decoder =====

fn decode_quine_value(buf: &[u8], offset: usize) -> Result<(QuineValue, usize), DecodeError> {
    if offset >= buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let tag = buf[offset];
    let data_start = offset + 1;
    match tag {
        QV_STR => {
            let (s, next) = decode_string(buf, data_start)?;
            Ok((QuineValue::Str(s), next))
        }
        QV_INTEGER => {
            let (bits, next) = decode_u64(buf, data_start)?;
            Ok((QuineValue::Integer(bits as i64), next))
        }
        QV_TRUE => Ok((QuineValue::True, data_start)),
        QV_FALSE => Ok((QuineValue::False, data_start)),
        QV_NULL => Ok((QuineValue::Null, data_start)),
        _ => Err(DecodeError::InvalidTag(tag)),
    }
}

/// Decode a QuineValue from a buffer at the given offset.
/// Public so that plan.rs can use it for inline prop decoding.
pub fn decode_quine_value_from_buf(buf: &[u8], offset: usize) -> Result<(QuineValue, usize), DecodeError> {
    decode_quine_value(buf, offset)
}

// ===== CompOp Decoder =====

fn decode_comp_op(b: u8) -> Result<CompOp, DecodeError> {
    match b {
        CMP_EQ => Ok(CompOp::Eq),
        CMP_NEQ => Ok(CompOp::Neq),
        CMP_LT => Ok(CompOp::Lt),
        CMP_GT => Ok(CompOp::Gt),
        CMP_LTE => Ok(CompOp::Lte),
        CMP_GTE => Ok(CompOp::Gte),
        _ => Err(DecodeError::InvalidTag(b)),
    }
}

// ===== BoolLogic Decoder =====

fn decode_bool_logic(b: u8) -> Result<BoolLogic, DecodeError> {
    match b {
        BOOL_AND => Ok(BoolLogic::And),
        BOOL_OR => Ok(BoolLogic::Or),
        _ => Err(DecodeError::InvalidTag(b)),
    }
}

// ===== Expr Decoder =====

/// Decode an Expr tree from the buffer at the given offset.
/// Returns the decoded Expr and the new offset past the consumed bytes.
pub fn decode_expr(buf: &[u8], offset: usize) -> Result<(Expr, usize), DecodeError> {
    if offset >= buf.len() {
        return Err(DecodeError::OutOfBounds);
    }
    let tag = buf[offset];
    let data_start = offset + 1;
    match tag {
        TAG_LITERAL => {
            let (qv, next) = decode_quine_value(buf, data_start)?;
            Ok((Expr::Literal(qv), next))
        }
        TAG_VARIABLE => {
            let (name, next) = decode_string(buf, data_start)?;
            Ok((Expr::Variable(name), next))
        }
        TAG_PROPERTY => {
            let (inner, key_start) = decode_expr(buf, data_start)?;
            let (key, next) = decode_string(buf, key_start)?;
            Ok((
                Expr::Property {
                    expr: Box::new(inner),
                    key,
                },
                next,
            ))
        }
        TAG_COMPARISON => {
            let (left, op_start) = decode_expr(buf, data_start)?;
            if op_start >= buf.len() {
                return Err(DecodeError::OutOfBounds);
            }
            let op = decode_comp_op(buf[op_start])?;
            let (right, next) = decode_expr(buf, op_start + 1)?;
            Ok((
                Expr::Comparison {
                    left: Box::new(left),
                    op,
                    right: Box::new(right),
                },
                next,
            ))
        }
        TAG_BOOL_OP => {
            let (left, op_start) = decode_expr(buf, data_start)?;
            if op_start >= buf.len() {
                return Err(DecodeError::OutOfBounds);
            }
            let op = decode_bool_logic(buf[op_start])?;
            let (right, next) = decode_expr(buf, op_start + 1)?;
            Ok((
                Expr::BoolOp {
                    left: Box::new(left),
                    op,
                    right: Box::new(right),
                },
                next,
            ))
        }
        TAG_NOT => {
            let (inner, next) = decode_expr(buf, data_start)?;
            Ok((Expr::Not(Box::new(inner)), next))
        }
        TAG_IS_NULL => {
            let (inner, next) = decode_expr(buf, data_start)?;
            Ok((Expr::IsNull(Box::new(inner)), next))
        }
        TAG_IN_LIST => {
            let (elem, list_start) = decode_expr(buf, data_start)?;
            let (list, next) = decode_expr(buf, list_start)?;
            Ok((
                Expr::InList {
                    elem: Box::new(elem),
                    list: Box::new(list),
                },
                next,
            ))
        }
        TAG_FN_CALL => {
            let (name, count_start) = decode_string(buf, data_start)?;
            let (count, mut args_offset) = decode_u16(buf, count_start)?;
            let mut args = Vec::with_capacity(count as usize);
            for _ in 0..count {
                let (arg, next) = decode_expr(buf, args_offset)?;
                args.push(arg);
                args_offset = next;
            }
            Ok((Expr::FnCall { name, args }, args_offset))
        }
        _ => Err(DecodeError::InvalidTag(tag)),
    }
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: encode a U16 in little-endian.
    fn le16(n: u16) -> [u8; 2] {
        n.to_le_bytes()
    }

    /// Helper: encode a U64 in little-endian.
    fn le64(n: u64) -> [u8; 8] {
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
    fn decode_literal_str() {
        let mut buf = vec![TAG_LITERAL, QV_STR];
        buf.extend_from_slice(&prefixed_str("hello"));
        let (expr, next) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Literal(QuineValue::Str("hello".into())));
        assert_eq!(next, buf.len());
    }

    #[test]
    fn decode_literal_integer() {
        let mut buf = vec![TAG_LITERAL, QV_INTEGER];
        buf.extend_from_slice(&le64(42));
        let (expr, next) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Literal(QuineValue::Integer(42)));
        assert_eq!(next, buf.len());
    }

    #[test]
    fn decode_literal_true() {
        let buf = vec![TAG_LITERAL, QV_TRUE];
        let (expr, next) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Literal(QuineValue::True));
        assert_eq!(next, buf.len());
    }

    #[test]
    fn decode_literal_null() {
        let buf = vec![TAG_LITERAL, QV_NULL];
        let (expr, next) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Literal(QuineValue::Null));
        assert_eq!(next, buf.len());
    }

    #[test]
    fn decode_variable() {
        let mut buf = vec![TAG_VARIABLE];
        buf.extend_from_slice(&prefixed_str("n"));
        let (expr, next) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Variable("n".into()));
        assert_eq!(next, buf.len());
    }

    #[test]
    fn decode_comparison() {
        // x > 10 → Comparison { left: Variable("x"), op: Gt, right: Literal(Integer(10)) }
        let mut buf = Vec::new();
        buf.push(TAG_COMPARISON);
        // left: Variable("x")
        buf.push(TAG_VARIABLE);
        buf.extend_from_slice(&prefixed_str("x"));
        // op: Gt
        buf.push(CMP_GT);
        // right: Literal(Integer(10))
        buf.push(TAG_LITERAL);
        buf.push(QV_INTEGER);
        buf.extend_from_slice(&le64(10));

        let (expr, next) = decode_expr(&buf, 0).unwrap();
        assert_eq!(
            expr,
            Expr::Comparison {
                left: Box::new(Expr::Variable("x".into())),
                op: CompOp::Gt,
                right: Box::new(Expr::Literal(QuineValue::Integer(10))),
            }
        );
        assert_eq!(next, buf.len());
    }

    #[test]
    fn decode_not() {
        // NOT(true) → Not(Literal(True))
        let buf = vec![TAG_NOT, TAG_LITERAL, QV_TRUE];
        let (expr, next) = decode_expr(&buf, 0).unwrap();
        assert_eq!(expr, Expr::Not(Box::new(Expr::Literal(QuineValue::True))));
        assert_eq!(next, buf.len());
    }

    #[test]
    fn decode_empty_buffer_errors() {
        let result = decode_expr(&[], 0);
        assert!(matches!(result, Err(DecodeError::OutOfBounds)));
    }

    #[test]
    fn decode_unknown_tag_errors() {
        let result = decode_expr(&[0xFF], 0);
        assert!(matches!(result, Err(DecodeError::InvalidTag(0xFF))));
    }
}
