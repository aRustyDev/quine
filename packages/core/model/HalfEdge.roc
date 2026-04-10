module [
    HalfEdge,
    reflect,
]

import id.QuineId exposing [QuineId]
import EdgeDirection exposing [EdgeDirection]

## One side of an edge in the graph.
##
## An edge between nodes A and B exists if and only if A holds a half-edge pointing
## at B AND B holds the reciprocal half-edge pointing at A. This design lets each
## node store only its own half of every edge — no global edge table is needed.
HalfEdge : {
    edge_type : Str,
    direction : EdgeDirection,
    other : QuineId,
}

## Compute the reciprocal half-edge for the other endpoint.
##
## Given a half-edge stored on `this_node`, returns the half-edge that the
## remote endpoint should store. Direction is reversed; the `other` field
## becomes `this_node`.
##
## Example: if A has HalfEdge(:KNOWS, Outgoing, B), then reflect(this, A) on
## that half-edge yields HalfEdge(:KNOWS, Incoming, A) — which B should hold.
reflect : HalfEdge, QuineId -> HalfEdge
reflect = |edge, this_node|
    {
        edge_type: edge.edge_type,
        direction: EdgeDirection.reverse(edge.direction),
        other: this_node,
    }

# ===== Tests =====

expect
    a_id = QuineId.from_bytes([0x0A])
    b_id = QuineId.from_bytes([0x0B])
    edge_on_a = { edge_type: "KNOWS", direction: Outgoing, other: b_id }
    edge_on_b = reflect(edge_on_a, a_id)
    edge_on_b.edge_type == "KNOWS"
        and edge_on_b.direction == Incoming
        and edge_on_b.other == a_id

expect
    a_id = QuineId.from_bytes([0x0A])
    b_id = QuineId.from_bytes([0x0B])
    edge = { edge_type: "FOLLOWS", direction: Incoming, other: b_id }
    reflected = reflect(edge, a_id)
    reflected.direction == Outgoing

expect
    a_id = QuineId.from_bytes([0x0A])
    b_id = QuineId.from_bytes([0x0B])
    edge = { edge_type: "PEER", direction: Undirected, other: b_id }
    reflected = reflect(edge, a_id)
    reflected.direction == Undirected

expect
    a_id = QuineId.from_bytes([0x0A])
    b_id = QuineId.from_bytes([0x0B])
    edge_on_a = { edge_type: "REL", direction: Outgoing, other: b_id }
    edge_on_b = reflect(edge_on_a, a_id)
    back_to_a = reflect(edge_on_b, b_id)
    back_to_a == edge_on_a
