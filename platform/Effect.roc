## Public effect API for apps running on the quine-graph platform.
## Apps import this module to call host-provided functions.
module [send_to_shard!, persist_async!, current_time!, log!, emit_sq_result!, reply!, shard_count!]

import Host

## Send a message to a shard's input channel.
## Returns Err ChannelFull if the channel is at capacity.
send_to_shard! : U32, List U8 => Result {} [ChannelFull]
send_to_shard! = |shard_id, msg|
    result = Host.send_to_shard!(shard_id, msg)
    if result == 0 then
        Ok({})
    else
        Err(ChannelFull)

## Dispatch an async persistence command.
## Returns a request ID that will arrive later as a PersistenceResult
## message to the calling shard's handle_message!.
persist_async! : List U8 => U64
persist_async! = |cmd|
    Host.persist_async!(cmd)

## Get the current wall-clock time in milliseconds since epoch.
current_time! : {} => U64
current_time! = |{}|
    Host.current_time!({})

## Emit a structured log message.
## Levels: 0=error, 1=warn, 2=info, 3=debug
log! : U8, Str => {}
log! = |level, msg|
    Host.log!(level, msg)

## Emit a standing query result to the host.
## Returns Err SqBufferFull if the host's result buffer is at capacity.
emit_sq_result! : List U8 => Result {} [SqBufferFull]
emit_sq_result! = |payload|
    result = Host.emit_sq_result!(payload)
    if result == 0 then
        Ok({})
    else
        Err(SqBufferFull)

## Send a reply to a pending request (node query response).
## The host routes the payload back to the waiting HTTP handler.
reply! : U64, List U8 => {}
reply! = |request_id, payload|
    Host.reply!(request_id, payload)

## Query the total number of shards configured for this platform instance.
shard_count! : {} => U32
shard_count! = |{}|
    Host.shard_count!({})
