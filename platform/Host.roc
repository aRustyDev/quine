hosted [send_to_shard!, current_time!, log!]

## Send a message to a shard's input channel.
## Returns 0 on success, 1 if the channel is full.
send_to_shard! : U32, List U8 => U8

## Get the current wall-clock time in milliseconds since epoch.
current_time! : {} => U64

## Emit a log message.
## Levels: 0=error, 1=warn, 2=info, 3=debug
log! : U8, Str => {}
