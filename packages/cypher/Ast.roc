module [
    CypherQuery,
    Pattern,
    NodePattern,
    EdgePattern,
    ReturnItem,
    ParseError,
    anon_node,
    anon_edge,
]

import expr.Expr exposing [Expr]
import model.QuineValue exposing [QuineValue]

## A parsed read-only Cypher query: MATCH pattern WHERE predicate RETURN items.
CypherQuery : {
    pattern : Pattern,
    where_ : [Where Expr, NoWhere],
    return_items : List ReturnItem,
}

## A graph pattern: a start node followed by zero or more (edge, node) steps.
##
## `MATCH (a)-[:KNOWS]->(b)-[:FOLLOWS]->(c)` becomes:
## `{ start: a, steps: [{ edge: KNOWS>, node: b }, { edge: FOLLOWS>, node: c }] }`
Pattern : {
    start : NodePattern,
    steps : List { edge : EdgePattern, node : NodePattern },
}

## A node pattern: `(alias:Label {key: value, ...})`
##
## All parts are optional: `()` is a valid anonymous unlabeled node.
NodePattern : {
    alias : [Named Str, Anon],
    label : [Labeled Str, Unlabeled],
    props : List { key : Str, value : QuineValue },
}

## An edge pattern: `-[alias:TYPE]->` or `<-[alias:TYPE]-` or `-[alias:TYPE]-`
EdgePattern : {
    alias : [Named Str, Anon],
    edge_type : [Typed Str, Untyped],
    direction : [Outgoing, Incoming, Undirected],
}

## A RETURN clause item.
ReturnItem : [
    WholeAlias Str,
    PropAccess { alias : Str, prop : Str, rename_as : [As Str, NoAs] },
]

## A parse error with position information.
ParseError : {
    message : Str,
    position : U64,
    context : Str,
}

## Convenience: anonymous unlabeled node with no properties.
anon_node : NodePattern
anon_node = { alias: Anon, label: Unlabeled, props: [] }

## Convenience: anonymous untyped undirected edge.
anon_edge : EdgePattern
anon_edge = { alias: Anon, edge_type: Untyped, direction: Undirected }

# ===== Tests =====

# anon_node has expected shape
expect anon_node.alias == Anon
expect anon_node.label == Unlabeled
expect List.is_empty(anon_node.props)

# anon_edge has expected shape
expect anon_edge.alias == Anon
expect anon_edge.edge_type == Untyped
expect anon_edge.direction == Undirected
