module [
    parse,
    parse_cypher,
]

import Token exposing [Token]
import Ast exposing [CypherQuery, Pattern, NodePattern, EdgePattern, ReturnItem, ParseError]
import Lexer exposing [lex]
import expr.Expr exposing [Expr]
import model.QuineValue exposing [QuineValue]

## Parser state: the token list and the current read position.
State : { tokens : List Token, pos : U64 }

## Peek at the current token without consuming it.
## Returns Eof if we are past the end of the list.
peek : State -> Token
peek = |state|
    when List.get(state.tokens, state.pos) is
        Ok(tok) -> tok
        Err(OutOfBounds) -> Eof

## Advance the position by one.
advance : State -> State
advance = |state|
    { state & pos: state.pos + 1 }

## Expect a specific keyword token; advance and return the new state or an error.
## Uses pattern matching via token_matches to avoid Eq requirement on Token (LitFloat F64).
expect_kw : State, Token, Str -> Result State ParseError
expect_kw = |state, expected, msg|
    tok = peek(state)
    if token_matches(tok, expected) then
        Ok(advance(state))
    else
        Err({ message: msg, position: state.pos, context: "parser" })

## Check whether two tokens are identical variants with equal payloads.
## F64 cannot implement Eq, so we pattern-match instead of using ==.
token_matches : Token, Token -> Bool
token_matches = |a, b|
    when (a, b) is
        (KwMatch, KwMatch) -> Bool.true
        (KwWhere, KwWhere) -> Bool.true
        (KwReturn, KwReturn) -> Bool.true
        (KwAnd, KwAnd) -> Bool.true
        (KwOr, KwOr) -> Bool.true
        (KwIs, KwIs) -> Bool.true
        (KwNot, KwNot) -> Bool.true
        (KwNull, KwNull) -> Bool.true
        (KwAs, KwAs) -> Bool.true
        (KwTrue, KwTrue) -> Bool.true
        (KwFalse, KwFalse) -> Bool.true
        (LParen, LParen) -> Bool.true
        (RParen, RParen) -> Bool.true
        (LBracket, LBracket) -> Bool.true
        (RBracket, RBracket) -> Bool.true
        (LBrace, LBrace) -> Bool.true
        (RBrace, RBrace) -> Bool.true
        (Colon, Colon) -> Bool.true
        (Comma, Comma) -> Bool.true
        (Dot, Dot) -> Bool.true
        (DashBracket, DashBracket) -> Bool.true
        (DashArrowRight, DashArrowRight) -> Bool.true
        (LeftArrowDash, LeftArrowDash) -> Bool.true
        (Dash, Dash) -> Bool.true
        (OpEq, OpEq) -> Bool.true
        (OpNeq, OpNeq) -> Bool.true
        (OpLt, OpLt) -> Bool.true
        (OpGt, OpGt) -> Bool.true
        (OpLte, OpLte) -> Bool.true
        (OpGte, OpGte) -> Bool.true
        (Eof, Eof) -> Bool.true
        (LitStr(x), LitStr(y)) -> x == y
        (LitInt(x), LitInt(y)) -> x == y
        (Ident(x), Ident(y)) -> x == y
        _ -> Bool.false

## Expect end-of-file; return the state or an error.
expect_eof : State -> Result State ParseError
expect_eof = |state|
    tok = peek(state)
    when tok is
        Eof -> Ok(state)
        _ -> Err({ message: "expected end of input", position: state.pos, context: "parser" })

## Parse a graph pattern: start node followed by zero or more (edge, node) steps.
## Handles `(a)-[:KNOWS]->(b)-[:FOLLOWS]->(c)` and variants.
parse_pattern : State -> Result (Pattern, State) ParseError
parse_pattern = |state|
    (start, state1) = parse_node_pattern(state)?
    (steps, state2) = parse_pattern_steps(state1, [])?
    Ok(({ start, steps }, state2))

## Recursive helper: consume (edge, node) pairs as long as an edge token is present.
parse_pattern_steps : State, List { edge : EdgePattern, node : NodePattern } -> Result (List { edge : EdgePattern, node : NodePattern }, State) ParseError
parse_pattern_steps = |state, acc|
    tok = peek(state)
    if token_matches(tok, DashBracket) || token_matches(tok, LeftArrowDash) then
        (edge, state1) = parse_edge_pattern(state)?
        (node, state2) = parse_node_pattern(state1)?
        parse_pattern_steps(state2, List.append(acc, { edge, node }))
    else
        Ok((acc, state))

## Parse one edge pattern.
##
## Outgoing / undirected (starts with `-[`):
##   DashBracket  [alias]  [: Type]  RBracket  (DashArrowRight | Dash)
##
## Incoming (starts with `<-`):
##   LeftArrowDash  LBracket  [alias]  [: Type]  RBracket  Dash
parse_edge_pattern : State -> Result (EdgePattern, State) ParseError
parse_edge_pattern = |state|
    tok = peek(state)
    if token_matches(tok, DashBracket) then
        parse_edge_outgoing_or_undirected(state)
    else if token_matches(tok, LeftArrowDash) then
        parse_edge_incoming(state)
    else
        Err({ message: "expected '-[' or '<-' to start edge pattern", position: state.pos, context: "edge pattern" })

## Parse `-[alias:Type]->` (Outgoing) or `-[alias:Type]-` (Undirected).
parse_edge_outgoing_or_undirected : State -> Result (EdgePattern, State) ParseError
parse_edge_outgoing_or_undirected = |state|
    # consume `-[`
    state1 = advance(state)

    # optional alias
    (alias, state2) =
        when peek(state1) is
            Ident(name) -> (Named(name), advance(state1))
            _ -> (Anon, state1)

    # optional `: Type`
    (edge_type, state3) = parse_edge_type(state2)?

    # expect `]`
    state4 = expect_kw(state3, RBracket, "expected ']' to close edge pattern")?

    # expect `->` or `-`
    when peek(state4) is
        DashArrowRight -> Ok(({ alias, edge_type, direction: Outgoing }, advance(state4)))
        Dash -> Ok(({ alias, edge_type, direction: Undirected }, advance(state4)))
        _ -> Err({ message: "expected '->' or '-' after edge pattern", position: state4.pos, context: "edge pattern" })

## Parse `<-[alias:Type]-` (Incoming).
parse_edge_incoming : State -> Result (EdgePattern, State) ParseError
parse_edge_incoming = |state|
    # consume `<-`
    state1 = advance(state)

    # expect `[`
    state2 = expect_kw(state1, LBracket, "expected '[' after '<-'")?

    # optional alias
    (alias, state3) =
        when peek(state2) is
            Ident(name) -> (Named(name), advance(state2))
            _ -> (Anon, state2)

    # optional `: Type`
    (edge_type, state4) = parse_edge_type(state3)?

    # expect `]`
    state5 = expect_kw(state4, RBracket, "expected ']' to close edge pattern")?

    # expect `-`
    state6 = expect_kw(state5, Dash, "expected '-' after ']' for incoming edge")?

    Ok(({ alias, edge_type, direction: Incoming }, state6))

## Parse an optional `: TypeName` for an edge pattern.
## Returns `(Typed name, state)` or `(Untyped, state)`.
parse_edge_type : State -> Result ([Typed Str, Untyped], State) ParseError
parse_edge_type = |state|
    when peek(state) is
        Colon ->
            state1 = advance(state)
            when peek(state1) is
                Ident(type_name) -> Ok((Typed(type_name), advance(state1)))
                _ -> Err({ message: "expected edge type name after ':'", position: state1.pos, context: "edge pattern" })

        _ -> Ok((Untyped, state))

## Parse an optional node label (`:Label` part).
## Returns `(Labeled name, state)` if a colon and ident follow, or `(Unlabeled, state)` otherwise.
parse_node_label : State -> Result ([Labeled Str, Unlabeled], State) ParseError
parse_node_label = |state|
    when peek(state) is
        Colon ->
            state1 = advance(state)
            when peek(state1) is
                Ident(lbl) -> Ok((Labeled(lbl), advance(state1)))
                _ -> Err({ message: "expected label name after ':'", position: state1.pos, context: "node pattern" })

        _ -> Ok((Unlabeled, state))

## Parse a node pattern: `(alias:Label {key: value, ...})`
parse_node_pattern : State -> Result (NodePattern, State) ParseError
parse_node_pattern = |state|
    # Expect opening paren
    state1 = expect_kw(state, LParen, "expected '(' for node pattern")?

    # Optional alias
    (alias, state2) =
        when peek(state1) is
            Ident(name) -> (Named(name), advance(state1))
            _ -> (Anon, state1)

    # Optional label
    (label, state3) = parse_node_label(state2)?

    # Optional property map
    (props, state4) =
        when peek(state3) is
            LBrace -> parse_prop_map(state3)?
            _ -> ([], state3)

    # Expect closing paren
    state5 = expect_kw(state4, RParen, "expected ')' to close node pattern")?

    Ok(({ alias, label, props }, state5))

## Parse a property map: `{key: value, ...}`
parse_prop_map : State -> Result (List { key : Str, value : QuineValue }, State) ParseError
parse_prop_map = |state|
    # Consume opening brace
    state1 = expect_kw(state, LBrace, "expected '{'")?
    parse_prop_map_entries(state1, [])

## Recursive helper to parse property map entries.
parse_prop_map_entries : State, List { key : Str, value : QuineValue } -> Result (List { key : Str, value : QuineValue }, State) ParseError
parse_prop_map_entries = |state, acc|
    # Check if we have hit the closing brace (empty map or trailing comma case)
    when peek(state) is
        RBrace ->
            state1 = advance(state)
            Ok((acc, state1))

        Ident(key) ->
            state1 = advance(state)
            # Expect colon
            state2 = expect_kw(state1, Colon, "expected ':' after property key")?
            # Parse value literal
            (value, state3) = parse_value_literal(state2)?
            entry = { key, value }
            new_acc = List.append(acc, entry)
            # Check for comma (continue) or closing brace (stop)
            when peek(state3) is
                Comma ->
                    state4 = advance(state3)
                    parse_prop_map_entries(state4, new_acc)

                RBrace ->
                    state4 = advance(state3)
                    Ok((new_acc, state4))

                _ ->
                    Err({ message: "expected ',' or '}' in property map", position: state3.pos, context: "property map" })

        _ ->
            Err({ message: "expected property key or '}'", position: state.pos, context: "property map" })

## Parse a single literal value.
parse_value_literal : State -> Result (QuineValue, State) ParseError
parse_value_literal = |state|
    tok = peek(state)
    when tok is
        LitStr(s) -> Ok((Str(s), advance(state)))
        LitInt(n) -> Ok((Integer(n), advance(state)))
        LitFloat(f) -> Ok((Floating(f), advance(state)))
        KwTrue -> Ok((True, advance(state)))
        KwFalse -> Ok((False, advance(state)))
        KwNull -> Ok((Null, advance(state)))
        _ -> Err({ message: "expected a literal value", position: state.pos, context: "value literal" })

## Parse an optional WHERE clause.
## If the next token is WHERE, consume it and parse an OR-level expression.
## Otherwise return NoWhere without consuming any tokens.
parse_optional_where : State -> Result ([Where Expr, NoWhere], State) ParseError
parse_optional_where = |state|
    if token_matches(peek(state), KwWhere) then
        state1 = advance(state)
        (expr, state2) = parse_or_expr(state1)?
        Ok((Where(expr), state2))
    else
        Ok((NoWhere, state))

## Parse an OR-level boolean expression (loosest binding).
## `a OR b OR c` → left-associative BoolOp chain.
parse_or_expr : State -> Result (Expr, State) ParseError
parse_or_expr = |state|
    (left, state1) = parse_and_expr(state)?
    parse_or_expr_rest(state1, left)

parse_or_expr_rest : State, Expr -> Result (Expr, State) ParseError
parse_or_expr_rest = |state, left|
    if token_matches(peek(state), KwOr) then
        state1 = advance(state)
        (right, state2) = parse_and_expr(state1)?
        combined = BoolOp({ left, op: Or, right })
        parse_or_expr_rest(state2, combined)
    else
        Ok((left, state))

## Parse an AND-level boolean expression.
## `a AND b AND c` → left-associative BoolOp chain.
parse_and_expr : State -> Result (Expr, State) ParseError
parse_and_expr = |state|
    (left, state1) = parse_comparison(state)?
    parse_and_expr_rest(state1, left)

parse_and_expr_rest : State, Expr -> Result (Expr, State) ParseError
parse_and_expr_rest = |state, left|
    if token_matches(peek(state), KwAnd) then
        state1 = advance(state)
        (right, state2) = parse_comparison(state1)?
        combined = BoolOp({ left, op: And, right })
        parse_and_expr_rest(state2, combined)
    else
        Ok((left, state))

## Parse a comparison or IS NULL / IS NOT NULL expression.
## Forms:
##   atom op value        → Comparison { left: atom, op, right: value }
##   atom IS NULL         → IsNull(atom)
##   atom IS NOT NULL     → Not(IsNull(atom))
##   atom                 → atom (no operator follows)
parse_comparison : State -> Result (Expr, State) ParseError
parse_comparison = |state|
    (atom, state1) = parse_atom(state)?
    tok = peek(state1)
    when tok is
        OpEq ->
            state2 = advance(state1)
            (right, state3) = parse_expr_value(state2)?
            Ok((Comparison({ left: atom, op: Eq, right }), state3))

        OpNeq ->
            state2 = advance(state1)
            (right, state3) = parse_expr_value(state2)?
            Ok((Comparison({ left: atom, op: Neq, right }), state3))

        OpLt ->
            state2 = advance(state1)
            (right, state3) = parse_expr_value(state2)?
            Ok((Comparison({ left: atom, op: Lt, right }), state3))

        OpGt ->
            state2 = advance(state1)
            (right, state3) = parse_expr_value(state2)?
            Ok((Comparison({ left: atom, op: Gt, right }), state3))

        OpLte ->
            state2 = advance(state1)
            (right, state3) = parse_expr_value(state2)?
            Ok((Comparison({ left: atom, op: Lte, right }), state3))

        OpGte ->
            state2 = advance(state1)
            (right, state3) = parse_expr_value(state2)?
            Ok((Comparison({ left: atom, op: Gte, right }), state3))

        KwIs ->
            # IS NULL or IS NOT NULL
            state2 = advance(state1)
            if token_matches(peek(state2), KwNot) then
                state3 = advance(state2)
                state4 = expect_kw(state3, KwNull, "expected NULL after IS NOT")?
                Ok((Not(IsNull(atom)), state4))
            else
                state3 = expect_kw(state2, KwNull, "expected NULL after IS")?
                Ok((IsNull(atom), state3))

        _ ->
            Ok((atom, state1))

## Parse an atomic predicate operand.
## Currently handles `alias.prop` → Property { expr: Variable(alias), key: prop }.
parse_atom : State -> Result (Expr, State) ParseError
parse_atom = |state|
    when peek(state) is
        Ident(alias) ->
            state1 = advance(state)
            when peek(state1) is
                Dot ->
                    state2 = advance(state1)
                    when peek(state2) is
                        Ident(prop) ->
                            state3 = advance(state2)
                            Ok((Property({ expr: Variable(alias), key: prop }), state3))

                        _ ->
                            Err({ message: "expected property name after '.'", position: state2.pos, context: "WHERE atom" })

                _ ->
                    Ok((Variable(alias), state1))

        _ ->
            Err({ message: "expected identifier in WHERE predicate", position: state.pos, context: "WHERE atom" })

## Parse a literal value on the RHS of a comparison.
## Produces an Expr (Literal wrapping a QuineValue).
parse_expr_value : State -> Result (Expr, State) ParseError
parse_expr_value = |state|
    tok = peek(state)
    when tok is
        LitStr(s) -> Ok((Literal(Str(s)), advance(state)))
        LitInt(n) -> Ok((Literal(Integer(n)), advance(state)))
        LitFloat(f) -> Ok((Literal(Floating(f)), advance(state)))
        KwTrue -> Ok((Literal(True), advance(state)))
        KwFalse -> Ok((Literal(False), advance(state)))
        KwNull -> Ok((Literal(Null), advance(state)))
        _ -> Err({ message: "expected a literal value in comparison", position: state.pos, context: "WHERE value" })

## Parse a comma-separated list of RETURN items.
parse_return_items : State -> Result (List ReturnItem, State) ParseError
parse_return_items = |state|
    (first, state1) = parse_return_item(state)?
    parse_return_items_rest(state1, [first])

## Recursive helper to parse additional comma-separated return items.
parse_return_items_rest : State, List ReturnItem -> Result (List ReturnItem, State) ParseError
parse_return_items_rest = |state, acc|
    when peek(state) is
        Comma ->
            state1 = advance(state)
            (item, state2) = parse_return_item(state1)?
            parse_return_items_rest(state2, List.append(acc, item))

        _ ->
            Ok((acc, state))

## Parse a single RETURN item.
## Forms:
##   n               →  WholeAlias "n"
##   n.prop          →  PropAccess { alias: "n", prop: "prop", rename_as: NoAs }
##   n.prop AS name  →  PropAccess { alias: "n", prop: "prop", rename_as: As "name" }
parse_return_item : State -> Result (ReturnItem, State) ParseError
parse_return_item = |state|
    when peek(state) is
        Ident(alias) ->
            state1 = advance(state)
            when peek(state1) is
                Dot ->
                    state2 = advance(state1)
                    when peek(state2) is
                        Ident(prop) ->
                            state3 = advance(state2)
                            # Check for optional AS rename
                            when peek(state3) is
                                KwAs ->
                                    state4 = advance(state3)
                                    when peek(state4) is
                                        Ident(rename) ->
                                            state5 = advance(state4)
                                            Ok((PropAccess({ alias, prop, rename_as: As(rename) }), state5))

                                        _ ->
                                            Err({ message: "expected identifier after AS", position: state4.pos, context: "RETURN item" })

                                _ ->
                                    Ok((PropAccess({ alias, prop, rename_as: NoAs }), state3))

                        _ ->
                            Err({ message: "expected property name after '.'", position: state2.pos, context: "RETURN item" })

                _ ->
                    Ok((WholeAlias(alias), state1))

        _ ->
            Err({ message: "expected identifier in RETURN item", position: state.pos, context: "RETURN item" })

## Parse a token list into a CypherQuery AST.
parse : List Token -> Result CypherQuery ParseError
parse = |tokens|
    state = { tokens, pos: 0 }
    state1 = expect_kw(state, KwMatch, "expected MATCH")?
    (pattern, state2) = parse_pattern(state1)?
    (where_, state3) = parse_optional_where(state2)?
    state4 = expect_kw(state3, KwReturn, "expected RETURN")?
    (return_items, state5) = parse_return_items(state4)?
    _ = expect_eof(state5)?
    Ok({ pattern, where_, return_items })

## Convenience: lex the input then parse.
parse_cypher : Str -> Result CypherQuery ParseError
parse_cypher = |input|
    when lex(input) is
        Ok(tokens) -> parse(tokens)
        Err(err) -> Err(err)

# ===== Tests =====

# MATCH (n) RETURN n
expect
    when parse_cypher("MATCH (n) RETURN n") is
        Ok(q) ->
            q.return_items == [WholeAlias("n")]
            && q.pattern.start.alias == Named("n")
            && q.pattern.start.label == Unlabeled
            && List.is_empty(q.pattern.steps)
            && (when q.where_ is
                NoWhere -> Bool.true
                _ -> Bool.false)
        _ -> Bool.false

# MATCH (n:Person) RETURN n
expect
    when parse_cypher("MATCH (n:Person) RETURN n") is
        Ok(q) ->
            q.return_items == [WholeAlias("n")]
            && q.pattern.start.alias == Named("n")
            && q.pattern.start.label == Labeled("Person")
            && List.is_empty(q.pattern.steps)
            && (when q.where_ is
                NoWhere -> Bool.true
                _ -> Bool.false)
        _ -> Bool.false

# MATCH (n {name: "Alice"}) RETURN n
expect
    when parse_cypher("MATCH (n {name: \"Alice\"}) RETURN n") is
        Ok(q) ->
            q.pattern.start.alias == Named("n")
            && q.pattern.start.label == Unlabeled
            && List.is_empty(q.pattern.steps)
            && List.len(q.pattern.start.props) == 1
        _ -> Bool.false

# MATCH (n:Person {age: 30}) RETURN n
expect
    when parse_cypher("MATCH (n:Person {age: 30}) RETURN n") is
        Ok(q) ->
            q.pattern.start.alias == Named("n")
            && q.pattern.start.label == Labeled("Person")
            && List.is_empty(q.pattern.steps)
            && List.len(q.pattern.start.props) == 1
        _ -> Bool.false

# RETURN with property access: MATCH (n) RETURN n.name, n.age
expect
    when parse_cypher("MATCH (n) RETURN n.name, n.age") is
        Ok(q) ->
            when q.return_items is
                [PropAccess(a), PropAccess(b)] ->
                    a.alias == "n" && a.prop == "name"
                    && b.alias == "n" && b.prop == "age"
                _ -> Bool.false
        _ -> Bool.false

# RETURN with AS: MATCH (n) RETURN n.name AS full_name
expect
    when parse_cypher("MATCH (n) RETURN n.name AS full_name") is
        Ok(q) ->
            when q.return_items is
                [PropAccess(a)] ->
                    a.alias == "n" && a.prop == "name" && a.rename_as == As("full_name")
                _ -> Bool.false
        _ -> Bool.false

# Anonymous node: MATCH () RETURN n
expect
    when parse_cypher("MATCH () RETURN n") is
        Ok(q) ->
            q.pattern.start.alias == Anon
            && q.pattern.start.label == Unlabeled
        _ -> Bool.false

# Error: missing MATCH keyword
expect
    when parse_cypher("(n) RETURN n") is
        Err(_) -> Bool.true
        _ -> Bool.false

# Error: missing RETURN keyword
expect
    when parse_cypher("MATCH (n)") is
        Err(_) -> Bool.true
        _ -> Bool.false

# Error: trailing tokens after query
expect
    when parse_cypher("MATCH (n) RETURN n extra") is
        Err(_) -> Bool.true
        _ -> Bool.false

# Single hop outgoing: MATCH (a)-[:KNOWS]->(b) RETURN a.name, b.name
expect
    when parse_cypher("MATCH (a)-[:KNOWS]->(b) RETURN a.name, b.name") is
        Ok(q) ->
            List.len(q.pattern.steps) == 1
            && q.pattern.start.alias == Named("a")
            && List.len(q.return_items) == 2
            && (when List.get(q.pattern.steps, 0) is
                Ok(step) ->
                    step.edge.edge_type == Typed("KNOWS")
                    && step.edge.direction == Outgoing
                    && step.node.alias == Named("b")
                _ -> Bool.false)
        _ -> Bool.false

# Incoming edge: MATCH (a)<-[:FOLLOWS]-(b) RETURN a, b
expect
    when parse_cypher("MATCH (a)<-[:FOLLOWS]-(b) RETURN a, b") is
        Ok(q) ->
            List.len(q.pattern.steps) == 1
            && (when List.get(q.pattern.steps, 0) is
                Ok(step) ->
                    step.edge.edge_type == Typed("FOLLOWS")
                    && step.edge.direction == Incoming
                _ -> Bool.false)
        _ -> Bool.false

# Multi-hop: MATCH (a)-[:KNOWS]->(b)-[:FOLLOWS]->(c) RETURN a.name, c.name
expect
    when parse_cypher("MATCH (a)-[:KNOWS]->(b)-[:FOLLOWS]->(c) RETURN a.name, c.name") is
        Ok(q) ->
            List.len(q.pattern.steps) == 2
        _ -> Bool.false

# Untyped edge: MATCH (a)-[]->(b) RETURN a, b
expect
    when parse_cypher("MATCH (a)-[]->(b) RETURN a, b") is
        Ok(q) ->
            when List.get(q.pattern.steps, 0) is
                Ok(step) ->
                    step.edge.edge_type == Untyped
                    && step.edge.direction == Outgoing
                _ -> Bool.false
        _ -> Bool.false

# Named edge: MATCH (a)-[r:KNOWS]->(b) RETURN a, b
expect
    when parse_cypher("MATCH (a)-[r:KNOWS]->(b) RETURN a, b") is
        Ok(q) ->
            when List.get(q.pattern.steps, 0) is
                Ok(step) ->
                    step.edge.alias == Named("r")
                    && step.edge.edge_type == Typed("KNOWS")
                    && step.edge.direction == Outgoing
                _ -> Bool.false
        _ -> Bool.false

# WHERE with simple equality comparison
expect
    when parse_cypher("MATCH (n) WHERE n.name = \"Alice\" RETURN n") is
        Ok(q) ->
            when q.where_ is
                Where(Comparison(c)) -> c.op == Eq
                _ -> Bool.false
        _ -> Bool.false

# WHERE with integer greater-than comparison
expect
    when parse_cypher("MATCH (n:Person) WHERE n.age > 25 RETURN n.name, n.age") is
        Ok(q) ->
            when q.where_ is
                Where(Comparison(c)) -> c.op == Gt
                _ -> Bool.false
        _ -> Bool.false

# WHERE with AND
expect
    when parse_cypher("MATCH (n) WHERE n.age > 25 AND n.name = \"Alice\" RETURN n") is
        Ok(q) ->
            when q.where_ is
                Where(BoolOp(b)) -> b.op == And
                _ -> Bool.false
        _ -> Bool.false

# WHERE with OR
expect
    when parse_cypher("MATCH (n) WHERE n.age < 18 OR n.age > 65 RETURN n") is
        Ok(q) ->
            when q.where_ is
                Where(BoolOp(b)) -> b.op == Or
                _ -> Bool.false
        _ -> Bool.false

# WHERE with IS NULL
expect
    when parse_cypher("MATCH (n) WHERE n.email IS NULL RETURN n") is
        Ok(q) ->
            when q.where_ is
                Where(IsNull(_)) -> Bool.true
                _ -> Bool.false
        _ -> Bool.false

# WHERE with IS NOT NULL
expect
    when parse_cypher("MATCH (n) WHERE n.email IS NOT NULL RETURN n") is
        Ok(q) ->
            when q.where_ is
                Where(Not(IsNull(_))) -> Bool.true
                _ -> Bool.false
        _ -> Bool.false

# Filtered traversal
expect
    when parse_cypher("MATCH (a)-[:KNOWS]->(b) WHERE a.name = \"Alice\" RETURN b") is
        Ok(q) ->
            is_comparison =
                when q.where_ is
                    Where(Comparison(_)) -> Bool.true
                    _ -> Bool.false
            is_single_return =
                q.return_items == [WholeAlias("b")]
            List.len(q.pattern.steps) == 1 && is_comparison && is_single_return
        _ -> Bool.false
