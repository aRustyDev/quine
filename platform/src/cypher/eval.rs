// platform/src/cypher/eval.rs
//
// Expression evaluator and row projection for the Cypher query executor.
// Evaluates Expr trees against a row of bound NodeData, and projects
// result rows into JSON for API responses.

use std::collections::HashMap;

use serde_json;

use super::expr::{BoolLogic, CompOp, Expr, QuineValue};
use super::plan::{Direction, ProjectItem};

// ===== Types =====

/// Data associated with a single graph node in a query result row.
#[derive(Debug, Clone)]
pub struct NodeData {
    pub id: [u8; 16],
    pub id_str: String,
    pub properties: HashMap<String, QuineValue>,
    pub edges: Vec<HalfEdge>,
}

/// One side of an edge as seen from a node.
#[derive(Debug, Clone)]
pub struct HalfEdge {
    pub edge_type: String,
    pub direction: Direction,
    pub other_id: [u8; 16],
}

/// A row in query evaluation: one slot per alias, `None` if unbound.
pub type Row = Vec<Option<NodeData>>;

// ===== Helpers =====

/// Find the index of an alias name in the alias list.
pub fn alias_idx(name: &str, aliases: &[String]) -> Option<usize> {
    aliases.iter().position(|a| a == name)
}

/// Cypher truthiness: True and non-null/non-false values are truthy.
/// Null is not truthy. False is not truthy.
pub fn is_truthy(v: &QuineValue) -> bool {
    match v {
        QuineValue::Null => false,
        QuineValue::False => false,
        _ => true, // True, Integer, Str are all truthy
    }
}

// ===== Expression Evaluator =====

/// Recursively evaluate an Expr against a row of bound nodes.
///
/// `row` contains one `Option<NodeData>` per alias index.
/// `aliases` maps alias names to their indices in `row`.
pub fn eval_expr(expr: &Expr, row: &Row, aliases: &[String]) -> QuineValue {
    match expr {
        Expr::Literal(v) => v.clone(),

        // Standalone variable access returns Null (variables are only
        // meaningful as the base of a Property access or as fn args).
        Expr::Variable(_) => QuineValue::Null,

        Expr::Property { expr: base, key } => {
            if let Expr::Variable(name) = base.as_ref() {
                if let Some(idx) = alias_idx(name, aliases) {
                    if let Some(Some(node)) = row.get(idx) {
                        return node
                            .properties
                            .get(key)
                            .cloned()
                            .unwrap_or(QuineValue::Null);
                    }
                }
            }
            QuineValue::Null
        }

        Expr::Comparison { left, op, right } => {
            let lv = eval_expr(left, row, aliases);
            let rv = eval_expr(right, row, aliases);
            eval_comparison(&lv, *op, &rv)
        }

        Expr::BoolOp { left, op, right } => match op {
            BoolLogic::And => {
                let lv = eval_expr(left, row, aliases);
                if !is_truthy(&lv) {
                    return lv; // short-circuit: false/null
                }
                eval_expr(right, row, aliases)
            }
            BoolLogic::Or => {
                let lv = eval_expr(left, row, aliases);
                if is_truthy(&lv) {
                    return lv; // short-circuit: truthy
                }
                eval_expr(right, row, aliases)
            }
        },

        Expr::Not(inner) => {
            let v = eval_expr(inner, row, aliases);
            match v {
                QuineValue::Null => QuineValue::Null,
                QuineValue::True => QuineValue::False,
                QuineValue::False => QuineValue::True,
                // Non-boolean values: negate truthiness
                _ => QuineValue::False,
            }
        }

        Expr::IsNull(inner) => {
            let v = eval_expr(inner, row, aliases);
            match v {
                QuineValue::Null => QuineValue::True,
                _ => QuineValue::False,
            }
        }

        // InList is unsupported in MVP — always returns Null.
        Expr::InList { .. } => QuineValue::Null,

        Expr::FnCall { name, args } => eval_fn_call(name, args, row, aliases),
    }
}

// ===== Comparison Evaluator =====

fn eval_comparison(left: &QuineValue, op: CompOp, right: &QuineValue) -> QuineValue {
    // Null propagation: any side Null → Null
    if matches!(left, QuineValue::Null) || matches!(right, QuineValue::Null) {
        return QuineValue::Null;
    }

    // Type-matching comparisons
    match (left, right) {
        (QuineValue::Integer(a), QuineValue::Integer(b)) => bool_to_qv(match op {
            CompOp::Eq => a == b,
            CompOp::Neq => a != b,
            CompOp::Lt => a < b,
            CompOp::Gt => a > b,
            CompOp::Lte => a <= b,
            CompOp::Gte => a >= b,
        }),
        (QuineValue::Str(a), QuineValue::Str(b)) => bool_to_qv(match op {
            CompOp::Eq => a == b,
            CompOp::Neq => a != b,
            CompOp::Lt => a < b,
            CompOp::Gt => a > b,
            CompOp::Lte => a <= b,
            CompOp::Gte => a >= b,
        }),
        (QuineValue::True | QuineValue::False, QuineValue::True | QuineValue::False) => {
            let a = matches!(left, QuineValue::True);
            let b = matches!(right, QuineValue::True);
            bool_to_qv(match op {
                CompOp::Eq => a == b,
                CompOp::Neq => a != b,
                // Booleans don't have meaningful ordering, but handle it
                CompOp::Lt => !a && b,
                CompOp::Gt => a && !b,
                CompOp::Lte => a == b || (!a && b),
                CompOp::Gte => a == b || (a && !b),
            })
        }
        // Type mismatch: only Neq returns true
        _ => bool_to_qv(matches!(op, CompOp::Neq)),
    }
}

fn bool_to_qv(b: bool) -> QuineValue {
    if b {
        QuineValue::True
    } else {
        QuineValue::False
    }
}

// ===== Function Call Evaluator =====

fn eval_fn_call(name: &str, args: &[Expr], row: &Row, aliases: &[String]) -> QuineValue {
    match name {
        "id" => {
            // id(alias) → returns the node's id_str
            if let Some(Expr::Variable(alias_name)) = args.first() {
                if let Some(idx) = alias_idx(alias_name, aliases) {
                    if let Some(Some(node)) = row.get(idx) {
                        return QuineValue::Str(node.id_str.clone());
                    }
                }
            }
            QuineValue::Null
        }
        _ => QuineValue::Null, // Unknown function
    }
}

// ===== Row Projection =====

/// Convert a QuineValue to a serde_json::Value.
pub fn quine_value_to_json(v: &QuineValue) -> serde_json::Value {
    match v {
        QuineValue::Str(s) => serde_json::Value::String(s.clone()),
        QuineValue::Integer(n) => serde_json::json!(n),
        QuineValue::True => serde_json::Value::Bool(true),
        QuineValue::False => serde_json::Value::Bool(false),
        QuineValue::Null => serde_json::Value::Null,
    }
}

/// Convert a NodeData to a JSON object: `{ "id": "...", "properties": {...}, "edges": [...] }`.
pub fn node_to_json(node: &NodeData) -> serde_json::Value {
    let mut props = serde_json::Map::new();
    for (k, v) in &node.properties {
        props.insert(k.clone(), quine_value_to_json(v));
    }

    let edges: Vec<serde_json::Value> = node
        .edges
        .iter()
        .map(|e| {
            let dir_str = match e.direction {
                Direction::Outgoing => "Outgoing",
                Direction::Incoming => "Incoming",
                Direction::Undirected => "Undirected",
            };
            let other_hex: String = e.other_id.iter().map(|b| format!("{:02x}", b)).collect();
            serde_json::json!({
                "edgeType": e.edge_type,
                "direction": dir_str,
                "other": other_hex,
            })
        })
        .collect();

    serde_json::json!({
        "id": node.id_str,
        "properties": props,
        "edges": edges,
    })
}

/// Project a row into a JSON object according to the projection items.
///
/// Each ProjectItem contributes key-value pairs to the output object.
pub fn project_row(
    items: &[ProjectItem],
    row: &Row,
    aliases: &[String],
) -> serde_json::Value {
    let mut result = serde_json::Map::new();

    for item in items {
        match item {
            ProjectItem::WholeNode(alias_idx) => {
                let alias_name = aliases
                    .get(*alias_idx)
                    .cloned()
                    .unwrap_or_else(|| format!("_{}", alias_idx));
                if let Some(Some(node)) = row.get(*alias_idx) {
                    result.insert(alias_name, node_to_json(node));
                } else {
                    result.insert(alias_name, serde_json::Value::Null);
                }
            }
            ProjectItem::NodeProperty {
                alias_idx: idx,
                prop,
                output_name,
            } => {
                if let Some(Some(node)) = row.get(*idx) {
                    let val = node
                        .properties
                        .get(prop)
                        .map(quine_value_to_json)
                        .unwrap_or(serde_json::Value::Null);
                    result.insert(output_name.clone(), val);
                } else {
                    result.insert(output_name.clone(), serde_json::Value::Null);
                }
            }
        }
    }

    serde_json::Value::Object(result)
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quine_id::quine_id_from_str;

    /// Build a test NodeData with the given id string and properties.
    fn make_node(id_str: &str, props: Vec<(&str, QuineValue)>) -> NodeData {
        let id = quine_id_from_str(id_str);
        let properties: HashMap<String, QuineValue> =
            props.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        NodeData {
            id,
            id_str: id_str.to_string(),
            properties,
            edges: vec![],
        }
    }

    /// Build a single-alias row with one bound node.
    fn single_row(node: NodeData) -> (Row, Vec<String>) {
        let aliases = vec!["n".to_string()];
        let row = vec![Some(node)];
        (row, aliases)
    }

    // ===== Task 1: Literals, Variables, Properties =====

    #[test]
    fn eval_literal_string() {
        let expr = Expr::Literal(QuineValue::Str("hello".into()));
        let result = eval_expr(&expr, &vec![], &[]);
        assert_eq!(result, QuineValue::Str("hello".into()));
    }

    #[test]
    fn eval_literal_integer() {
        let expr = Expr::Literal(QuineValue::Integer(42));
        let result = eval_expr(&expr, &vec![], &[]);
        assert_eq!(result, QuineValue::Integer(42));
    }

    #[test]
    fn eval_literal_true() {
        let expr = Expr::Literal(QuineValue::True);
        let result = eval_expr(&expr, &vec![], &[]);
        assert_eq!(result, QuineValue::True);
    }

    #[test]
    fn eval_literal_null() {
        let expr = Expr::Literal(QuineValue::Null);
        let result = eval_expr(&expr, &vec![], &[]);
        assert_eq!(result, QuineValue::Null);
    }

    #[test]
    fn eval_property_access() {
        let node = make_node("alice", vec![("name", QuineValue::Str("Alice".into()))]);
        let (row, aliases) = single_row(node);
        let expr = Expr::Property {
            expr: Box::new(Expr::Variable("n".into())),
            key: "name".into(),
        };
        let result = eval_expr(&expr, &row, &aliases);
        assert_eq!(result, QuineValue::Str("Alice".into()));
    }

    #[test]
    fn eval_property_missing_returns_null() {
        let node = make_node("alice", vec![]);
        let (row, aliases) = single_row(node);
        let expr = Expr::Property {
            expr: Box::new(Expr::Variable("n".into())),
            key: "nonexistent".into(),
        };
        let result = eval_expr(&expr, &row, &aliases);
        assert_eq!(result, QuineValue::Null);
    }

    #[test]
    fn eval_variable_unbound_returns_null() {
        // Standalone variable access returns Null
        let expr = Expr::Variable("n".into());
        let result = eval_expr(&expr, &vec![], &[]);
        assert_eq!(result, QuineValue::Null);
    }

    #[test]
    fn eval_unknown_variable_returns_null() {
        // Variable not in aliases returns Null even with a row
        let node = make_node("alice", vec![]);
        let (row, aliases) = single_row(node);
        let expr = Expr::Property {
            expr: Box::new(Expr::Variable("unknown".into())),
            key: "name".into(),
        };
        let result = eval_expr(&expr, &row, &aliases);
        assert_eq!(result, QuineValue::Null);
    }

    // ===== Task 2: Comparisons, Boolean Logic, Not, IsNull, FnCall =====

    #[test]
    fn eval_eq_integers() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(5))),
            op: CompOp::Eq,
            right: Box::new(Expr::Literal(QuineValue::Integer(5))),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_neq_integers() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(5))),
            op: CompOp::Neq,
            right: Box::new(Expr::Literal(QuineValue::Integer(3))),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_lt_integers() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(3))),
            op: CompOp::Lt,
            right: Box::new(Expr::Literal(QuineValue::Integer(5))),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_eq_strings() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Str("hello".into()))),
            op: CompOp::Eq,
            right: Box::new(Expr::Literal(QuineValue::Str("hello".into()))),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_null_propagation() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Null)),
            op: CompOp::Eq,
            right: Box::new(Expr::Literal(QuineValue::Integer(5))),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::Null);
    }

    #[test]
    fn eval_type_mismatch_eq_is_false() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(5))),
            op: CompOp::Eq,
            right: Box::new(Expr::Literal(QuineValue::Str("5".into()))),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::False);
    }

    #[test]
    fn eval_and_true_true() {
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::True)),
            op: BoolLogic::And,
            right: Box::new(Expr::Literal(QuineValue::True)),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_and_true_false() {
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::True)),
            op: BoolLogic::And,
            right: Box::new(Expr::Literal(QuineValue::False)),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::False);
    }

    #[test]
    fn eval_and_short_circuit() {
        // AND with false on left should not evaluate right
        // We can't directly test side effects, but we verify the result
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::False)),
            op: BoolLogic::And,
            right: Box::new(Expr::Literal(QuineValue::True)),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::False);
    }

    #[test]
    fn eval_or_false_true() {
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::False)),
            op: BoolLogic::Or,
            right: Box::new(Expr::Literal(QuineValue::True)),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_or_short_circuit() {
        // OR with true on left should short-circuit
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::True)),
            op: BoolLogic::Or,
            right: Box::new(Expr::Literal(QuineValue::False)),
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_not_true() {
        let expr = Expr::Not(Box::new(Expr::Literal(QuineValue::True)));
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::False);
    }

    #[test]
    fn eval_not_false() {
        let expr = Expr::Not(Box::new(Expr::Literal(QuineValue::False)));
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_not_null() {
        let expr = Expr::Not(Box::new(Expr::Literal(QuineValue::Null)));
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::Null);
    }

    #[test]
    fn eval_is_null_null() {
        let expr = Expr::IsNull(Box::new(Expr::Literal(QuineValue::Null)));
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::True);
    }

    #[test]
    fn eval_is_null_integer() {
        let expr = Expr::IsNull(Box::new(Expr::Literal(QuineValue::Integer(42))));
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::False);
    }

    #[test]
    fn eval_fn_id() {
        let node = make_node("alice", vec![]);
        let (row, aliases) = single_row(node);
        let expr = Expr::FnCall {
            name: "id".into(),
            args: vec![Expr::Variable("n".into())],
        };
        let result = eval_expr(&expr, &row, &aliases);
        assert_eq!(result, QuineValue::Str("alice".into()));
    }

    #[test]
    fn eval_fn_unknown_returns_null() {
        let expr = Expr::FnCall {
            name: "unknown_fn".into(),
            args: vec![],
        };
        assert_eq!(eval_expr(&expr, &vec![], &[]), QuineValue::Null);
    }

    #[test]
    fn eval_combined_filter() {
        // n.age > 21 AND n.name = "Alice"
        let node = make_node(
            "alice",
            vec![
                ("age", QuineValue::Integer(25)),
                ("name", QuineValue::Str("Alice".into())),
            ],
        );
        let (row, aliases) = single_row(node);
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Comparison {
                left: Box::new(Expr::Property {
                    expr: Box::new(Expr::Variable("n".into())),
                    key: "age".into(),
                }),
                op: CompOp::Gt,
                right: Box::new(Expr::Literal(QuineValue::Integer(21))),
            }),
            op: BoolLogic::And,
            right: Box::new(Expr::Comparison {
                left: Box::new(Expr::Property {
                    expr: Box::new(Expr::Variable("n".into())),
                    key: "name".into(),
                }),
                op: CompOp::Eq,
                right: Box::new(Expr::Literal(QuineValue::Str("Alice".into()))),
            }),
        };
        assert_eq!(eval_expr(&expr, &row, &aliases), QuineValue::True);
    }

    // ===== Task 3: project_row =====

    #[test]
    fn project_whole_node() {
        let node = make_node("alice", vec![("name", QuineValue::Str("Alice".into()))]);
        let (row, aliases) = single_row(node);
        let items = vec![ProjectItem::WholeNode(0)];
        let result = project_row(&items, &row, &aliases);

        let obj = result.as_object().unwrap();
        let n_val = obj.get("n").unwrap();
        assert_eq!(n_val["id"], "alice");
        assert_eq!(n_val["properties"]["name"], "Alice");
        assert!(n_val["edges"].as_array().unwrap().is_empty());
    }

    #[test]
    fn project_node_property() {
        let node = make_node("alice", vec![("name", QuineValue::Str("Alice".into()))]);
        let (row, aliases) = single_row(node);
        let items = vec![ProjectItem::NodeProperty {
            alias_idx: 0,
            prop: "name".into(),
            output_name: "full_name".into(),
        }];
        let result = project_row(&items, &row, &aliases);
        assert_eq!(result["full_name"], "Alice");
    }

    #[test]
    fn project_missing_property_returns_null() {
        let node = make_node("alice", vec![]);
        let (row, aliases) = single_row(node);
        let items = vec![ProjectItem::NodeProperty {
            alias_idx: 0,
            prop: "missing".into(),
            output_name: "val".into(),
        }];
        let result = project_row(&items, &row, &aliases);
        assert!(result["val"].is_null());
    }
}
