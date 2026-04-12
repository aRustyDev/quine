module [
    NetworkError,
    SerializationError,
]

## Forward-looking network-ish error variants.
##
## These errors appear in every public Persistor operation's error tag union
## but are never produced by the in-memory backend. Including them from day
## one forces callers to handle them, so future distributed backends can slot
## in without breaking the API. See ADR-013.
NetworkError : [
    Unavailable,
    Timeout,
    NotLeader,
]

## Errors that arise when encoding or decoding values.
##
## `Str` field carries a human-readable description of the failure.
SerializationError : [
    SerializeError Str,
    DeserializeError Str,
]

# ===== Tests =====

expect
    # NetworkError variants are constructible
    e : NetworkError
    e = Unavailable
    when e is
        Unavailable -> Bool.true
        _ -> Bool.false

expect
    # SerializationError variants are constructible
    e : SerializationError
    e = DeserializeError("bad utf-8")
    when e is
        DeserializeError(_) -> Bool.true
        _ -> Bool.false
