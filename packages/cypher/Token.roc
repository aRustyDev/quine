module [
    Token,
    to_str,
]

## A Cypher lexical token.
##
## Keywords are case-insensitive (lexer normalizes to lowercase before matching).
## Edge arrow tokens are multi-character: the lexer assembles `-[`, `->`, `<-`
## from individual characters so the parser can match on single tokens for direction.
Token : [
    # Keywords
    KwMatch, KwWhere, KwReturn, KwAnd, KwOr,
    KwIs, KwNot, KwNull, KwAs, KwTrue, KwFalse,
    # Delimiters
    LParen, RParen, LBracket, RBracket, LBrace, RBrace,
    Colon, Comma, Dot,
    # Edge patterns (multi-char)
    DashBracket,      # -[
    DashArrowRight,   # ->
    LeftArrowDash,    # <-
    Dash,             # - (standalone)
    # Comparison operators
    OpEq, OpNeq, OpLt, OpGt, OpLte, OpGte,
    # Literals
    LitStr Str, LitInt I64, LitFloat F64,
    # Identifier
    Ident Str,
    # End of input
    Eof,
]

## Debug display for a token (used in error messages).
to_str : Token -> Str
to_str = |token|
    when token is
        KwMatch -> "MATCH"
        KwWhere -> "WHERE"
        KwReturn -> "RETURN"
        KwAnd -> "AND"
        KwOr -> "OR"
        KwIs -> "IS"
        KwNot -> "NOT"
        KwNull -> "NULL"
        KwAs -> "AS"
        KwTrue -> "TRUE"
        KwFalse -> "FALSE"
        LParen -> "("
        RParen -> ")"
        LBracket -> "["
        RBracket -> "]"
        LBrace -> "{"
        RBrace -> "}"
        Colon -> ":"
        Comma -> ","
        Dot -> "."
        DashBracket -> "-["
        DashArrowRight -> "->"
        LeftArrowDash -> "<-"
        Dash -> "-"
        OpEq -> "="
        OpNeq -> "<>"
        OpLt -> "<"
        OpGt -> ">"
        OpLte -> "<="
        OpGte -> ">="
        LitStr(s) -> "\"$(s)\""
        LitInt(n) -> Num.to_str(n)
        LitFloat(f) -> Num.to_str(f)
        Ident(s) -> s
        Eof -> "<EOF>"

# ===== Tests =====

expect to_str(KwMatch) == "MATCH"
expect to_str(OpNeq) == "<>"
expect to_str(LitStr("hello")) == "\"hello\""
expect to_str(Ident("n")) == "n"
expect to_str(Eof) == "<EOF>"
