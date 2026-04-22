# C1.2: Cypher Query Planner Design

**Date:** 2026-04-22
**Issue:** qr-1fz
**Depends on:** C1.1 (lexer+parser, complete)
**Blocks:** C1.3 (executor)

## Summary

Convert the CypherQuery AST (from the Roc parser) into a QueryPlan — a flat
list of typed operations that the Rust executor can walk to resolve a Cypher
read query against the graph. The QueryPlan is the FFI boundary: Roc owns
parsing and planning (pure FP), Rust owns execution (shard I/O).

## Design Decisions

1. **Seed-and-expand (no full scans):** The MVP has no property index. Queries
   require `node_ids` hints from the API caller. Unconstrained patterns without
   hints fail with `PlanError`. See `docs/src/future/problems/property-index.md`.

2. **Filter as explicit plan step:** WHERE predicates are represented as a
   first-class `Filter` step carrying a serialized `Expr`. Rust does not
   interpret the Expr — it sends bytes back to Roc's `Expr.eval` via FFI.
   Keeps all evaluation logic in Roc.

3. **Tag-length-value codec for FFI:** Reuses the established shard message
   codec pattern. Plan bytes are inspectable and decoupled from Roc ABI.

## QueryPlan Type (Roc)

```roc
QueryPlan : {
    steps : List PlanStep,
    aliases : List Str,
}

PlanStep : [
    ScanSeeds {
        alias : Str,
        node_ids : List QuineId,
        label : [Labeled Str, Unlabeled],
        inline_props : List { key : Str, value : QuineValue },
    },
    Traverse {
        from_alias : Str,
        edge_type : [Typed Str, Untyped],
        direction : [Outgoing, Incoming, Undirected],
        to_alias : Str,
        to_label : [Labeled Str, Unlabeled],
    },
    Filter {
        predicate : Expr,
    },
    Project {
        items : List ProjectItem,
    },
]

ProjectItem : [
    WholeNode Str,
    NodeProperty { alias : Str, prop : Str, output_name : Str },
]
```

## Planner Algorithm

`plan : CypherQuery, List QuineId -> Result QueryPlan [PlanError Str]`

1. **ScanSeeds:** From `pattern.start` node. If `node_ids` is empty and no
   inline props/label, return `PlanError "no seed nodes"`. Bind alias.

2. **Traverse:** Walk `pattern.steps`. For each `{ edge, node }`, emit
   `Traverse` mapping direction, edge type, and far-end alias.

3. **Filter:** If `where_` is `Where expr`, emit `Filter { predicate: expr }`.
   No transformation — the parser's Expr is used directly.

4. **Project:** Map each `ReturnItem`:
   - `WholeAlias "n"` → `WholeNode "n"`
   - `PropAccess { alias, prop, rename_as }` → `NodeProperty` with
     `output_name` defaulting to `"alias.prop"` when `NoAs`.

5. **Collect aliases:** All unique aliases from ScanSeeds + Traverse steps.

**Error cases:**
- No seed nodes → `PlanError "no seed nodes: provide node_ids or inline property constraints"`
- Return item references unknown alias → `PlanError "unknown alias: x"`
- Alias collision (edge alias = node alias) → `PlanError`

## Query Examples → Plans

```
MATCH (n) WHERE n.name = "Alice" RETURN n
  node_ids: ["alice"]
  → ScanSeeds(alias="n", node_ids=["alice"])
  → Filter(n.name = "Alice")
  → Project(WholeNode "n")

MATCH (n:Person) WHERE n.age > 25 RETURN n.name, n.age
  node_ids: ["a1", "a2"]
  → ScanSeeds(alias="n", label=Person, node_ids=["a1","a2"])
  → Filter(n.age > 25)
  → Project(NodeProperty("n","name","n.name"), NodeProperty("n","age","n.age"))

MATCH (a)-[:KNOWS]->(b) RETURN a.name, b.name
  node_ids: ["alice"]
  → ScanSeeds(alias="a", node_ids=["alice"])
  → Traverse(from="a", KNOWS, Outgoing, to="b")
  → Project(NodeProperty("a","name","a.name"), NodeProperty("b","name","b.name"))

MATCH (a)-[:KNOWS]->(b)-[:FOLLOWS]->(c) RETURN a.name, c.name
  node_ids: ["alice"]
  → ScanSeeds(alias="a", node_ids=["alice"])
  → Traverse(from="a", KNOWS, Outgoing, to="b")
  → Traverse(from="b", FOLLOWS, Outgoing, to="c")
  → Project(NodeProperty("a","name","a.name"), NodeProperty("c","name","c.name"))
```

## Codec Wire Format

### Plan Envelope

```
[step_count : U16LE]
[alias_count : U16LE]
[aliases... : (len:U16LE, utf8)*]
[steps... : (tag:U8, payload)*]
```

### Step Tags (0x30 range)

| Tag  | Step       |
|------|------------|
| 0x30 | ScanSeeds  |
| 0x31 | Traverse   |
| 0x32 | Filter     |
| 0x33 | Project    |

### ScanSeeds (0x30)

```
[alias_idx : U16LE]
[label_tag : U8]  (0x00=Unlabeled, 0x01=Labeled)
[label_str : len:U16LE + utf8]?
[inline_prop_count : U16LE]
[inline_props... : (key_len:U16LE, key_utf8, value via QuineValue codec)*]
[node_id_count : U16LE]
[node_ids... : 16 bytes each]
```

### Traverse (0x31)

```
[from_alias_idx : U16LE]
[to_alias_idx : U16LE]
[direction : U8]  (0x00=Outgoing, 0x01=Incoming, 0x02=Undirected)
[type_tag : U8]   (0x00=Untyped, 0x01=Typed)
[type_str : len:U16LE + utf8]?
[to_label_tag : U8]  (0x00=Unlabeled, 0x01=Labeled)
[to_label_str : len:U16LE + utf8]?  (only if Labeled)
```

### Filter (0x32)

```
[expr_bytes : len:U32LE + encoded Expr]
```

### Project (0x33)

```
[item_count : U16LE]
[items... : (tag:U8, payload)*]
  0x00 = WholeNode     [alias_idx : U16LE]
  0x01 = NodeProperty  [alias_idx:U16LE][prop_len:U16LE][prop_utf8][out_len:U16LE][out_utf8]
```

### Expr Codec (0x40 range)

| Tag  | Expr Variant |
|------|-------------|
| 0x40 | Literal     |
| 0x41 | Variable    |
| 0x42 | Property    |
| 0x43 | Comparison  |
| 0x44 | BoolOp      |
| 0x45 | Not         |
| 0x46 | IsNull      |
| 0x47 | InList      |
| 0x48 | FnCall      |

Each Expr node is `[tag:U8][payload]`, recursively encoded. Literal payloads
reuse existing QuineValue codec.

CompOp tags: `0x00`=Eq, `0x01`=Neq, `0x02`=Lt, `0x03`=Gt, `0x04`=Lte, `0x05`=Gte.
BoolLogic tags: `0x00`=And, `0x01`=Or.

## Rust-Side Types

`platform/src/cypher/plan.rs`:

```rust
pub struct QueryPlan {
    pub steps: Vec<PlanStep>,
    pub aliases: Vec<String>,
}

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

pub enum ProjectItem {
    WholeNode(usize),
    NodeProperty {
        alias_idx: usize,
        prop: String,
        output_name: String,
    },
}
```

Filter holds opaque `expr_bytes` — Rust does not interpret expressions. In
C1.3, these bytes are sent back to Roc via `roc_fx_eval_expr` for evaluation.

## New Roc Host Functions (wired in C1.3)

- `roc_fx_parse_and_plan : Str, List QuineId -> List U8` — parse + plan,
  returns encoded QueryPlan bytes
- `roc_fx_eval_expr : List U8, List U8 -> U8` — evaluate Expr against
  bindings, returns 1=true / 0=false / 2=null

## File Layout

### Roc (packages/cypher/)
- `Planner.roc` — `plan` function, QueryPlan/PlanStep/ProjectItem types
- `PlanCodec.roc` — encode QueryPlan to bytes
- `ExprCodec.roc` — encode Expr to bytes

### Rust (platform/src/cypher/)
- `mod.rs` — module root
- `plan.rs` — QueryPlan/PlanStep/ProjectItem structs + `decode_plan`
- `expr.rs` — Expr decode (verify round-trip; full eval wiring is C1.3)

## Scope

### In scope (C1.2)
- All Roc types, planner logic, and codec encoders listed above
- Rust types and decoders
- Tests: planner logic, codec round-trips, Rust decode, error cases

### Out of scope
- Host function wiring (`roc_fx_*`) — C1.3
- Shard I/O execution — C1.3
- Query API endpoint — C1.3
- Property index — future (see `docs/src/future/problems/property-index.md`)
- Mutations, aggregations, OPTIONAL MATCH — future

## Test Plan

### Roc (expect tests)
- **Planner:** single node, labeled node, single-hop, multi-hop, with WHERE,
  with inline props, missing seeds error, unknown alias error, alias collision
- **PlanCodec:** encode→decode round-trip for each step type, multi-step plan
- **ExprCodec:** encode→decode round-trip for each Expr variant, nested exprs

### Rust (#[test])
- **plan.rs:** decode valid plan bytes, reject truncated bytes, reject unknown
  tags, round-trip with Roc encoder output
- **expr.rs:** decode each Expr variant, reject malformed bytes
