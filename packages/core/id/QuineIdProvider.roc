module [
    QuineIdProvider,
    uuid_provider,
]

import QuineId exposing [QuineId]

## A pluggable ID scheme for graph nodes.
##
## QuineIdProvider is a record of functions (a manual vtable / type class) that
## abstracts over different ID generation strategies. Concrete providers implement
## the functions and pass the record around explicitly.
QuineIdProvider : {
    new_id : {} -> QuineId,
    from_bytes : List U8 -> Result QuineId [InvalidId Str],
    to_bytes : QuineId -> List U8,
    from_str : Str -> Result QuineId [InvalidId Str],
    to_str : QuineId -> Str,
    hashed_id : List U8 -> QuineId,
}

## A simple UUID-based provider.
##
## Phase 1 ships a deterministic stub: new_id always returns the empty QuineId,
## and hashed_id returns the input bytes wrapped as a QuineId. A real UUID v4
## generator requires platform support (random bytes) which Phase 1 does not have.
## Phase 2 will swap this for a real implementation.
uuid_provider : QuineIdProvider
uuid_provider = {
    new_id: |{}| QuineId.empty,
    from_bytes: |bytes| Ok(QuineId.from_bytes(bytes)),
    to_bytes: QuineId.to_bytes,
    from_str: |s|
        when QuineId.from_hex_str(s) is
            Ok(qid) -> Ok(qid)
            Err(_) -> Err(InvalidId("not valid hex")),
    to_str: QuineId.to_hex_str,
    hashed_id: |bytes| QuineId.from_bytes(bytes),
}

# ===== Tests =====

expect
    p = uuid_provider
    p.new_id({}) == QuineId.empty

expect
    p = uuid_provider
    bytes = [0xde, 0xad, 0xbe, 0xef]
    when p.from_bytes(bytes) is
        Ok(qid) -> p.to_bytes(qid) == bytes
        Err(_) -> Bool.false

expect
    p = uuid_provider
    qid = QuineId.from_bytes([0xab, 0xcd])
    s = p.to_str(qid)
    when p.from_str(s) is
        Ok(parsed) -> p.to_bytes(parsed) == [0xab, 0xcd]
        Err(_) -> Bool.false

expect
    p = uuid_provider
    when p.from_str("not hex") is
        Err(InvalidId(_)) -> Bool.true
        _ -> Bool.false

expect
    p = uuid_provider
    qid1 = p.hashed_id([1, 2, 3])
    qid2 = p.hashed_id([1, 2, 3])
    qid1 == qid2
