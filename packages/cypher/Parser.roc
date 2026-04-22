module [
    parse,
    parse_cypher,
]

import Token exposing [Token]
import Ast exposing [CypherQuery, Pattern, NodePattern, ReturnItem, ParseError]
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

## Parse a graph pattern.
## For now only parses the start node (no edge steps yet — Task 6).
parse_pattern : State -> Result (Pattern, State) ParseError
parse_pattern = |state|
    (node, state1) = parse_node_pattern(state)?
    Ok(({ start: node, steps: [] }, state1))

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
## For now always returns NoWhere (WHERE parsing is Task 7).
parse_optional_where : State -> Result ([Where Expr, NoWhere], State) ParseError
parse_optional_where = |state|
    Ok((NoWhere, state))

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
