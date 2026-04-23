# C1.3 Cypher Query Executor — Design Spec

**Date:** 2026-04-22
**Status:** Approved
**Depends on:** C1.2 (planner + codecs), A.1 (GetNodeState refactor)
**Blocks:** C1.4 (POST /api/v1/query endpoint)

## Summary

A Rust-side query executor (`platform/src/cypher/executor.rs`) that takes a Cypher query string, routes it to Roc for planning via the existing shard request-response pattern, then walks the resulting QueryPlan — issuing parallel shard requests, evaluating filter expressions locally, and projecting results as JSON.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Where planning happens | Shard-routed (option C) | Reuses existing request-response pattern; no new FFI functions needed |
| Where filter evaluation happens | Rust (option A) | Avoids per-row FFI round-trip; Expr types already decoded into Rust |
| Row representation | Vec-indexed by alias_idx (option B) | Plan already resolves aliases to indices; faster than HashMap<String> |
| Fan-out strategy | Parallel with seam for batching | Single-host MVP; `fan_out_get_nodes` signature supports future batching |

## Data Types

### NodeData

```rust
pub struct NodeData {
    pub id: [u8; 16],
    pub id_str: String,
    pub properties: HashMap<String, QuineValue>,
    pub edges: Vec<HalfEdge>,
}

pub struct HalfEdge {
    pub edge_type: String,
    pub direction: Direction,
    pub other_id: [u8; 16],
}
```

Uses `QuineValue` from `cypher::expr` (already has Str, Integer, True, False, Null).

### Row

```rust
/// One result row: indexed by alias_idx from plan.aliases.
type Row = Vec<Option<NodeData>>;
```

### ExecuteError

```rust
pub enum ExecuteError {
    PlanDecode(String),
    ShardTimeout,
    ShardUnavailable,
    EvalError(String),
    PlanError(String),
}
```

## Execution Flow

```
POST /api/v1/query { "query": "MATCH (n)...", "node_ids": [...] }
        |
        v
  encode PlanQuery command --> shard 0 channel
        |                         |
        |                    Roc: lex -> parse -> plan -> encode_plan
        |                         |
        <-- roc_fx_reply <--------+
        |
  decode QueryPlan bytes (plan::decode_plan)
        |
        v
  walk steps sequentially:
    ScanSeeds -> fan_out_get_nodes() -> initial rows
    Traverse  -> get edges from rows, fan_out_get_nodes() -> expanded rows
    Filter    -> eval_expr() per row, keep matches
    Project   -> extract fields -> JSON response
```

## Key Functions

### execute

```rust
pub async fn execute(
    plan: &QueryPlan,
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
    shard_count: u32,
) -> Result<Vec<serde_json::Value>, ExecuteError>
```

Main entry point. Walks plan steps in order, threading `Vec<Row>` through each step. Returns projected JSON values.

### fan_out_get_nodes

```rust
async fn fan_out_get_nodes(
    node_targets: &[([u8; 16], u32)],
    pending: &PendingRequests,
    registry: &'static ChannelRegistry,
) -> Vec<Result<NodeData, ExecuteError>>
```

Sends GetNodeState to all targets in parallel. Each target is a `(qid, shard_id)` pair. Registers oneshot channels, sends messages, awaits all with 5s timeout.

**Batching seam:** Internally sends all at once. To add batching later, chunk `node_targets` into groups of N and process groups sequentially. Signature and callers don't change.

### eval_expr

```rust
fn eval_expr(expr: &Expr, row: &Row, aliases: &[String]) -> QuineValue
```

Recursive evaluator. Handles:
- **Literal** -> return value
- **Variable** -> only valid as the base of a Property expr (e.g., `n.name`). Standalone variable references in expressions are unsupported in MVP; project_row handles `RETURN n` via WholeNode directly
- **Property** -> evaluate inner expr (usually Variable), look up property key in NodeData.properties
- **Comparison** -> evaluate left/right, compare (Eq, Neq, Lt, Gt, Lte, Gte) with type coercion rules (null propagation: any comparison with Null returns Null)
- **BoolOp** -> short-circuit And/Or
- **Not** -> negate truthy value
- **IsNull** -> return True/False
- **InList** -> not supported in MVP, return EvalError
- **FnCall** -> allowlist: `id(alias)` returns QID as string, `type(alias)` returns label. Unknown function returns EvalError.

Truthy: True is truthy, False/Null are falsy, everything else is truthy.

### project_row

```rust
fn project_row(
    items: &[ProjectItem],
    row: &Row,
    aliases: &[String],
) -> serde_json::Value
```

Converts a row into a JSON object based on Project items:
- **WholeNode(alias_idx)** -> `{ "id": "...", "properties": {...}, "edges": [...] }`
- **NodeProperty { alias_idx, prop, output_name }** -> `{ output_name: value }`

## PlanQuery Shard Command

New shard command sub-tag `0x04` under `TAG_SHARD_CMD` (matching the existing SQ command pattern, not node messages). Tag `0x07` on node messages is already taken by SleepCheck.

### Wire Format

```
[TAG_SHARD_CMD (0x02)]
[CMD_PLAN_QUERY: 0x04]
[reply_to: U64LE]
[query_len: U16LE]
[query_utf8: query_len bytes]
[hint_count: U16LE]
[hint_qid: 16 bytes] * hint_count
```

Sent to shard 0 (or any shard — planning is stateless). Roc decodes via `Codec.decode_shard_cmd`, runs `Lexer.lex -> Parser.parse -> Planner.plan(ast, hint_qids)`, encodes the result with `PlanCodec.encode_plan`, and calls `Effect.reply!(reply_to, encoded_bytes)`.

### Reply Format

On success: raw `PlanCodec.encode_plan` bytes (the executor calls `plan::decode_plan` on them).

On error: `[0xFF][error_len:U16LE][error_utf8]` — tag `0xFF` distinguishes error from valid plan (which starts with step_count U16LE, always < 0xFF).

### Roc-Side Changes

In `graph-app.roc`, add handling for `PlanQuery` in `handle_shard_cmd!`:
1. Decode reply_to (U64LE), query string (len-prefixed), hint QIDs
2. Import cypher package: Lexer, Parser, Planner, PlanCodec
3. Run `Lexer.lex(query) |> Parser.parse |> Planner.plan(_, hints)`
4. On Ok: `Effect.reply!(reply_to, PlanCodec.encode_plan(plan))`
5. On Err: `Effect.reply!(reply_to, [0xFF] ++ encode_error(err))`

## Step Execution Details

### ScanSeeds

1. Take `node_ids` from the step (explicit QIDs from query hints)
2. Compute `shard_for_node` for each
3. `fan_out_get_nodes(targets)` -> get NodeData for each
4. Label filtering: skipped for MVP (no label storage convention exists yet)
5. Filter by `inline_props` if present (match property values against NodeData.properties)
6. Create initial rows: one row per matching node, with `row[alias_idx] = Some(node_data)`

### Traverse

1. For each row in current result set:
   a. Get the "from" node: `row[from_alias_idx]`
   b. Filter its edges by `edge_type` and `direction`
   c. Collect `other_id` from matching edges
2. Deduplicate target node IDs across all rows
3. `fan_out_get_nodes(targets)` for all discovered "to" nodes
4. Filter by `to_label` if present
5. Expand rows: for each original row x each matching "to" node, create a new row with `row[to_alias_idx] = Some(to_node_data)`

### Filter

1. For each row: `eval_expr(predicate, row, aliases)`
2. Keep rows where result is truthy (True)
3. Drop rows where result is falsy (False, Null)

### Project

1. For each surviving row: `project_row(items, row, aliases)`
2. Collect into `Vec<serde_json::Value>`

## Timeouts

- PlanQuery: 10s (parsing + planning may be slower)
- GetNodeState fan-out: 5s (matches existing node query timeout)
- Total query timeout: not enforced at executor level for MVP (sum of step timeouts provides an upper bound)

## Files Changed

| File | Change |
|------|--------|
| `platform/src/cypher/executor.rs` | **New** — executor, eval_expr, fan_out, project |
| `platform/src/cypher/mod.rs` | Add `pub mod executor;` |
| `platform/src/cypher/expr.rs` | Make types `pub` if needed by executor |
| `app/graph-app.roc` | Handle tag `0x07` PlanQuery command |
| `packages/graph/codec/Codec.roc` | Decode PlanQuery message fields |
| `packages/cypher/main.roc` | Expose Lexer, Parser, Planner, PlanCodec to app |

## Testing Strategy

- **Unit tests** for `eval_expr`: literal, variable lookup, property access, comparisons (including null propagation), boolean logic, not, is_null
- **Unit tests** for `project_row`: WholeNode, NodeProperty
- **Unit tests** for `fan_out_get_nodes`: mock with test ChannelRegistry (will timeout, test timeout path)
- **Integration test**: full execute() with a real shard worker running — requires the Roc PlanQuery handler to be wired. May defer to C1.4 endpoint tests.
