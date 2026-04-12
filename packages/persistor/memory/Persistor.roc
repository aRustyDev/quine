module [
    Persistor,
    Config,
    new,
    put_metadata,
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
