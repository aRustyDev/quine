module [lex]

import Token exposing [Token]
import Ast exposing [ParseError]

## Lex a Cypher input string into a list of tokens.
##
## Returns Ok(tokens) where the last element is always Eof,
## or Err(ParseError) if an unrecognized character or malformed literal
## is encountered.
lex : Str -> Result (List Token) ParseError
lex = |input|
    bytes = Str.to_utf8(input)
    lex_loop(bytes, 0, [])

## Main lexing loop: process bytes starting at `pos`, accumulating tokens.
lex_loop : List U8, U64, List Token -> Result (List Token) ParseError
lex_loop = |bytes, pos, acc|
    when List.get(bytes, pos) is
        Err(OutOfBounds) ->
            # End of input
            Ok(List.append(acc, Eof))

        Ok(byte) ->
            if is_whitespace(byte) then
                lex_loop(bytes, pos + 1, acc)
            else if byte == '(' then
                lex_loop(bytes, pos + 1, List.append(acc, LParen))
            else if byte == ')' then
                lex_loop(bytes, pos + 1, List.append(acc, RParen))
            else if byte == '{' then
                lex_loop(bytes, pos + 1, List.append(acc, LBrace))
            else if byte == '}' then
                lex_loop(bytes, pos + 1, List.append(acc, RBrace))
            else if byte == '[' then
                lex_loop(bytes, pos + 1, List.append(acc, LBracket))
            else if byte == ']' then
                lex_loop(bytes, pos + 1, List.append(acc, RBracket))
            else if byte == ':' then
                lex_loop(bytes, pos + 1, List.append(acc, Colon))
            else if byte == ',' then
                lex_loop(bytes, pos + 1, List.append(acc, Comma))
            else if byte == '.' then
                # Could be part of a float, but standalone '.' is Dot
                # (floats are handled in the digit branch)
                lex_loop(bytes, pos + 1, List.append(acc, Dot))
            else if byte == '=' then
                lex_loop(bytes, pos + 1, List.append(acc, OpEq))
            else if byte == '<' then
                lex_lt(bytes, pos, acc)
            else if byte == '>' then
                lex_gt(bytes, pos, acc)
            else if byte == '-' then
                lex_dash(bytes, pos, acc)
            else if byte == '"' then
                lex_string(bytes, pos + 1, [], acc)
            else if is_digit(byte) then
                lex_number(bytes, pos, acc)
            else if is_alpha_or_underscore(byte) then
                lex_ident(bytes, pos, acc)
            else
                # Unrecognized character
                Err({
                    message: "Unexpected character",
                    position: pos,
                    context: "lexer",
                })

## Handle '<': could be '<>', '<=', '<-', or just '<'.
lex_lt : List U8, U64, List Token -> Result (List Token) ParseError
lex_lt = |bytes, pos, acc|
    when List.get(bytes, pos + 1) is
        Ok(next) if next == '>' ->
            lex_loop(bytes, pos + 2, List.append(acc, OpNeq))

        Ok(next) if next == '=' ->
            lex_loop(bytes, pos + 2, List.append(acc, OpLte))

        Ok(next) if next == '-' ->
            lex_loop(bytes, pos + 2, List.append(acc, LeftArrowDash))

        _ ->
            lex_loop(bytes, pos + 1, List.append(acc, OpLt))

## Handle '>': could be '>=' or just '>'.
lex_gt : List U8, U64, List Token -> Result (List Token) ParseError
lex_gt = |bytes, pos, acc|
    when List.get(bytes, pos + 1) is
        Ok(next) if next == '=' ->
            lex_loop(bytes, pos + 2, List.append(acc, OpGte))

        _ ->
            lex_loop(bytes, pos + 1, List.append(acc, OpGt))

## Handle '-': could be '-[', '->', or a negative number, or standalone '-'.
##
## Negative number heuristic: '-' is a negative sign only if the last token
## is NOT an identifier, RParen, or RBracket (i.e., not the end of an expression).
lex_dash : List U8, U64, List Token -> Result (List Token) ParseError
lex_dash = |bytes, pos, acc|
    when List.get(bytes, pos + 1) is
        Ok(next) if next == '[' ->
            lex_loop(bytes, pos + 2, List.append(acc, DashBracket))

        Ok(next) if next == '>' ->
            lex_loop(bytes, pos + 2, List.append(acc, DashArrowRight))

        Ok(next) if is_digit(next) ->
            # Negative number only if not after expression-ending token
            if is_after_expression(acc) then
                lex_loop(bytes, pos + 1, List.append(acc, Dash))
            else
                lex_number(bytes, pos, acc)

        _ ->
            lex_loop(bytes, pos + 1, List.append(acc, Dash))

## Returns true if the last token in the accumulator means '-' is a binary operator.
is_after_expression : List Token -> Bool
is_after_expression = |acc|
    when List.last(acc) is
        Ok(Ident(_)) -> Bool.true
        Ok(RParen) -> Bool.true
        Ok(RBracket) -> Bool.true
        Ok(LitInt(_)) -> Bool.true
        Ok(LitFloat(_)) -> Bool.true
        Ok(LitStr(_)) -> Bool.true
        _ -> Bool.false

## Lex a double-quoted string literal, collecting bytes until closing '"'.
## Handles '\"' escape sequences.
lex_string : List U8, U64, List U8, List Token -> Result (List Token) ParseError
lex_string = |bytes, pos, collected, acc|
    when List.get(bytes, pos) is
        Err(OutOfBounds) ->
            Err({
                message: "Unterminated string literal",
                position: pos,
                context: "string literal",
            })

        Ok(byte) ->
            if byte == '"' then
                # Closing quote — convert collected bytes to Str
                when Str.from_utf8(collected) is
                    Ok(s) ->
                        lex_loop(bytes, pos + 1, List.append(acc, LitStr(s)))

                    Err(_) ->
                        Err({
                            message: "Invalid UTF-8 in string literal",
                            position: pos,
                            context: "string literal",
                        })
            else if byte == '\\' then
                # Escape sequence: peek at next byte
                when List.get(bytes, pos + 1) is
                    Ok(escaped) if escaped == '"' ->
                        lex_string(bytes, pos + 2, List.append(collected, '"'), acc)

                    Ok(escaped) if escaped == '\\' ->
                        lex_string(bytes, pos + 2, List.append(collected, '\\'), acc)

                    Ok(escaped) if escaped == 'n' ->
                        lex_string(bytes, pos + 2, List.append(collected, '\n'), acc)

                    Ok(escaped) if escaped == 't' ->
                        lex_string(bytes, pos + 2, List.append(collected, '\t'), acc)

                    _ ->
                        # Unknown escape — include the backslash and move on
                        lex_string(bytes, pos + 1, List.append(collected, byte), acc)
            else
                lex_string(bytes, pos + 1, List.append(collected, byte), acc)

## Lex a numeric literal (integer or float), handling optional leading '-'.
##
## Collects digit bytes; if a '.' followed by a digit is found, lex as float.
## The num_bytes slice always starts at `pos` (including any leading '-'),
## so Str.to_i64 / Str.to_f64 see the sign naturally.
lex_number : List U8, U64, List Token -> Result (List Token) ParseError
lex_number = |bytes, pos, acc|
    # Skip optional leading minus before scanning digits
    digit_start =
        when List.get(bytes, pos) is
            Ok(byte) if byte == '-' -> pos + 1
            _ -> pos

    # Collect integer digits
    int_end = scan_digits(bytes, digit_start)

    # Check for decimal point followed by digit
    has_decimal =
        when (List.get(bytes, int_end), List.get(bytes, int_end + 1)) is
            (Ok(dot), Ok(next_digit)) if dot == '.' && is_digit(next_digit) -> Bool.true
            _ -> Bool.false

    if has_decimal then
        frac_end = scan_digits(bytes, int_end + 1)
        num_bytes = List.sublist(bytes, { start: pos, len: frac_end - pos })
        when Str.from_utf8(num_bytes) is
            Ok(num_str) ->
                when Str.to_f64(num_str) is
                    Ok(f) ->
                        lex_loop(bytes, frac_end, List.append(acc, LitFloat(f)))

                    Err(_) ->
                        Err({
                            message: "Invalid float literal",
                            position: pos,
                            context: "float literal",
                        })

            Err(_) ->
                Err({
                    message: "Invalid float literal encoding",
                    position: pos,
                    context: "float literal",
                })
    else
        num_bytes = List.sublist(bytes, { start: pos, len: int_end - pos })
        when Str.from_utf8(num_bytes) is
            Ok(num_str) ->
                when Str.to_i64(num_str) is
                    Ok(n) ->
                        # Sign is already encoded in num_str (Str.to_i64 handles '-' prefix)
                        lex_loop(bytes, int_end, List.append(acc, LitInt(n)))

                    Err(_) ->
                        Err({
                            message: "Invalid integer literal",
                            position: pos,
                            context: "integer literal",
                        })

            Err(_) ->
                Err({
                    message: "Invalid integer literal encoding",
                    position: pos,
                    context: "integer literal",
                })

## Scan forward as long as bytes are ASCII digits; return the end position.
scan_digits : List U8, U64 -> U64
scan_digits = |bytes, pos|
    when List.get(bytes, pos) is
        Ok(byte) if is_digit(byte) -> scan_digits(bytes, pos + 1)
        _ -> pos

## Lex an identifier or keyword.
##
## Collects letters, digits, and underscores; lowercases the result,
## then checks the keyword table.
lex_ident : List U8, U64, List Token -> Result (List Token) ParseError
lex_ident = |bytes, pos, acc|
    end = scan_ident(bytes, pos)
    ident_bytes = List.sublist(bytes, { start: pos, len: end - pos })
    when Str.from_utf8(ident_bytes) is
        Ok(raw) ->
            lower = Str.to_utf8(raw)
                |> List.map(to_lower_byte)
                |> Str.from_utf8
                |> Result.with_default(raw)
            token = keyword_or_ident(lower)
            lex_loop(bytes, end, List.append(acc, token))

        Err(_) ->
            Err({
                message: "Invalid UTF-8 in identifier",
                position: pos,
                context: "identifier",
            })

## Scan forward while the byte is a valid identifier continuation (letter, digit, underscore).
scan_ident : List U8, U64 -> U64
scan_ident = |bytes, pos|
    when List.get(bytes, pos) is
        Ok(byte) if is_ident_continue(byte) -> scan_ident(bytes, pos + 1)
        _ -> pos

## Map a keyword string to its token, or return Ident if not a keyword.
keyword_or_ident : Str -> Token
keyword_or_ident = |s|
    when s is
        "match" -> KwMatch
        "where" -> KwWhere
        "return" -> KwReturn
        "and" -> KwAnd
        "or" -> KwOr
        "is" -> KwIs
        "not" -> KwNot
        "null" -> KwNull
        "as" -> KwAs
        "true" -> KwTrue
        "false" -> KwFalse
        _ -> Ident(s)

# ===== Character classification helpers =====

is_whitespace : U8 -> Bool
is_whitespace = |b|
    b == ' ' || b == '\t' || b == '\n' || b == '\r'

is_digit : U8 -> Bool
is_digit = |b|
    b >= '0' && b <= '9'

is_alpha : U8 -> Bool
is_alpha = |b|
    (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')

is_alpha_or_underscore : U8 -> Bool
is_alpha_or_underscore = |b|
    is_alpha(b) || b == '_'

is_ident_continue : U8 -> Bool
is_ident_continue = |b|
    is_alpha(b) || is_digit(b) || b == '_'

## Convert an ASCII byte to lowercase.
to_lower_byte : U8 -> U8
to_lower_byte = |b|
    if b >= 'A' && b <= 'Z' then
        b + 32u8
    else
        b

# ===== Tests =====
#
# Note: Token contains LitFloat F64, which does not implement Eq in Roc.
# Therefore all tests use `when ... is` pattern matching rather than `==`.

# Empty input → just Eof
expect
    when lex("") is
        Ok([Eof]) -> Bool.true
        _ -> Bool.false

# Whitespace only → just Eof
expect
    when lex("   \n\t ") is
        Ok([Eof]) -> Bool.true
        _ -> Bool.false

# Single keyword (case insensitive)
expect
    when lex("MATCH") is
        Ok([KwMatch, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("match") is
        Ok([KwMatch, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("Match") is
        Ok([KwMatch, Eof]) -> Bool.true
        _ -> Bool.false

# Single-char delimiters
expect
    when lex("()") is
        Ok([LParen, RParen, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("{}") is
        Ok([LBrace, RBrace, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex(":,.") is
        Ok([Colon, Comma, Dot, Eof]) -> Bool.true
        _ -> Bool.false

# Comparison operators
expect
    when lex("= <> < > <= >=") is
        Ok([OpEq, OpNeq, OpLt, OpGt, OpLte, OpGte, Eof]) -> Bool.true
        _ -> Bool.false

# Integer literal
expect
    when lex("42") is
        Ok([LitInt(42), Eof]) -> Bool.true
        _ -> Bool.false

# Float literal — compare value directly since we can't use == on lists with F64
expect
    when lex("3.14") is
        Ok([LitFloat(f), Eof]) -> Num.is_approx_eq(f, 3.14f64, { rtol: 1e-10, atol: 0.0 })
        _ -> Bool.false

# String literal
expect
    when lex("\"hello\"") is
        Ok([LitStr("hello"), Eof]) -> Bool.true
        _ -> Bool.false

# Identifier
expect
    when lex("n") is
        Ok([Ident("n"), Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("node_1") is
        Ok([Ident("node_1"), Eof]) -> Bool.true
        _ -> Bool.false

# Additional keyword tests
expect
    when lex("WHERE") is
        Ok([KwWhere, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("RETURN") is
        Ok([KwReturn, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("AND") is
        Ok([KwAnd, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("OR") is
        Ok([KwOr, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("NULL") is
        Ok([KwNull, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("true") is
        Ok([KwTrue, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("false") is
        Ok([KwFalse, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("AS") is
        Ok([KwAs, Eof]) -> Bool.true
        _ -> Bool.false

# Edge arrow tokens
expect
    when lex("->") is
        Ok([DashArrowRight, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("<-") is
        Ok([LeftArrowDash, Eof]) -> Bool.true
        _ -> Bool.false

expect
    when lex("-[") is
        Ok([DashBracket, Eof]) -> Bool.true
        _ -> Bool.false

# Standalone dash
expect
    when lex("-") is
        Ok([Dash, Eof]) -> Bool.true
        _ -> Bool.false

# Brackets
expect
    when lex("[]") is
        Ok([LBracket, RBracket, Eof]) -> Bool.true
        _ -> Bool.false

# Negative number: '-' after operator is negative sign
expect
    when lex("=-42") is
        Ok([OpEq, LitInt(-42), Eof]) -> Bool.true
        _ -> Bool.false

# '-' after ident is Dash (binary minus)
expect
    when lex("n-1") is
        Ok([Ident("n"), Dash, LitInt(1), Eof]) -> Bool.true
        _ -> Bool.false

# String with escape
expect
    when lex("\"he\\\"llo\"") is
        Ok([LitStr("he\"llo"), Eof]) -> Bool.true
        _ -> Bool.false

# Simple Cypher fragment
expect
    when lex("MATCH (n)") is
        Ok([KwMatch, LParen, Ident("n"), RParen, Eof]) -> Bool.true
        _ -> Bool.false
