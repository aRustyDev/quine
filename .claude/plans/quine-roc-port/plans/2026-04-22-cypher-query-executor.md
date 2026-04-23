# C1.3 Cypher Query Executor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Rust-side Cypher query executor that walks a QueryPlan, issues shard requests in parallel, evaluates filter expressions locally, and projects results as JSON.

**Architecture:** PlanQuery is sent as a shard command (TAG_SHARD_CMD, sub-tag 0x04) to shard 0. Roc parses the Cypher text, runs the planner, encodes the QueryPlan, and replies via roc_fx_reply. The Rust executor decodes the plan and walks steps sequentially: ScanSeeds fans out GetNodeState requests, Traverse follows edges, Filter evaluates expressions in Rust, Project extracts JSON output.

**Tech Stack:** Rust (tokio oneshot channels for request-response), Roc (Lexer/Parser/Planner/PlanCodec for planning)

**Spec:** `.claude/plans/quine-roc-port/refs/specs/cypher-query-executor-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `platform/src/cypher/executor.rs` | Create | Query execution: fan_out_get_nodes, step walking, result assembly |
| `platform/src/cypher/eval.rs` | Create | Expression evaluator: eval_expr, comparison, boolean logic |
| `platform/src/cypher/mod.rs` | Modify | Add `pub mod executor;` and `pub mod eval;` |
| `platform/src/api/query.rs` | Create | POST /api/v1/query endpoint (C1.4 scope, but PlanQuery encoding lives here) |
| `app/graph-app.roc` | Modify | Handle PlanQuery shard command (tag 0x04) |
| `packages/graph/codec/Codec.roc` | Modify | Decode PlanQuery in decode_shard_cmd |

Note: Task 7 (Roc PlanQuery handler) and Task 8 (query endpoint) are split from the core executor to keep task scope manageable. The executor (Tasks 1-6) is independently testable with pre-decoded plans.

---

### Task 1: eval_expr — Literals, Variables, Properties

**Files:**
- Create: `platform/src/cypher/eval.rs`
- Modify: `platform/src/cypher/mod.rs`

- [ ] **Step 1: Write failing tests for literal evaluation**

```rust
// platform/src/cypher/eval.rs

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cypher::expr::{Expr, QuineValue, CompOp, BoolLogic};

    fn empty_row(alias_count: usize) -> Row {
        vec![None; alias_count]
    }

    fn sample_node(id_str: &str, props: Vec<(&str, QuineValue)>) -> NodeData {
        let id = crate::quine_id::quine_id_from_str(id_str);
        let mut properties = std::collections::HashMap::new();
        for (k, v) in props {
            properties.insert(k.to_string(), v);
        }
        NodeData {
            id,
            id_str: id_str.to_string(),
            properties,
            edges: vec![],
        }
    }

    #[test]
    fn eval_literal_string() {
        let expr = Expr::Literal(QuineValue::Str("hello".into()));
        let row = empty_row(0);
        assert_eq!(eval_expr(&expr, &row, &[]), QuineValue::Str("hello".into()));
    }

    #[test]
    fn eval_literal_integer() {
        let expr = Expr::Literal(QuineValue::Integer(42));
        let row = empty_row(0);
        assert_eq!(eval_expr(&expr, &row, &[]), QuineValue::Integer(42));
    }

    #[test]
    fn eval_literal_true() {
        let expr = Expr::Literal(QuineValue::True);
        let row = empty_row(0);
        assert_eq!(eval_expr(&expr, &row, &[]), QuineValue::True);
    }

    #[test]
    fn eval_literal_null() {
        let expr = Expr::Literal(QuineValue::Null);
        let row = empty_row(0);
        assert_eq!(eval_expr(&expr, &row, &[]), QuineValue::Null);
    }

    #[test]
    fn eval_property_access() {
        let aliases = vec!["n".to_string()];
        let mut row = empty_row(1);
        row[0] = Some(sample_node("alice", vec![("name", QuineValue::Str("Alice".into()))]));

        let expr = Expr::Property {
            expr: Box::new(Expr::Variable("n".into())),
            key: "name".into(),
        };
        assert_eq!(eval_expr(&expr, &row, &aliases), QuineValue::Str("Alice".into()));
    }

    #[test]
    fn eval_property_missing_returns_null() {
        let aliases = vec!["n".to_string()];
        let mut row = empty_row(1);
        row[0] = Some(sample_node("alice", vec![]));

        let expr = Expr::Property {
            expr: Box::new(Expr::Variable("n".into())),
            key: "missing".into(),
        };
        assert_eq!(eval_expr(&expr, &row, &aliases), QuineValue::Null);
    }

    #[test]
    fn eval_variable_unbound_returns_null() {
        let aliases = vec!["n".to_string()];
        let row = empty_row(1); // n is None

        let expr = Expr::Property {
            expr: Box::new(Expr::Variable("n".into())),
            key: "name".into(),
        };
        assert_eq!(eval_expr(&expr, &row, &aliases), QuineValue::Null);
    }

    #[test]
    fn eval_unknown_variable_returns_null() {
        let aliases = vec!["n".to_string()];
        let row = empty_row(1);

        let expr = Expr::Property {
            expr: Box::new(Expr::Variable("x".into())),
            key: "name".into(),
        };
        assert_eq!(eval_expr(&expr, &row, &aliases), QuineValue::Null);
    }
}
```

- [ ] **Step 2: Add module to mod.rs**

```rust
// platform/src/cypher/mod.rs
pub mod eval;
pub mod executor;
pub mod expr;
pub mod plan;
```

- [ ] **Step 3: Implement eval_expr core**

```rust
// platform/src/cypher/eval.rs

use std::collections::HashMap;

use super::expr::{BoolLogic, CompOp, Expr, QuineValue};
use super::plan::Direction;

/// Data about a single node, fetched via GetNodeState.
#[derive(Debug, Clone)]
pub struct NodeData {
    pub id: [u8; 16],
    pub id_str: String,
    pub properties: HashMap<String, QuineValue>,
    pub edges: Vec<HalfEdge>,
}

#[derive(Debug, Clone)]
pub struct HalfEdge {
    pub edge_type: String,
    pub direction: Direction,
    pub other_id: [u8; 16],
}

/// One result row: indexed by alias_idx from plan.aliases.
pub type Row = Vec<Option<NodeData>>;

/// Find the alias index for a given name.
fn alias_idx(name: &str, aliases: &[String]) -> Option<usize> {
    aliases.iter().position(|a| a == name)
}

/// Evaluate an Expr against a row's bindings. Returns a QuineValue.
pub fn eval_expr(expr: &Expr, row: &Row, aliases: &[String]) -> QuineValue {
    match expr {
        Expr::Literal(v) => v.clone(),

        Expr::Variable(_name) => {
            // Standalone variable — only meaningful as base of Property.
            // Returning Null here; Property handles the actual lookup.
            QuineValue::Null
        }

        Expr::Property { expr: base, key } => {
            if let Expr::Variable(name) = base.as_ref() {
                match alias_idx(name, aliases) {
                    Some(idx) => match row.get(idx).and_then(|slot| slot.as_ref()) {
                        Some(node) => node
                            .properties
                            .get(key.as_str())
                            .cloned()
                            .unwrap_or(QuineValue::Null),
                        None => QuineValue::Null,
                    },
                    None => QuineValue::Null,
                }
            } else {
                // Nested property access not supported in MVP
                QuineValue::Null
            }
        }

        Expr::Comparison { left, op, right } => {
            let lhs = eval_expr(left, row, aliases);
            let rhs = eval_expr(right, row, aliases);
            eval_comparison(&lhs, *op, &rhs)
        }

        Expr::BoolOp { left, op, right } => {
            let lhs = eval_expr(left, row, aliases);
            match op {
                BoolLogic::And => {
                    if !is_truthy(&lhs) {
                        return lhs;
                    }
                    eval_expr(right, row, aliases)
                }
                BoolLogic::Or => {
                    if is_truthy(&lhs) {
                        return lhs;
                    }
                    eval_expr(right, row, aliases)
                }
            }
        }

        Expr::Not(inner) => {
            let val = eval_expr(inner, row, aliases);
            match val {
                QuineValue::True => QuineValue::False,
                QuineValue::False => QuineValue::True,
                QuineValue::Null => QuineValue::Null,
                _ => QuineValue::False, // truthy non-booleans negate to false
            }
        }

        Expr::IsNull(inner) => {
            let val = eval_expr(inner, row, aliases);
            match val {
                QuineValue::Null => QuineValue::True,
                _ => QuineValue::False,
            }
        }

        Expr::InList { .. } => QuineValue::Null, // not supported in MVP

        Expr::FnCall { name, args } => eval_fn_call(name, args, row, aliases),
    }
}

/// Truthy: True and non-null/non-false values are truthy.
pub fn is_truthy(v: &QuineValue) -> bool {
    match v {
        QuineValue::True => true,
        QuineValue::False | QuineValue::Null => false,
        _ => true, // strings, integers are truthy
    }
}

fn eval_comparison(lhs: &QuineValue, op: CompOp, rhs: &QuineValue) -> QuineValue {
    // Null propagation: any comparison with Null returns Null
    if matches!(lhs, QuineValue::Null) || matches!(rhs, QuineValue::Null) {
        return QuineValue::Null;
    }

    let result = match (lhs, rhs) {
        (QuineValue::Integer(a), QuineValue::Integer(b)) => match op {
            CompOp::Eq => a == b,
            CompOp::Neq => a != b,
            CompOp::Lt => a < b,
            CompOp::Gt => a > b,
            CompOp::Lte => a <= b,
            CompOp::Gte => a >= b,
        },
        (QuineValue::Str(a), QuineValue::Str(b)) => match op {
            CompOp::Eq => a == b,
            CompOp::Neq => a != b,
            CompOp::Lt => a < b,
            CompOp::Gt => a > b,
            CompOp::Lte => a <= b,
            CompOp::Gte => a >= b,
        },
        (QuineValue::True, QuineValue::True) | (QuineValue::False, QuineValue::False) => {
            matches!(op, CompOp::Eq | CompOp::Lte | CompOp::Gte)
        }
        (QuineValue::True, QuineValue::False) | (QuineValue::False, QuineValue::True) => {
            matches!(op, CompOp::Neq)
        }
        // Type mismatch: only Eq/Neq are defined, rest is false
        _ => matches!(op, CompOp::Neq),
    };

    if result {
        QuineValue::True
    } else {
        QuineValue::False
    }
}

fn eval_fn_call(name: &str, args: &[Expr], row: &Row, aliases: &[String]) -> QuineValue {
    match name {
        "id" => {
            if let Some(Expr::Variable(alias)) = args.first() {
                match alias_idx(alias, aliases) {
                    Some(idx) => match row.get(idx).and_then(|s| s.as_ref()) {
                        Some(node) => QuineValue::Str(node.id_str.clone()),
                        None => QuineValue::Null,
                    },
                    None => QuineValue::Null,
                }
            } else {
                QuineValue::Null
            }
        }
        _ => QuineValue::Null, // unknown function
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test cypher::eval --  --nocapture`
Expected: all 7 tests pass

- [ ] **Step 5: Commit**

```bash
git add platform/src/cypher/eval.rs platform/src/cypher/mod.rs
git commit -m "C1.3: eval_expr — literals, properties, variables"
```

---

### Task 2: eval_expr — Comparisons, Boolean Logic, Not, IsNull, FnCall

**Files:**
- Modify: `platform/src/cypher/eval.rs` (add tests only — implementation is already in Task 1)

- [ ] **Step 1: Write tests for comparisons and boolean logic**

Add to the `tests` module in `eval.rs`:

```rust
    // ---- Comparison tests ----

    #[test]
    fn eval_eq_integers() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(5))),
            op: CompOp::Eq,
            right: Box::new(Expr::Literal(QuineValue::Integer(5))),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    #[test]
    fn eval_neq_integers() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(5))),
            op: CompOp::Neq,
            right: Box::new(Expr::Literal(QuineValue::Integer(3))),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    #[test]
    fn eval_lt_integers() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(3))),
            op: CompOp::Lt,
            right: Box::new(Expr::Literal(QuineValue::Integer(5))),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    #[test]
    fn eval_eq_strings() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Str("a".into()))),
            op: CompOp::Eq,
            right: Box::new(Expr::Literal(QuineValue::Str("a".into()))),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    #[test]
    fn eval_null_propagation() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(5))),
            op: CompOp::Eq,
            right: Box::new(Expr::Literal(QuineValue::Null)),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::Null);
    }

    #[test]
    fn eval_type_mismatch_eq_is_false() {
        let expr = Expr::Comparison {
            left: Box::new(Expr::Literal(QuineValue::Integer(5))),
            op: CompOp::Eq,
            right: Box::new(Expr::Literal(QuineValue::Str("5".into()))),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::False);
    }

    // ---- Boolean logic tests ----

    #[test]
    fn eval_and_true_true() {
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::True)),
            op: BoolLogic::And,
            right: Box::new(Expr::Literal(QuineValue::True)),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    #[test]
    fn eval_and_true_false() {
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::True)),
            op: BoolLogic::And,
            right: Box::new(Expr::Literal(QuineValue::False)),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::False);
    }

    #[test]
    fn eval_and_short_circuit() {
        // false AND anything → false (short-circuit)
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::False)),
            op: BoolLogic::And,
            right: Box::new(Expr::Literal(QuineValue::True)),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::False);
    }

    #[test]
    fn eval_or_false_true() {
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::False)),
            op: BoolLogic::Or,
            right: Box::new(Expr::Literal(QuineValue::True)),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    #[test]
    fn eval_or_short_circuit() {
        let expr = Expr::BoolOp {
            left: Box::new(Expr::Literal(QuineValue::True)),
            op: BoolLogic::Or,
            right: Box::new(Expr::Literal(QuineValue::False)),
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    // ---- Not ----

    #[test]
    fn eval_not_true() {
        let expr = Expr::Not(Box::new(Expr::Literal(QuineValue::True)));
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::False);
    }

    #[test]
    fn eval_not_false() {
        let expr = Expr::Not(Box::new(Expr::Literal(QuineValue::False)));
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    #[test]
    fn eval_not_null() {
        let expr = Expr::Not(Box::new(Expr::Literal(QuineValue::Null)));
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::Null);
    }

    // ---- IsNull ----

    #[test]
    fn eval_is_null_null() {
        let expr = Expr::IsNull(Box::new(Expr::Literal(QuineValue::Null)));
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::True);
    }

    #[test]
    fn eval_is_null_integer() {
        let expr = Expr::IsNull(Box::new(Expr::Literal(QuineValue::Integer(5))));
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::False);
    }

    // ---- FnCall: id() ----

    #[test]
    fn eval_fn_id() {
        let aliases = vec!["n".to_string()];
        let mut row = empty_row(1);
        row[0] = Some(sample_node("alice", vec![]));

        let expr = Expr::FnCall {
            name: "id".into(),
            args: vec![Expr::Variable("n".into())],
        };
        assert_eq!(eval_expr(&expr, &row, &aliases), QuineValue::Str("alice".into()));
    }

    #[test]
    fn eval_fn_unknown_returns_null() {
        let expr = Expr::FnCall {
            name: "bogus".into(),
            args: vec![],
        };
        assert_eq!(eval_expr(&expr, &empty_row(0), &[]), QuineValue::Null);
    }

    // ---- Combined: WHERE n.age > 20 AND n.name = "Alice" ----

    #[test]
    fn eval_combined_filter() {
        let aliases = vec!["n".to_string()];
        let mut row = empty_row(1);
        row[0] = Some(sample_node("alice", vec![
            ("age", QuineValue::Integer(30)),
            ("name", QuineValue::Str("Alice".into())),
        ]));

        let expr = Expr::BoolOp {
            left: Box::new(Expr::Comparison {
                left: Box::new(Expr::Property {
                    expr: Box::new(Expr::Variable("n".into())),
                    key: "age".into(),
                }),
                op: CompOp::Gt,
                right: Box::new(Expr::Literal(QuineValue::Integer(20))),
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
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `cargo test cypher::eval --  --nocapture`
Expected: all 22 tests pass

- [ ] **Step 3: Commit**

```bash
git add platform/src/cypher/eval.rs
git commit -m "C1.3: eval_expr tests — comparisons, boolean logic, not, is_null, fn_call"
```

---

### Task 3: project_row

**Files:**
- Modify: `platform/src/cypher/eval.rs`

- [ ] **Step 1: Write failing tests for project_row**

Add to `eval.rs` tests module:

```rust
    // ---- project_row tests ----

    use crate::cypher::plan::ProjectItem;

    #[test]
    fn project_whole_node() {
        let aliases = vec!["n".to_string()];
        let mut row = empty_row(1);
        row[0] = Some(sample_node("alice", vec![
            ("name", QuineValue::Str("Alice".into())),
        ]));

        let items = vec![ProjectItem::WholeNode(0)];
        let result = project_row(&items, &row, &aliases);
        assert_eq!(result["n"]["id"], "alice");
        assert_eq!(result["n"]["properties"]["name"], "Alice");
    }

    #[test]
    fn project_node_property() {
        let aliases = vec!["n".to_string()];
        let mut row = empty_row(1);
        row[0] = Some(sample_node("alice", vec![
            ("name", QuineValue::Str("Alice".into())),
            ("age", QuineValue::Integer(30)),
        ]));

        let items = vec![
            ProjectItem::NodeProperty {
                alias_idx: 0,
                prop: "name".into(),
                output_name: "n.name".into(),
            },
            ProjectItem::NodeProperty {
                alias_idx: 0,
                prop: "age".into(),
                output_name: "n.age".into(),
            },
        ];
        let result = project_row(&items, &row, &aliases);
        assert_eq!(result["n.name"], "Alice");
        assert_eq!(result["n.age"], 30);
    }

    #[test]
    fn project_missing_property_returns_null() {
        let aliases = vec!["n".to_string()];
        let mut row = empty_row(1);
        row[0] = Some(sample_node("alice", vec![]));

        let items = vec![ProjectItem::NodeProperty {
            alias_idx: 0,
            prop: "missing".into(),
            output_name: "n.missing".into(),
        }];
        let result = project_row(&items, &row, &aliases);
        assert!(result["n.missing"].is_null());
    }
```

- [ ] **Step 2: Implement project_row**

Add to `eval.rs` (after `eval_fn_call`):

```rust
/// Project a single result row into a JSON object.
pub fn project_row(
    items: &[crate::cypher::plan::ProjectItem],
    row: &Row,
    aliases: &[String],
) -> serde_json::Value {
    let mut obj = serde_json::Map::new();

    for item in items {
        match item {
            crate::cypher::plan::ProjectItem::WholeNode(alias_idx) => {
                let alias = &aliases[*alias_idx];
                let val = match row.get(*alias_idx).and_then(|s| s.as_ref()) {
                    Some(node) => node_to_json(node),
                    None => serde_json::Value::Null,
                };
                obj.insert(alias.clone(), val);
            }
            crate::cypher::plan::ProjectItem::NodeProperty {
                alias_idx,
                prop,
                output_name,
            } => {
                let val = match row.get(*alias_idx).and_then(|s| s.as_ref()) {
                    Some(node) => match node.properties.get(prop.as_str()) {
                        Some(qv) => quine_value_to_json(qv),
                        None => serde_json::Value::Null,
                    },
                    None => serde_json::Value::Null,
                };
                obj.insert(output_name.clone(), val);
            }
        }
    }

    serde_json::Value::Object(obj)
}

fn node_to_json(node: &NodeData) -> serde_json::Value {
    let mut props = serde_json::Map::new();
    for (k, v) in &node.properties {
        props.insert(k.clone(), quine_value_to_json(v));
    }

    let edges: Vec<serde_json::Value> = node
        .edges
        .iter()
        .map(|e| {
            let dir = match e.direction {
                Direction::Outgoing => "outgoing",
                Direction::Incoming => "incoming",
                Direction::Undirected => "undirected",
            };
            let other_hex: String = e.other_id.iter().map(|b| format!("{:02x}", b)).collect();
            serde_json::json!({
                "type": e.edge_type,
                "direction": dir,
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

fn quine_value_to_json(v: &QuineValue) -> serde_json::Value {
    match v {
        QuineValue::Str(s) => serde_json::Value::String(s.clone()),
        QuineValue::Integer(n) => serde_json::json!(n),
        QuineValue::True => serde_json::Value::Bool(true),
        QuineValue::False => serde_json::Value::Bool(false),
        QuineValue::Null => serde_json::Value::Null,
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cargo test cypher::eval --  --nocapture`
Expected: all 25 tests pass

- [ ] **Step 4: Commit**

```bash
git add platform/src/cypher/eval.rs
git commit -m "C1.3: project_row — WholeNode and NodeProperty projection"
```

---

### Task 4: fan_out_get_nodes

**Files:**
- Create: `platform/src/cypher/executor.rs`

- [ ] **Step 1: Write the executor module with fan_out_get_nodes and decode_node_data**

```rust
// platform/src/cypher/executor.rs
//
// Cypher query executor: walks a QueryPlan, issues shard requests in
// parallel, evaluates filters locally, projects results as JSON.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};

use super::eval::{self, HalfEdge, NodeData, Row};
use super::expr::{self, QuineValue};
use super::plan::{Direction, PlanStep, ProjectItem, QueryPlan};
use crate::api::PendingRequests;
use crate::channels::{ChannelRegistry, TAG_SHARD_MSG};
use crate::quine_id;

// ===== Error Type =====

#[derive(Debug)]
pub enum ExecuteError {
    PlanDecode(String),
    ShardTimeout,
    ShardUnavailable,
    EvalError(String),
    PlanError(String),
}

impl std::fmt::Display for ExecuteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExecuteError::PlanDecode(s) => write!(f, "plan decode error: {}", s),
            ExecuteError::ShardTimeout => write!(f, "shard request timed out"),
            ExecuteError::ShardUnavailable => write!(f, "shard channel full"),
            ExecuteError::EvalError(s) => write!(f, "expression eval error: {}", s),
            ExecuteError::PlanError(s) => write!(f, "plan error: {}", s),
        }
    }
}

// ===== Request ID =====

/// Shared request ID counter (separate from nodes.rs to avoid collisions).
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1_000_000);

fn next_request_id() -> u64 {
    NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
}

// ===== Node State Request =====

const TAG_GET_NODE_STATE: u8 = 0x01;

fn encode_get_node_state(qid: &[u8; 16], request_id: u64) -> Vec<u8> {
    let mut buf = Vec::with_capacity(28);
    buf.push(TAG_SHARD_MSG);
    buf.extend_from_slice(&(qid.len() as u16).to_le_bytes());
    buf.extend_from_slice(qid);
    buf.push(TAG_GET_NODE_STATE);
    buf.extend_from_slice(&request_id.to_le_bytes());
    buf
}

// ===== Fan-out =====

/// Fetch node data for multiple nodes in parallel.
///
/// Sends GetNodeState to each target's shard, awaits all replies with timeout.
/// Seam for batching: change internals to chunk `targets` without changing signature.
pub async fn fan_out_get_nodes(
    targets: &[([u8; 16], u32)], // (qid, shard_id)
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
) -> Vec<Result<NodeData, ExecuteError>> {
    if targets.is_empty() {
        return vec![];
    }

    // Register all oneshot channels and send messages
    let mut receivers = Vec::with_capacity(targets.len());
    for (qid, shard_id) in targets {
        let request_id = next_request_id();
        let (tx, rx) = tokio::sync::oneshot::channel::<Vec<u8>>();

        {
            let mut p = pending.lock().unwrap();
            p.insert(request_id, tx);
        }

        let msg = encode_get_node_state(qid, request_id);
        if !registry.try_send(*shard_id, msg) {
            // Clean up and record failure
            let mut p = pending.lock().unwrap();
            p.remove(&request_id);
            receivers.push((*qid, None, request_id));
            continue;
        }

        receivers.push((*qid, Some(rx), request_id));
    }

    // Await all replies with timeout
    let timeout = std::time::Duration::from_secs(5);
    let mut results = Vec::with_capacity(receivers.len());

    for (qid, rx_opt, request_id) in receivers {
        match rx_opt {
            None => results.push(Err(ExecuteError::ShardUnavailable)),
            Some(rx) => match tokio::time::timeout(timeout, rx).await {
                Ok(Ok(payload)) => {
                    results.push(decode_node_data(&qid, &payload));
                }
                Ok(Err(_)) => results.push(Err(ExecuteError::ShardTimeout)),
                Err(_) => {
                    let mut p = pending.lock().unwrap();
                    p.remove(&request_id);
                    results.push(Err(ExecuteError::ShardTimeout));
                }
            },
        }
    }

    results
}

// ===== Node Reply Decoder =====

/// Decode a GetNodeState reply into NodeData.
///
/// Reply format (matches graph-app.roc encode_reply_payload NodeState):
///   [prop_count:U32LE]
///     [key_len:U16LE][key...][value_tag:U8][value_data...] * prop_count
///   [edge_count:U32LE]
///     [edge_type_len:U16LE][edge_type...][direction:U8][other_qid_len:U16LE][other_qid...] * edge_count
fn decode_node_data(qid: &[u8; 16], payload: &[u8]) -> Result<NodeData, ExecuteError> {
    let id_str = qid_to_string(qid);
    let mut offset = 0;
    let mut properties = HashMap::new();
    let mut edges = Vec::new();

    // Properties
    let prop_count = read_u32_le(payload, offset).ok_or(ExecuteError::PlanDecode(
        "truncated prop_count".into(),
    ))?;
    offset += 4;

    for _ in 0..prop_count {
        let (key, next) = read_string(payload, offset).ok_or(ExecuteError::PlanDecode(
            "truncated prop key".into(),
        ))?;
        offset = next;
        let (val, next) = decode_quine_value(payload, offset).ok_or(
            ExecuteError::PlanDecode("truncated prop value".into()),
        )?;
        offset = next;
        properties.insert(key, val);
    }

    // Edges
    let edge_count = read_u32_le(payload, offset).ok_or(ExecuteError::PlanDecode(
        "truncated edge_count".into(),
    ))?;
    offset += 4;

    for _ in 0..edge_count {
        let (edge_type, next) = read_string(payload, offset).ok_or(
            ExecuteError::PlanDecode("truncated edge type".into()),
        )?;
        offset = next;

        let dir_byte = payload
            .get(offset)
            .ok_or(ExecuteError::PlanDecode("truncated direction".into()))?;
        offset += 1;
        let direction = match dir_byte {
            0x01 => Direction::Outgoing,
            0x02 => Direction::Incoming,
            _ => Direction::Undirected,
        };

        let other_len = read_u16_le(payload, offset).ok_or(ExecuteError::PlanDecode(
            "truncated other qid len".into(),
        ))? as usize;
        offset += 2;
        if offset + other_len > payload.len() {
            return Err(ExecuteError::PlanDecode("truncated other qid".into()));
        }
        let mut other_id = [0u8; 16];
        let copy_len = other_len.min(16);
        other_id[..copy_len].copy_from_slice(&payload[offset..offset + copy_len]);
        offset += other_len;

        edges.push(HalfEdge {
            edge_type,
            direction,
            other_id,
        });
    }

    Ok(NodeData {
        id: *qid,
        id_str,
        properties,
        edges,
    })
}

// ===== Wire Format Helpers =====

fn read_u16_le(buf: &[u8], offset: usize) -> Option<u16> {
    if offset + 2 > buf.len() {
        return None;
    }
    Some(u16::from_le_bytes([buf[offset], buf[offset + 1]]))
}

fn read_u32_le(buf: &[u8], offset: usize) -> Option<u32> {
    if offset + 4 > buf.len() {
        return None;
    }
    Some(u32::from_le_bytes(
        buf[offset..offset + 4].try_into().ok()?,
    ))
}

fn read_u64_le(buf: &[u8], offset: usize) -> Option<u64> {
    if offset + 8 > buf.len() {
        return None;
    }
    Some(u64::from_le_bytes(
        buf[offset..offset + 8].try_into().ok()?,
    ))
}

fn read_string(buf: &[u8], offset: usize) -> Option<(String, usize)> {
    let len = read_u16_le(buf, offset)? as usize;
    let start = offset + 2;
    if start + len > buf.len() {
        return None;
    }
    let s = String::from_utf8(buf[start..start + len].to_vec()).ok()?;
    Some((s, start + len))
}

fn decode_quine_value(buf: &[u8], offset: usize) -> Option<(QuineValue, usize)> {
    let tag = *buf.get(offset)?;
    match tag {
        0x01 => {
            let (s, next) = read_string(buf, offset + 1)?;
            Some((QuineValue::Str(s), next))
        }
        0x02 => {
            let n = read_u64_le(buf, offset + 1)? as i64;
            Some((QuineValue::Integer(n), offset + 9))
        }
        0x04 => Some((QuineValue::True, offset + 1)),
        0x05 => Some((QuineValue::False, offset + 1)),
        0x06 => Some((QuineValue::Null, offset + 1)),
        _ => None,
    }
}

fn qid_to_string(qid: &[u8; 16]) -> String {
    // Find the trailing zeros to get just the meaningful bytes
    // For display, use hex encoding of the full 16 bytes
    qid.iter().map(|b| format!("{:02x}", b)).collect()
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_empty_node_reply() {
        let qid = [0u8; 16];
        let mut payload = Vec::new();
        payload.extend_from_slice(&0u32.to_le_bytes()); // prop_count = 0
        payload.extend_from_slice(&0u32.to_le_bytes()); // edge_count = 0

        let result = decode_node_data(&qid, &payload).unwrap();
        assert!(result.properties.is_empty());
        assert!(result.edges.is_empty());
    }

    #[test]
    fn decode_node_with_string_prop() {
        let qid = [0u8; 16];
        let mut payload = Vec::new();
        payload.extend_from_slice(&1u32.to_le_bytes()); // prop_count = 1
        // key: "name" (len=4)
        payload.extend_from_slice(&4u16.to_le_bytes());
        payload.extend_from_slice(b"name");
        // value: Str "Alice" (tag=0x01, len=5)
        payload.push(0x01);
        payload.extend_from_slice(&5u16.to_le_bytes());
        payload.extend_from_slice(b"Alice");
        // edges
        payload.extend_from_slice(&0u32.to_le_bytes());

        let result = decode_node_data(&qid, &payload).unwrap();
        assert_eq!(
            result.properties.get("name"),
            Some(&QuineValue::Str("Alice".into()))
        );
    }

    #[test]
    fn decode_node_with_edge() {
        let qid = [0u8; 16];
        let mut payload = Vec::new();
        payload.extend_from_slice(&0u32.to_le_bytes()); // prop_count = 0
        payload.extend_from_slice(&1u32.to_le_bytes()); // edge_count = 1
        // edge_type: "KNOWS" (len=5)
        payload.extend_from_slice(&5u16.to_le_bytes());
        payload.extend_from_slice(b"KNOWS");
        // direction: outgoing (0x01)
        payload.push(0x01);
        // other qid: 16 bytes
        let other = [0xABu8; 16];
        payload.extend_from_slice(&16u16.to_le_bytes());
        payload.extend_from_slice(&other);

        let result = decode_node_data(&qid, &payload).unwrap();
        assert_eq!(result.edges.len(), 1);
        assert_eq!(result.edges[0].edge_type, "KNOWS");
        assert!(matches!(result.edges[0].direction, Direction::Outgoing));
        assert_eq!(result.edges[0].other_id, other);
    }

    #[test]
    fn decode_truncated_payload_errors() {
        let qid = [0u8; 16];
        let payload = vec![0x01]; // too short for u32
        assert!(decode_node_data(&qid, &payload).is_err());
    }
}
```

- [ ] **Step 2: Run tests**

Run: `cargo test cypher::executor --  --nocapture`
Expected: 4 tests pass

- [ ] **Step 3: Commit**

```bash
git add platform/src/cypher/executor.rs
git commit -m "C1.3: fan_out_get_nodes and decode_node_data"
```

---

### Task 5: execute() — Plan Step Walker

**Files:**
- Modify: `platform/src/cypher/executor.rs`

- [ ] **Step 1: Implement execute() and step handlers**

Add to `executor.rs` after the `fan_out_get_nodes` function:

```rust
// ===== Plan Execution =====

/// Execute a decoded QueryPlan. Walks steps sequentially, threading rows.
pub async fn execute(
    plan: &QueryPlan,
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) -> Result<Vec<serde_json::Value>, ExecuteError> {
    let mut rows: Vec<Row> = Vec::new();
    let alias_count = plan.aliases.len();

    for step in &plan.steps {
        match step {
            PlanStep::ScanSeeds {
                alias_idx,
                label: _,
                inline_props,
                node_ids,
            } => {
                rows = exec_scan_seeds(
                    *alias_idx,
                    alias_count,
                    node_ids,
                    inline_props,
                    pending,
                    registry,
                    shard_count,
                )
                .await?;
            }

            PlanStep::Traverse {
                from_alias_idx,
                to_alias_idx,
                direction,
                edge_type,
                to_label: _,
            } => {
                rows = exec_traverse(
                    &rows,
                    *from_alias_idx,
                    *to_alias_idx,
                    alias_count,
                    *direction,
                    edge_type.as_deref(),
                    pending,
                    registry,
                    shard_count,
                )
                .await?;
            }

            PlanStep::Filter { expr_bytes } => {
                let (decoded_expr, _) = expr::decode_expr(expr_bytes, 0).map_err(|e| {
                    ExecuteError::EvalError(format!("filter decode: {}", e))
                })?;
                rows = exec_filter(&rows, &decoded_expr, &plan.aliases);
            }

            PlanStep::Project { items } => {
                return Ok(exec_project(&rows, items, &plan.aliases));
            }
        }
    }

    // No Project step — return empty rows as JSON (shouldn't normally happen)
    Ok(rows
        .iter()
        .map(|_| serde_json::json!({}))
        .collect())
}

async fn exec_scan_seeds(
    alias_idx: usize,
    alias_count: usize,
    node_ids: &[[u8; 16]],
    inline_props: &[(String, QuineValue)],
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) -> Result<Vec<Row>, ExecuteError> {
    let targets: Vec<([u8; 16], u32)> = node_ids
        .iter()
        .map(|qid| (*qid, quine_id::shard_for_node(qid, shard_count)))
        .collect();

    let results = fan_out_get_nodes(&targets, pending, registry).await;

    let mut rows = Vec::new();
    for result in results {
        let node = result?;

        // Filter by inline_props (WHERE {key: value} in MATCH pattern)
        if !inline_props.is_empty() {
            let matches = inline_props.iter().all(|(k, v)| {
                node.properties.get(k).map_or(false, |actual| actual == v)
            });
            if !matches {
                continue;
            }
        }

        let mut row = vec![None; alias_count];
        row[alias_idx] = Some(node);
        rows.push(row);
    }

    Ok(rows)
}

async fn exec_traverse(
    rows: &[Row],
    from_alias_idx: usize,
    to_alias_idx: usize,
    alias_count: usize,
    direction: Direction,
    edge_type: Option<&str>,
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) -> Result<Vec<Row>, ExecuteError> {
    // Collect target nodes from edges of "from" nodes
    let mut targets_with_row: Vec<(usize, [u8; 16])> = Vec::new(); // (row_index, to_qid)

    for (row_idx, row) in rows.iter().enumerate() {
        let from_node = match row.get(from_alias_idx).and_then(|s| s.as_ref()) {
            Some(n) => n,
            None => continue,
        };

        for edge in &from_node.edges {
            // Direction match
            let dir_matches = match direction {
                Direction::Outgoing => matches!(edge.direction, Direction::Outgoing),
                Direction::Incoming => matches!(edge.direction, Direction::Incoming),
                Direction::Undirected => true,
            };
            if !dir_matches {
                continue;
            }

            // Edge type match
            if let Some(et) = edge_type {
                if edge.edge_type != et {
                    continue;
                }
            }

            targets_with_row.push((row_idx, edge.other_id));
        }
    }

    // Deduplicate targets for fetching
    let mut unique_targets: Vec<([u8; 16], u32)> = Vec::new();
    let mut seen: HashMap<[u8; 16], usize> = HashMap::new();
    for (_, qid) in &targets_with_row {
        if !seen.contains_key(qid) {
            seen.insert(*qid, unique_targets.len());
            unique_targets.push((*qid, quine_id::shard_for_node(qid, shard_count)));
        }
    }

    let fetched = fan_out_get_nodes(&unique_targets, pending, registry).await;

    // Build a lookup from qid -> NodeData
    let mut node_map: HashMap<[u8; 16], NodeData> = HashMap::new();
    for (i, result) in fetched.into_iter().enumerate() {
        if let Ok(node) = result {
            node_map.insert(unique_targets[i].0, node);
        }
        // Silently skip failed fetches — the row just won't expand
    }

    // Expand rows
    let mut new_rows = Vec::new();
    for (row_idx, to_qid) in &targets_with_row {
        if let Some(to_node) = node_map.get(to_qid) {
            let mut new_row = rows[*row_idx].clone();
            // Extend row if needed
            while new_row.len() < alias_count {
                new_row.push(None);
            }
            new_row[to_alias_idx] = Some(to_node.clone());
            new_rows.push(new_row);
        }
    }

    Ok(new_rows)
}

fn exec_filter(rows: &[Row], predicate: &expr::Expr, aliases: &[String]) -> Vec<Row> {
    rows.iter()
        .filter(|row| eval::is_truthy(&eval::eval_expr(predicate, row, aliases)))
        .cloned()
        .collect()
}

fn exec_project(
    rows: &[Row],
    items: &[ProjectItem],
    aliases: &[String],
) -> Vec<serde_json::Value> {
    rows.iter()
        .map(|row| eval::project_row(items, row, aliases))
        .collect()
}
```

- [ ] **Step 2: Write test for execute with a synthetic plan (no shard interaction)**

Add to `executor.rs` tests module:

```rust
    #[test]
    fn exec_filter_keeps_matching_rows() {
        use crate::cypher::eval::{NodeData, HalfEdge};

        let aliases = vec!["n".to_string()];
        let node_alice = NodeData {
            id: [0; 16],
            id_str: "alice".into(),
            properties: {
                let mut m = HashMap::new();
                m.insert("age".into(), QuineValue::Integer(30));
                m
            },
            edges: vec![],
        };
        let node_bob = NodeData {
            id: [1; 16],
            id_str: "bob".into(),
            properties: {
                let mut m = HashMap::new();
                m.insert("age".into(), QuineValue::Integer(15));
                m
            },
            edges: vec![],
        };

        let rows = vec![
            vec![Some(node_alice)],
            vec![Some(node_bob)],
        ];

        // WHERE n.age > 20
        let predicate = expr::Expr::Comparison {
            left: Box::new(expr::Expr::Property {
                expr: Box::new(expr::Expr::Variable("n".into())),
                key: "age".into(),
            }),
            op: expr::CompOp::Gt,
            right: Box::new(expr::Expr::Literal(QuineValue::Integer(20))),
        };

        let filtered = exec_filter(&rows, &predicate, &aliases);
        assert_eq!(filtered.len(), 1);
        assert_eq!(
            filtered[0][0].as_ref().unwrap().id_str,
            "alice"
        );
    }

    #[test]
    fn exec_project_extracts_fields() {
        use crate::cypher::plan::ProjectItem;

        let aliases = vec!["n".to_string()];
        let node = NodeData {
            id: [0; 16],
            id_str: "alice".into(),
            properties: {
                let mut m = HashMap::new();
                m.insert("name".into(), QuineValue::Str("Alice".into()));
                m
            },
            edges: vec![],
        };
        let rows = vec![vec![Some(node)]];

        let items = vec![ProjectItem::NodeProperty {
            alias_idx: 0,
            prop: "name".into(),
            output_name: "n.name".into(),
        }];

        let results = exec_project(&rows, &items, &aliases);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["n.name"], "Alice");
    }
```

- [ ] **Step 3: Run tests**

Run: `cargo test cypher::executor --  --nocapture`
Expected: 6 tests pass

- [ ] **Step 4: Commit**

```bash
git add platform/src/cypher/executor.rs
git commit -m "C1.3: execute() — plan step walker with scan, traverse, filter, project"
```

---

### Task 6: PlanQuery Encoding (Rust Side)

**Files:**
- Modify: `platform/src/cypher/executor.rs`

- [ ] **Step 1: Add PlanQuery encoder and send_plan_query function**

Add to `executor.rs` after the `next_request_id` function:

```rust
// ===== PlanQuery Command =====

/// Shard command sub-tag for PlanQuery (matches Codec.decode_shard_cmd tag 0x04).
const CMD_PLAN_QUERY: u8 = 0x04;

/// Encode a PlanQuery shard command.
///
/// Wire format:
///   [TAG_SHARD_CMD (0x02)]
///   [CMD_PLAN_QUERY (0x04)]
///   [reply_to: U64LE]
///   [query_len: U16LE]
///   [query_utf8...]
///   [hint_count: U16LE]
///   [hint_qid: 16 bytes] * hint_count
fn encode_plan_query(query: &str, hint_qids: &[[u8; 16]], request_id: u64) -> Vec<u8> {
    let query_bytes = query.as_bytes();
    let size = 1 + 1 + 8 + 2 + query_bytes.len() + 2 + hint_qids.len() * 16;
    let mut buf = Vec::with_capacity(size);
    buf.push(crate::channels::TAG_SHARD_CMD);
    buf.push(CMD_PLAN_QUERY);
    buf.extend_from_slice(&request_id.to_le_bytes());
    buf.extend_from_slice(&(query_bytes.len() as u16).to_le_bytes());
    buf.extend_from_slice(query_bytes);
    buf.extend_from_slice(&(hint_qids.len() as u16).to_le_bytes());
    for qid in hint_qids {
        buf.extend_from_slice(qid);
    }
    buf
}

/// Send a Cypher query to shard 0 for planning. Returns the decoded QueryPlan.
///
/// Flow: encode PlanQuery → send to shard 0 → Roc parses/plans/encodes → reply via oneshot.
/// Error reply format: [0xFF][error_len:U16LE][error_utf8] (tag 0xFF distinguishes from valid plan).
pub async fn plan_query(
    query: &str,
    hint_qids: &[[u8; 16]],
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
) -> Result<QueryPlan, ExecuteError> {
    let request_id = next_request_id();
    let (tx, rx) = tokio::sync::oneshot::channel::<Vec<u8>>();

    {
        let mut p = pending.lock().unwrap();
        p.insert(request_id, tx);
    }

    let msg = encode_plan_query(query, hint_qids, request_id);
    if !registry.try_send(0, msg) {
        let mut p = pending.lock().unwrap();
        p.remove(&request_id);
        return Err(ExecuteError::ShardUnavailable);
    }

    // 10s timeout for planning (longer than node queries)
    let timeout = std::time::Duration::from_secs(10);
    match tokio::time::timeout(timeout, rx).await {
        Ok(Ok(payload)) => {
            // Check for error reply (tag 0xFF)
            if payload.first() == Some(&0xFF) {
                let error_msg = if payload.len() >= 3 {
                    let len = u16::from_le_bytes([payload[1], payload[2]]) as usize;
                    if payload.len() >= 3 + len {
                        String::from_utf8_lossy(&payload[3..3 + len]).into_owned()
                    } else {
                        "unknown planner error".into()
                    }
                } else {
                    "unknown planner error".into()
                };
                Err(ExecuteError::PlanError(error_msg))
            } else {
                super::plan::decode_plan(&payload)
                    .map_err(|e| ExecuteError::PlanDecode(e.to_string()))
            }
        }
        Ok(Err(_)) => Err(ExecuteError::ShardTimeout),
        Err(_) => {
            let mut p = pending.lock().unwrap();
            p.remove(&request_id);
            Err(ExecuteError::ShardTimeout)
        }
    }
}
```

- [ ] **Step 2: Write tests for encode_plan_query**

Add to tests module:

```rust
    #[test]
    fn encode_plan_query_wire_format() {
        let msg = encode_plan_query("MATCH (n) RETURN n", &[], 42);
        // byte 0: TAG_SHARD_CMD (0x02)
        assert_eq!(msg[0], 0x02);
        // byte 1: CMD_PLAN_QUERY (0x04)
        assert_eq!(msg[1], 0x04);
        // bytes 2-9: reply_to (42 as U64LE)
        assert_eq!(u64::from_le_bytes(msg[2..10].try_into().unwrap()), 42);
        // bytes 10-11: query_len
        let query_len = u16::from_le_bytes([msg[10], msg[11]]) as usize;
        assert_eq!(query_len, 18); // "MATCH (n) RETURN n".len()
        // query bytes
        assert_eq!(&msg[12..12 + query_len], b"MATCH (n) RETURN n");
        // hint_count = 0
        let hint_offset = 12 + query_len;
        let hint_count = u16::from_le_bytes([msg[hint_offset], msg[hint_offset + 1]]);
        assert_eq!(hint_count, 0);
    }

    #[test]
    fn encode_plan_query_with_hints() {
        let hint1 = [0xAA; 16];
        let hint2 = [0xBB; 16];
        let msg = encode_plan_query("MATCH (n) RETURN n", &[hint1, hint2], 1);
        let query_len = u16::from_le_bytes([msg[10], msg[11]]) as usize;
        let hint_offset = 12 + query_len;
        let hint_count = u16::from_le_bytes([msg[hint_offset], msg[hint_offset + 1]]);
        assert_eq!(hint_count, 2);
        // First hint QID
        let h1_start = hint_offset + 2;
        assert_eq!(&msg[h1_start..h1_start + 16], &[0xAA; 16]);
        // Second hint QID
        let h2_start = h1_start + 16;
        assert_eq!(&msg[h2_start..h2_start + 16], &[0xBB; 16]);
    }

    #[test]
    fn plan_error_reply_decoding() {
        // Simulate an error reply: [0xFF][len:U16LE]["parse error"]
        let error_msg = "parse error";
        let mut payload = vec![0xFF];
        payload.extend_from_slice(&(error_msg.len() as u16).to_le_bytes());
        payload.extend_from_slice(error_msg.as_bytes());

        // Verify the error detection logic
        assert_eq!(payload[0], 0xFF);
        let len = u16::from_le_bytes([payload[1], payload[2]]) as usize;
        let decoded = String::from_utf8_lossy(&payload[3..3 + len]);
        assert_eq!(decoded, "parse error");
    }
```

- [ ] **Step 3: Run tests**

Run: `cargo test cypher::executor --  --nocapture`
Expected: 9 tests pass

- [ ] **Step 4: Commit**

```bash
git add platform/src/cypher/executor.rs
git commit -m "C1.3: PlanQuery encoder and plan_query() async function"
```

---

### Task 7: Roc PlanQuery Handler

**Files:**
- Modify: `packages/graph/codec/Codec.roc` — add PlanQuery decode case to `decode_shard_cmd`
- Modify: `app/graph-app.roc` — add cypher package dependency, handle PlanQuery

- [ ] **Step 1: Add PlanQuery decode to Codec.roc**

In `decode_shard_cmd`, add tag `0x04` case. The return type union expands to include `PlanQuery`.

Update the `decode_shard_cmd` function — add before the `_ -> Err(InvalidTag)` line:

```roc
                0x04 ->
                    when decode_u64(buf, data_start) is
                        Err(e) -> Err(e)
                        Ok({ val: reply_to, next: query_start }) ->
                            when decode_str(buf, query_start) is
                                Err(e) -> Err(e)
                                Ok({ val: query_text, next: hints_start }) ->
                                    when decode_u16(buf, hints_start) is
                                        Err(e) -> Err(e)
                                        Ok({ val: hint_count, next: hints_data_start }) ->
                                            when decode_qid_list(buf, hints_data_start, Num.int_cast(hint_count)) is
                                                Err(e) -> Err(e)
                                                Ok({ val: hint_qids, next }) ->
                                                    Ok({ val: PlanQuery({ reply_to, query_text, hint_qids }), next })
```

Also add the `decode_qid_list` helper function (add near the other decode helpers):

```roc
## Decode a list of QuineIds (16 bytes each) from the buffer.
decode_qid_list : List U8, U64, U64 -> Result { val : List QuineId, next : U64 } [OutOfBounds, BadUtf8, InvalidTag, InvalidDirection]
decode_qid_list = |buf, offset, count|
    List.range({ start: At(0u64), end: Before(count) })
    |> List.walk_try({ val: [], next: offset }, |state, _i|
        if state.next + 16 > List.len(buf) then
            Err(OutOfBounds)
        else
            qid_bytes = List.sublist(buf, { start: state.next, len: 16 })
            qid = QuineId.from_bytes(qid_bytes)
            Ok({ val: List.append(state.val, qid), next: state.next + 16 }))
```

Update the module export in `Codec.roc` module header — no changes needed since `decode_shard_cmd` is already exported.

Also add a Roc `expect` test at the bottom of Codec.roc:

```roc
# -- PlanQuery roundtrip --
expect
    reply_to = 42u64
    query = "MATCH (n) RETURN n"
    # Manually encode: [0x04][reply_to:U64LE][query_str][hint_count=0:U16LE]
    encoded =
        [0x04]
        |> List.concat(encode_u64(reply_to))
        |> List.concat(encode_str(query))
        |> List.concat(encode_u16(0u16))
    when decode_shard_cmd(encoded, 0) is
        Ok({ val: PlanQuery({ reply_to: 42, query_text: "MATCH (n) RETURN n", hint_qids }) }) ->
            List.len(hint_qids) == 0
        _ -> Bool.false
```

- [ ] **Step 2: Verify Codec compiles and tests pass**

Run: `cd /Users/adam/code/proj/rewrite/quine-roc && roc check packages/graph/codec/Codec.roc`

If the Roc compiler doesn't have `check`, run:
`roc test packages/graph/codec/Codec.roc`

Expected: existing tests pass + new PlanQuery expect passes

- [ ] **Step 3: Add cypher package to graph-app.roc**

Update the `app` header in `graph-app.roc`:

```roc
app [init_shard!, handle_message!, on_timer!]
    { pf: platform "../platform/main.roc",
      id: "../packages/core/id/main.roc",
      shard: "../packages/graph/shard/main.roc",
      codec: "../packages/graph/codec/main.roc",
      routing: "../packages/graph/routing/main.roc",
      types: "../packages/graph/types/main.roc",
      standing_result: "../packages/graph/standing/result/main.roc",
      cypher: "../packages/cypher/main.roc" }
```

Add the import:

```roc
import cypher.Lexer
import cypher.Parser
import cypher.Planner
import cypher.PlanCodec
```

- [ ] **Step 4: Add PlanQuery handler to handle_shard_cmd!**

Add a new case in `handle_shard_cmd!` after the `CancelSq` case:

```roc
        Ok({ val: PlanQuery({ reply_to, query_text, hint_qids }) }) ->
            Effect.log!(2, "graph-app: PlanQuery received")
            plan_result =
                Lexer.lex(query_text)
                |> Result.try(|tokens| Parser.parse(tokens))
                |> Result.try(|ast| Planner.plan(ast, hint_qids))
            when plan_result is
                Ok(plan) ->
                    encoded = PlanCodec.encode_plan(plan)
                    Effect.reply!(reply_to, encoded)
                    state

                Err(LexError(msg)) ->
                    Effect.reply!(reply_to, encode_plan_error("lex error: $(msg)"))
                    state

                Err(ParseError(msg)) ->
                    Effect.reply!(reply_to, encode_plan_error("parse error: $(msg)"))
                    state

                Err(PlanError(msg)) ->
                    Effect.reply!(reply_to, encode_plan_error("plan error: $(msg)"))
                    state
```

Add the `encode_plan_error` helper function in `graph-app.roc`:

```roc
## Encode a plan error reply: [0xFF][error_len:U16LE][error_utf8]
encode_plan_error : Str -> List U8
encode_plan_error = |msg|
    msg_bytes = Str.to_utf8(msg)
    [0xFF]
    |> List.concat(encode_u16_le(Num.to_u16(List.len(msg_bytes))))
    |> List.concat(msg_bytes)
```

- [ ] **Step 5: Verify the app compiles**

Run: `cd /Users/adam/code/proj/rewrite/quine-roc && roc check app/graph-app.roc`

Expected: no errors. Note: The `plan_result` error variants (LexError, ParseError, PlanError) must match what Lexer.lex, Parser.parse, and Planner.plan actually return. Check the actual error types and adjust the `when` branches accordingly.

- [ ] **Step 6: Commit**

```bash
git add packages/graph/codec/Codec.roc app/graph-app.roc
git commit -m "C1.3: Roc PlanQuery handler — lex, parse, plan, reply"
```

---

### Task 8: Build Verification and Full Test Run

**Files:**
- All changed files

- [ ] **Step 1: Run Rust tests**

Run: `cargo test 2>&1`
Expected: all tests pass (66 existing + new eval/executor tests)

- [ ] **Step 2: Run Roc tests**

Run: `roc test packages/graph/codec/Codec.roc`
Expected: all codec tests pass including PlanQuery

- [ ] **Step 3: Cargo check for warnings**

Run: `cargo check 2>&1 | grep "^warning"`
Expected: only pre-existing warnings (cypher types not yet used externally)

- [ ] **Step 4: Final commit if any cleanup needed**

```bash
git add -A
git status
# Only commit if there are changes
git commit -m "C1.3: Cypher query executor — build verification"
```

---

## Summary

| Task | What | Tests Added |
|------|------|-------------|
| 1 | eval_expr core (literals, props, variables) | 7 |
| 2 | eval_expr (comparisons, booleans, not, is_null, fn_call) | 15 |
| 3 | project_row | 3 |
| 4 | fan_out_get_nodes + decode_node_data | 4 |
| 5 | execute() plan walker + filter/project integration | 2 |
| 6 | PlanQuery encoder + plan_query() | 3 |
| 7 | Roc PlanQuery handler (Codec + graph-app) | 1 (Roc expect) |
| 8 | Build verification | 0 |
| **Total** | | **~35 new tests** |
