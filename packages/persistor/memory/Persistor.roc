module [
    Persistor,
    Config,
    new,
    put_metadata,
    get_metadata,
]

import id.QuineId exposing [QuineId]
import id.EventTime exposing [EventTime]
import model.PropertyValue
import model.HalfEdge
import model.NodeEvent exposing [TimestampedEvent]
import model.NodeSnapshot exposing [NodeSnapshot]

## Opaque in-memory persistor backend.
##
## Holds three independent stores: an append-only event journal, a
## replaceable-per-key snapshot store, and a flat metadata key-value store.
## All state is threaded through operations — callers receive a new
## `Persistor` from every mutating operation and pass it to subsequent calls.
##
## Roc's refcount-1 optimization means these operations mutate the underlying
## Dicts in place at runtime, so performance matches a mutable implementation
## despite the pure-functional API.
Persistor := {
    events : Dict QuineId (Dict EventTime (List TimestampedEvent)),
    snapshots : Dict QuineId (Dict EventTime NodeSnapshot),
    metadata : Dict Str (List U8),
}

## Configuration options for the in-memory persistor.
##
## Empty for Phase 2 — exists as a placeholder for future backends that will
## need backend-specific options (RocksDB path, Cassandra contact points, etc.)
## This keeps the constructor signature consistent across backends.
Config : {}

## Create a new, empty in-memory persistor.
new : Config -> Persistor
new = |_config|
    @Persistor({
        events: Dict.empty({}),
        snapshots: Dict.empty({}),
        metadata: Dict.empty({}),
    })

## Store an opaque byte value under a metadata key.
##
## Overwrites any existing value at the key (last-write-wins semantics).
put_metadata :
    Persistor,
    Str,
    List U8
    -> Result Persistor [Unavailable, Timeout]
put_metadata = |@Persistor(state), key, value|
    new_metadata = Dict.insert(state.metadata, key, value)
    Ok(@Persistor({ state & metadata: new_metadata }))

## Retrieve an opaque byte value for a metadata key.
##
## Returns `Err NotFound` if no value is stored at the key.
get_metadata :
    Persistor,
    Str
    -> Result (List U8) [NotFound, Unavailable, Timeout]
get_metadata = |@Persistor(state), key|
    when Dict.get(state.metadata, key) is
        Ok(value) -> Ok(value)
        Err(_) -> Err(NotFound)

# ===== Tests =====

expect
    # new produces an opaque Persistor
    p = new({})
    when p is
        @Persistor(_) -> Bool.true

expect
    # put_metadata stores a value at a key
    p = new({})
    when put_metadata(p, "version", [0x01, 0x02]) is
        Ok(@Persistor(state)) ->
            Dict.get(state.metadata, "version") == Ok([0x01, 0x02])
        Err(_) -> Bool.false

expect
    # get_metadata returns Ok for a stored key
    p = new({})
    when put_metadata(p, "k", [0xAA]) is
        Ok(p2) ->
            when get_metadata(p2, "k") is
                Ok([0xAA]) -> Bool.true
                _ -> Bool.false
        Err(_) -> Bool.false

expect
    # get_metadata returns Err NotFound for a missing key
    p = new({})
    when get_metadata(p, "missing") is
        Err(NotFound) -> Bool.true
        _ -> Bool.false
