## Public effect API for apps running on the quine-graph platform.
## Apps import this module to call host-provided functions.
module [send_to_shard!, current_time!, log!]

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

## Get the current wall-clock time in milliseconds since epoch.
current_time! : {} => U64
current_time! = |{}|
    Host.current_time!({})

## Emit a structured log message.
## Levels: 0=error, 1=warn, 2=info, 3=debug
log! : U8, Str => {}
log! = |level, msg|
    Host.log!(level, msg)
