# Query Languages

## What Happens Here

This stage covers how users express graph queries and mutations. Quine supports two query languages -- Cypher (the primary, fully-featured language) and Gremlin (a limited subset for traversal queries). Both languages follow the same high-level arc: source text is parsed into an AST, the AST is analyzed/compiled into an executable query plan, and the plan is interpreted against the live graph.

### The Cypher Pipeline (Primary Path)

Quine's Cypher support involves **two parallel parsing pipelines** and one compilation/execution pipeline:

#### Pipeline 1: openCypher Front-End (Production Compilation)

This is the pipeline used for actual query execution. It lives in `quine-cypher/` and delegates parsing to the **openCypher v9.0 JavaCC parser** (`org.opencypher.v9_0`), a third-party library (`com.thatdot.opencypher` -- a thatdot fork):

1. **Parse + Rewrite** (`openCypherParseAndRewrite` in `quine-cypher/.../compiler/cypher/package.scala`):
   - `OpenCypherJavaCCParsing` -- JavaCC-based parser produces openCypher AST (`org.opencypher.v9_0.ast`)
   - `SyntaxDeprecationWarningsAndReplacements` -- flag deprecated syntax
   - `PreparatoryRewriting` -- normalize WITH/WHERE/MERGE/CALL clauses
   - `patternExpressionAsComprehension` -- desugar pattern expressions
   - `SemanticAnalysis` -- type checking and scope analysis
   - `AstRewriting` -- normalize redundant AST nodes
   - `ProjectNamedPathsRewriter` -- rewrite named paths
   - `LiteralExtraction` -- extract literal values as parameters
   - `resolveFunctions` / `resolveCalls` -- resolve function/procedure names
   - `CNFNormalizer` + `transitiveClosure` + predicate rewrites -- optimize predicates

2. **Compile** (`compileStatement` / `QueryPart.compile` in `quine-cypher/.../compiler/cypher/`):
   - Takes the openCypher AST (`org.opencypher.v9_0.ast.Statement`)
   - Produces a Quine `Query[Location.Anywhere]` (defined in `quine-core/.../graph/cypher/Query.scala`)
   - Key compilation steps:
     - **Graph patterns** (`Graph.fromPattern` / `Graph.synthesizeFetch`) -- MATCH clauses become graph traversal plans with entry points, edge expansions, and node checks
     - **Expressions** (`Expression.compile`) -- openCypher expressions become `Expr` nodes (in `quine-core`)
     - **Mutations** (CREATE/SET/DELETE) -- become `SetProperty`, `SetEdge`, `SetLabels`, `Delete` query nodes
     - **Clauses** (WITH/RETURN/UNWIND/CALL) -- become `AdjustContext`, `Return`, `Unwind`, `ProcedureCall`, `SubQuery` nodes
   - Uses `CompM` monad for stateful compilation (tracks columns in scope, parameter indices, source positions)
   - Compilation results are cached in a Guava/Scaffeine cache (up to 1024 entries)

3. **Execute** (`CypherOpsGraph.cypherOps.query` / `continueQuery`):
   - Picks an interpreter based on timestamp: `ThoroughgoingInterpreter` for present, `AtTimeInterpreter` for historical queries
   - Interpreters implement `CypherInterpreter[Location]` trait with pattern matching over all `Query` variants
   - `GraphExternalInterpreter` handles queries from outside the graph
   - On-node queries run inside Pekko actor message handlers (`CypherBehavior`)

#### Pipeline 2: ANTLR4-Based Quine Language (Newer/In-Progress)

This pipeline lives in `quine-language/` and appears to be a newer, thatdot-owned Cypher parser being developed in parallel:

1. **Lex** (`LexerPhase` in `quine-language/.../cypher/phases/LexerPhase.scala`):
   - Uses ANTLR4 with the `Cypher.g4` grammar (`quine-language/src/main/antlr4/Cypher.g4`)
   - ANTLR4 generates `CypherLexer` and `CypherParser` into `com.thatdot.quine.cypher.parsing`
   - Produces `CommonTokenStream`

2. **Parse** (`ParserPhase` in `quine-language/.../cypher/phases/ParserPhase.scala`):
   - Walks the ANTLR4 parse tree using hand-written visitor classes (two parallel visitor sets):
     - `visitors/ast/` -- builds the quine-language AST (`com.thatdot.quine.cypher.ast.Query`)
     - `visitors/semantic/` -- performs semantic analysis alongside AST construction
   - Produces `com.thatdot.quine.cypher.ast.Query` (distinct from the openCypher AST)

3. **Symbol Analysis** (`SymbolAnalysisPhase`):
   - Assigns unique integer IDs (BindingId) to all variables
   - Builds a symbol table mapping names to binding entries
   - Rewrites `CypherIdentifier` references to `BindingId` references

4. **Type Checking** (`TypeCheckingPhase`):
   - Infers types for expressions and bindings
   - Uses the `Type` ADT from `quine-language/.../types/Type.scala`

5. **Materialization** (`MaterializationPhase`):
   - Produces property access mappings and aggregation access mappings
   - This is the final output: `TypeCheckResult` (aliased as `CompileResult`)

The pipeline is composed using the `Phase` trait with `andThen` combinators and threaded state via `cats.data.IndexedState`.

**Current status**: The `Cypher.compile()` entry point produces a `TypeCheckResult` but this does NOT yet connect to the execution engine. The production path still goes through Pipeline 1 (openCypher).

### The Gremlin Pipeline

Gremlin support lives entirely in `quine-gremlin/` and is a self-contained, much simpler system:

1. **Lex** (`GremlinLexer` in `quine-gremlin/.../gremlin/GremlinLexer.scala`):
   - Uses Scala's `JavaTokenParsers` with `Scanners` trait (not ANTLR4)
   - Produces a stream of `GremlinToken` values (punctuation, identifiers, literals)
   - Custom ID parsing via regex, pluggable custom literal parsers

2. **Parse** (`GremlinParser` trait in `quine-gremlin/.../gremlin/GremlinParser.scala`):
   - Uses Scala's `PackratParsers` (parser combinators with memoization)
   - Produces `Query` (either `AssignLiteral` for variable bindings or `FinalTraversal` for actual queries)
   - A `Traversal` is a sequence of `TraversalStep`s

3. **Execute** (directly -- no separate compilation step):
   - `GremlinQueryRunner.query()` lexes, parses, then immediately runs `Query.run()`
   - Each `TraversalStep.flow()` produces a Pekko Streams `Flow[Result, Result, NotUsed]`
   - Steps are composed by folding flows: `steps.foldLeft(Flow[Result])((acc, step) => acc.via(step.flow.get))`
   - Graph operations happen inline in the step implementations via `graph.literalOps(namespace)`

Entry point: `GremlinQueryRunner(graph).query("g.V().has('foo').valueMap()")` -- a single call from text to streaming results.

## Key Types and Structures

### Cypher AST (quine-language -- the newer pipeline)

File: `quine-language/.../cypher/ast/AST.scala`

```
Query
  Union(all, lhs: Query, rhs: SingleQuery)
  SingleQuery
    MultipartQuery(queryParts: List[QueryPart], into: SinglepartQuery)
    SinglepartQuery(queryParts, hasWildcard, isDistinct, bindings: List[Projection], orderBy, skip, limit)

QueryPart = ReadingClausePart | WithClausePart | EffectPart

ReadingClause
  FromPatterns(patterns: List[GraphPattern], maybePredicate, isOptional)
  FromUnwind(list: Expression, as)
  FromProcedure(name, args, yields)
  FromSubquery(bindings, subquery: Query)

Effect
  Foreach(binding, in, effects: List[Effect])
  SetProperty(property, value)
  SetProperties(of, properties)
  SetLabel(on, labels)
  Create(patterns: List[GraphPattern])

GraphPattern(initial: NodePattern, path: List[Connection])
NodePattern(maybeBinding, labels, maybeProperties)
EdgePattern(maybeBinding, direction, edgeType)
```

### Cypher Expressions (quine-language)

File: `quine-language/.../language/ast/AST.scala`

```
Expression (all carry source: Source, ty: Option[Type])
  IdLookup | SynthesizeId | AtomicLiteral | ListLiteral | MapLiteral
  Ident | Parameter | Apply(name, args) | UnaryOp | BinOp
  FieldAccess | IndexIntoArray | IsNull | CaseBlock

Value = Null | True | False | Integer(Long) | Real(Double) | Text(String)
      | Bytes | Duration | Date | DateTime | DateTimeLocal
      | List | Map | NodeId | Node | Relationship

Operator = Plus | Minus | Asterisk | Slash | Percent | Carat
         | Equals | NotEquals | LessThan | LessThanEqual | GreaterThan | GreaterThanEqual
         | And | Or | Xor | Not

Direction = Left | Right
```

### Quine Query Plan (quine-core -- the execution IR)

File: `quine-core/.../graph/cypher/Query.scala`

This is the IR that both pipelines ultimately need to target:

```
Query[+Start <: Location] (sealed abstract class, ~25 variants)

  -- Entry points --
  Empty | Unit | AnchoredEntry(entry: EntryPoint, andThen) | ArgumentEntry(node: Expr, andThen)

  -- Graph-local operations (Location.OnNode) --
  LocalNode(labelsOpt, propertiesOpt, bindName)
  Expand(edgeName, toNode, direction, bindRelation, range, andThen)
  GetDegree(edgeName, direction, bindName)
  SetProperty(nodeVar, key, newValue)
  SetProperties(nodeVar, properties, includeExisting)
  SetLabels(nodeVar, labels, add)
  SetEdge(label, direction, bindRelation, target, add, andThen)

  -- Query composition --
  Apply(startWithThis, thenCrossWithThis)
  Union(unionLhs, unionRhs)
  Or(tryFirst, trySecond)
  ValueHashJoin(joinLhs, joinRhs, lhsProperty, rhsProperty)
  SemiApply(acceptIfThisSucceeds, inverted)
  Optional(query)
  SubQuery(subQuery, isUnitSubquery, importedVariables)
  RecursiveSubQuery(innerQuery, initialVariables, variableMappings, doneExpression)

  -- Result shaping --
  Filter(condition, toFilter)
  Skip(drop, toSkip) | Limit(take, toLimit) | Sort(by, toSort)
  Return(toReturn, orderBy, distinctBy, drop, take)
  Distinct(by, toDedup)
  Unwind(listExpr, as, unwindFrom)
  AdjustContext(dropExisting, toAdd, adjustThis)
  EagerAggregation(aggregateAlong, aggregateWith, toAggregate, keepExisting)

  -- External --
  Delete(toDelete, detach)
  ProcedureCall(procedure, arguments, returns)
  LoadCSV(withHeaders, urlString, variable, fieldTerminator)

Location = OnNode | External | Anywhere (Anywhere <: OnNode with External)
EntryPoint = AllNodesScan | NodeById(ids)
```

### Gremlin Types

```
Query = AssignLiteral(name, value, then: Query) | FinalTraversal(traversal: Traversal)
Traversal(steps: Seq[TraversalStep])

TraversalStep (25 variants, each produces a Flow[Result, Result, NotUsed]):
  EmptyVertices | Vertices(vertices) | RecentVertices(limit)
  Has(key, hasRestriction) | HasId(ids) | HasLabel
  HopFromVertex(edgeNames, dirRestriction, toVertex, limitOpt) | HopFromEdge(dirRestriction)
  Values(keys, groupResultsInMap)
  Dedup | As(key) | Select(keys) | Limit(num)
  Id(stringOutput) | UnrollPath | Count | GroupCount
  Logical(kind: Not|Where|And|Or) | Union(combined)
  Is(testAgainst) | EqToVar(key)

GremlinExpression = TypedValue(QuineValue) | IdFromFunc(args) | RawArr(elements) | Variable(name)
GremlinPredicateExpression = EqPred | NeqPred | WithinPred | RegexPred
Result(unwrap: Any, path: List[QuineId], matchContext: VariableStore)
```

## Dependencies

### Internal (other stages/modules)

- **quine-core**: `Query[Location]`, `Expr`, `Value`, `CypherOpsGraph`, `CypherInterpreter`, `BaseNodeActor`, `CypherBehavior` -- the execution engine and node model
- **quine-core graph model**: `QuineId`, `QuineIdProvider`, `HalfEdge`, `EdgeDirection`, `PropertyValue`, `NamespaceId`, `Milliseconds`
- **quine-core**: `LiteralOpsGraph` -- Gremlin accesses the graph through `graph.literalOps(namespace).getProps()`, `graph.literalOps(namespace).getEdges()`, `graph.enumerateAllNodeIds()`

### External (JVM libraries)

**Cypher Pipeline 1 (openCypher -- production)**:
- `com.thatdot.opencypher:expressions` / `front-end` / `opencypher-cypher-ast-factory` / `util` v9.0 -- thatdot fork of Neo4j's openCypher reference implementation. Provides JavaCC parser, AST types, semantic analysis, rewriting infrastructure
- `com.github.blemale:scaffeine` -- Guava/Caffeine cache wrapper for compiled query caching
- `cats-core` -- `Validated`, `Either` for error handling in `CompM`

**Cypher Pipeline 2 (quine-language -- in-progress)**:
- `org.antlr:antlr4-runtime` -- ANTLR4 runtime for the custom Cypher parser generated from `Cypher.g4`
- `cats-effect` -- effect monad
- `org.eclipse.lsp4j` -- Language Server Protocol support (for IDE tooling)
- `org.typelevel:cats-core` -- `IndexedState`, `OptionT` for the phase pipeline

**Gremlin**:
- `scala.util.parsing.combinator` -- Scala parser combinators for lexing and parsing (part of scala-parser-combinators library)
- `org.apache.pekko` (`pekko-stream`) -- `Flow`, `Source` for streaming query execution
- `org.apache.commons.text` -- `StringEscapeUtils` for pretty-printing

### Scala-Specific Idioms

- **Sealed ADTs with pattern matching**: All ASTs (both Cypher and Gremlin), the `Query` IR, and `Expr` are sealed hierarchies exhaustively matched in interpreters
- **Higher-kinded type parameters**: `Query[+Start <: Location]` uses phantom type parameters to enforce that on-node queries only run on nodes, and anywhere queries can run anywhere
- **Monad transformers**: `CompM` wraps `EitherT[ReaderWriterState[...], ...]` for the Cypher compiler's stateful, error-handling computation
- **Cats IndexedState**: The quine-language pipeline threads compiler state through phases using `IndexedState` (each phase can change the state type)
- **Parser combinators**: Gremlin uses Scala's `PackratParsers` with `~`, `^^`, `^^^`, `~>`, `<~` operators
- **Implicit conversions/parameters**: `GremlinTypes` trait uses implicit `graph`, `timeout`, `VariableStore`, `LogConfig` throughout
- **Self-types**: `GremlinParser` requires `self: GremlinTypes =>`, mixing concrete graph access into the parser
- **ANTLR4 visitor pattern**: The quine-language parser uses generated visitors from `Cypher.g4` with hand-written visitor implementations

## Essential vs. Incidental Complexity

### Essential (must port)

1. **Cypher query semantics**: The meaning of MATCH, WHERE, RETURN, WITH, UNWIND, CREATE, SET, DELETE, MERGE, FOREACH, CALL, UNION, ORDER BY, SKIP, LIMIT, DISTINCT. These define what users can express.

2. **The Query IR** (`Query[Location]` with ~25 variants): This is the execution plan that bridges parsed queries to graph operations. The variant set (AnchoredEntry, Expand, LocalNode, SetProperty, SetEdge, etc.) defines the operational semantics of what the graph can do.

3. **Expression evaluation**: The `Expr` type hierarchy (variables, literals, operators, functions, property access, list/map operations, aggregators) must be faithfully reproduced.

4. **Graph pattern matching**: The algorithm in `Graph.synthesizeFetch`/`synthesizeFetchOnNode` that turns a declarative MATCH pattern into an execution plan (choose entry points, traverse edges, check properties) is essential graph query planning logic.

5. **Cypher function library**: Built-in functions (id, idFrom, type, labels, properties, string functions, math functions, list functions, temporal functions) and procedures (reify.time, do.cypher.*, graph algorithms).

6. **Standing query pattern compilation**: `StandingQueryPatterns.compile` turns a restricted subset of Cypher (MATCH-WHERE-RETURN) into `GraphQueryPattern` for standing queries. This is core to Quine's streaming use case.

7. **Gremlin traversal semantics**: The subset of Gremlin steps supported (V, has, hasNot, hasLabel, hasId, out/in/both, outE/inE/bothE, outV/inV/bothV, values, valueMap, dedup, as, select, limit, count, groupCount, not, where, and, or, is, union, id, unrollPath) plus the streaming execution model.

8. **Location-typed query safety**: The distinction between `Location.OnNode` and `Location.Anywhere` queries, ensuring on-node operations only execute on nodes.

### Incidental (rethink for Roc)

1. **openCypher front-end dependency**: The entire `org.opencypher.v9_0` library (JavaCC parser, semantic analysis, AST rewriting pipeline). This is the largest external dependency and is JVM-specific.

2. **ANTLR4 dependency**: The quine-language pipeline's ANTLR4 parser generator. The grammar itself (`Cypher.g4`) documents the syntax but the tooling is JVM-specific.

3. **Dual AST representation**: Having both the openCypher AST (`org.opencypher.v9_0.ast`) and the quine-language AST (`com.thatdot.quine.cypher.ast`) means the same concepts are modeled twice. Roc needs only one AST.

4. **Cats monad transformer stack**: `CompM` wrapping `EitherT[ReaderWriterState[...], ...]` is idiomatic Scala/cats but would not translate directly to Roc.

5. **Pekko Streams for Gremlin**: Each Gremlin `TraversalStep.flow()` returns a `Flow[Result, Result, NotUsed]`. Roc would need a different streaming primitive.

6. **Reflection in Plan**: `Plan.fromQuery` uses Java reflection (`getDeclaredFields`, `getDeclaredMethod`, `invoke`) to introspect query AST nodes for the EXPLAIN plan feature.

7. **Mutable state in compilation**: `mutable.Set`, `Map.newBuilder` etc. in `Graph.fromPattern` and elsewhere.

8. **Guava/Scaffeine caching**: The compiled query cache is a JVM-specific caching library.

9. **Scala parser combinators**: The Gremlin parser uses Scala's parser combinator library, which has no Roc equivalent.

10. **Implicit parameters threading**: Gremlin pervasively threads `graph`, `timeout`, `namespace`, `atTime`, `logConfig` through implicits.

## Roc Translation Notes

### Maps Naturally

- **Sealed ADTs**: Roc's tagged unions are a direct fit for `Query[Location]`, `Expr`, `Value`, `Expression`, `TraversalStep`, etc. The ~25 `Query` variants, ~60 `Expr` variants, and ~25 Gremlin steps all map to Roc union types with exhaustive pattern matching.

- **The quine-language AST**: `Query`, `ReadingClause`, `Effect`, `Expression`, `Value`, `Operator`, `Direction`, `NodePattern`, `GraphPattern` -- these are pure data types with no behavior, ideal for Roc records/tags.

- **Phase pipeline composition**: The `Phase` trait's `andThen` combinator is essentially function composition. In Roc: `parse |> symbolAnalyze |> typeCheck |> materialize`.

- **Query plan semantics**: The `Query` IR is a tree of product types. The interpreter dispatches on variants via pattern matching. This is a natural fit for Roc.

- **Gremlin predicates**: `EqPred`, `NeqPred`, `WithinPred`, `RegexPred` are simple data types.

- **Source positions**: `Source.TextSource(start, end)` for error reporting is a simple record.

### Needs Different Approach

- **Parser**: Roc has no ANTLR4, no JavaCC, and no parser combinator library in its standard library. Options:
  1. Write a hand-rolled recursive descent parser directly in Roc (the grammar is documented in `Cypher.g4`, ~600 lines). This is feasible and gives full control.
  2. Use a Roc parser combinator library if one exists/is created.
  3. For Gremlin, the grammar is simple enough that a recursive descent parser is straightforward.

- **Compilation monad**: `CompM` (EitherT + ReaderWriterState) would become explicit state-passing in Roc. A compilation function would take `(ParametersIndex, SourceText, QueryScopeInfo)` as parameters and return `Result CompileError (QueryScopeInfo, Query)`. Roc's `Result` type handles the error case.

- **Location phantom types**: `Query[+Start <: Location]` uses JVM subtyping for compile-time safety. In Roc, this would likely become either:
  - Two separate types (`OnNodeQuery` and `AnywhereQuery`) with explicit conversions, or
  - A single `Query` type with a runtime `location` tag, relying on tests rather than the type system

- **Streaming execution**: Both Cypher (via `InterpM`) and Gremlin (via Pekko Streams `Flow`) use streaming. Roc would need a lazy sequence/iterator/stream abstraction for backpressured result sets. This might be a custom `Task`-based pull stream or Roc's built-in concurrency primitives.

- **Graph access pattern**: Gremlin steps call `graph.literalOps(namespace).getProps()` and `.getEdges()` directly. Cypher goes through interpreters that dispatch to node actors. In Roc, the boundary would be a clean interface/ability:
  ```
  GraphOps : {
      getProperties : NodeId -> Task (Dict Str Value)
      getEdges : NodeId, EdgeFilter -> Task (List Edge)
      setProperty : NodeId, Str, Value -> Task {}
      ...
  }
  ```

- **Compiled query cache**: Replace Guava/Scaffeine with a Roc `Dict` behind a mutable reference, or use an LRU cache implementation.

- **openCypher semantic analysis**: The 10+ openCypher rewriting phases (CNF normalization, transitive closure, etc.) would need to be reimplemented or simplified. Many are optimizations rather than correctness requirements.

### Open Questions

1. **Which Cypher pipeline to port?** The codebase has two pipelines. Pipeline 1 (openCypher) is production-proven but deeply entangled with the `org.opencypher` library. Pipeline 2 (quine-language/ANTLR4) has its own AST and is cleaner but incomplete. The quine-language AST is a better starting point since it's thatdot-owned and simpler, but it doesn't yet connect to the execution `Query` IR. The Roc port likely needs to build: `Roc Cypher parser -> quine-language-style AST -> Query IR`.

2. **What is the minimum viable Cypher subset?** Not all of Cypher is needed on day one. The essential subset for Quine's core use case is: MATCH with node/edge patterns, WHERE filtering, RETURN/WITH projections, CREATE/SET for mutations, UNWIND, CALL for procedures. MERGE, FOREACH, LOAD CSV, and complex path patterns could come later.

3. **Should Gremlin be ported at all?** The Gremlin support is a "nice to have" compatibility layer. It uses `LiteralOpsGraph` (a lower-level API) rather than Cypher's compilation pipeline. The TODO comments in `quine-gremlin/package.scala` mention several unimplemented features (fold/unfold, group/by). If Gremlin is needed, it's a relatively small and independent port.

4. **How to handle the standing query compiler?** `StandingQueryPatterns.compile` expects a very restricted Cypher subset (single MATCH-WHERE-RETURN). This is critical for Quine's streaming behavior. Should this be a separate, simpler parser, or a validation pass on the full AST?

5. **What replaces openCypher's semantic analysis?** The openCypher pipeline does scope analysis, type inference, CNF normalization, transitive closure, predicate rewriting, and more. How much of this is needed for correctness vs. optimization? The quine-language pipeline already has symbol analysis and type checking, suggesting the minimum viable set is known.

6. **How to express the Location type constraint?** The `Query[+Start <: Location]` pattern prevents bugs where an on-node query is executed off-node. Roc lacks subtyping, so this safety must be achieved differently (separate types, builder patterns, or runtime checks).

7. **What about the Bolt protocol?** `quine-cypher/` includes `bolt/Protocol.scala`, `bolt/Structure.scala`, `bolt/Serialization.scala` for Neo4j Bolt wire protocol compatibility. Is Bolt protocol support needed in the Roc port, or will a different query API suffice?
