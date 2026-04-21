hosted [send_to_shard!, persist_async!, current_time!, log!, emit_sq_result!]

## Send a message to a shard's input channel.
## Returns 0 on success, 1 if the channel is full.
send_to_shard! : U32, List U8 => U8

## Dispatch an async persistence command.
## Returns a request ID that will arrive later as a PersistenceResult message.
persist_async! : List U8 => U64

## Get the current wall-clock time in milliseconds since epoch.
current_time! : {} => U64

## Emit a log message.
## Levels: 0=error, 1=warn, 2=info, 3=debug
log! : U8, Str => {}

## Emit a standing query result to the host for delivery to consumers.
## Encodes query_id as U128 (16 bytes LE) + is_positive_match (1 byte) + data payload.
## Returns 0 on success, 1 if the result buffer is full (backpressure).
emit_sq_result! : List U8 => U8
