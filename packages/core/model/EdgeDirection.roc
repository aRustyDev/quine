module [
    EdgeDirection,
    reverse,
]

## The direction of a half-edge.
##
## Outgoing and Incoming reverse to each other; Undirected reverses to itself.
EdgeDirection : [Outgoing, Incoming, Undirected]

## Reverse a direction. Used to construct reciprocal half-edges.
reverse : EdgeDirection -> EdgeDirection
reverse = |dir|
    when dir is
        Outgoing -> Incoming
        Incoming -> Outgoing
        Undirected -> Undirected

# ===== Tests =====

expect reverse(Outgoing) == Incoming
expect reverse(Incoming) == Outgoing
expect reverse(Undirected) == Undirected

expect
    reverse(reverse(Outgoing)) == Outgoing

expect
    reverse(reverse(Incoming)) == Incoming

expect
    reverse(reverse(Undirected)) == Undirected
