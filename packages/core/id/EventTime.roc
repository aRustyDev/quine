module [
    EventTime,
    from_parts,
    millis,
    message_seq,
    event_seq,
    min_value,
    max_value,
    advance_event,
]

## A high-resolution timestamp for graph events.
##
## Packed into a single U64:
## - Top 42 bits: wall-clock milliseconds since epoch
## - Middle 14 bits: message sequence (disambiguates events in the same ms from different messages)
## - Bottom 8 bits: event sequence (disambiguates events from the same message)
##
## This packing gives every event a globally unique, totally-ordered timestamp.
EventTime := U64 implements [Eq { is_eq: is_eq }, Hash]

is_eq : EventTime, EventTime -> Bool
is_eq = |@EventTime(a), @EventTime(b)| a == b

## Bit layout constants
millis_shift : U8
millis_shift = 22

message_seq_shift : U8
message_seq_shift = 8

# 14 bits
message_seq_mask : U64
message_seq_mask = 0x3FFF

# 8 bits
event_seq_mask : U64
event_seq_mask = 0xFF

# 42 bits
millis_max : U64
millis_max = 0x3FFFFFFFFFF

## Construct an EventTime from its three components.
##
## Values are masked to fit their bit-widths; out-of-range inputs are silently truncated.
from_parts : { millis : U64, message_seq : U16, event_seq : U8 } -> EventTime
from_parts = |{ millis: m, message_seq: msg, event_seq: ev }|
    m_bits = Num.bitwise_and(m, millis_max) |> Num.shift_left_by(millis_shift)
    msg_bits = Num.bitwise_and(Num.to_u64(msg), message_seq_mask) |> Num.shift_left_by(message_seq_shift)
    ev_bits = Num.to_u64(ev)
    @EventTime(Num.bitwise_or(m_bits, Num.bitwise_or(msg_bits, ev_bits)))

## Extract the milliseconds-since-epoch component.
millis : EventTime -> U64
millis = |@EventTime(packed)|
    Num.shift_right_zf_by(packed, millis_shift)

## Extract the message sequence component.
message_seq : EventTime -> U16
message_seq = |@EventTime(packed)|
    Num.shift_right_zf_by(packed, message_seq_shift)
    |> Num.bitwise_and(message_seq_mask)
    |> Num.to_u16

## Extract the event sequence component.
event_seq : EventTime -> U8
event_seq = |@EventTime(packed)|
    Num.bitwise_and(packed, event_seq_mask) |> Num.to_u8

## The smallest possible EventTime (all zeros).
min_value : EventTime
min_value = @EventTime(0)

## The largest possible EventTime (all bits set).
max_value : EventTime
max_value = @EventTime(Num.max_u64)

## Increment the event sequence by one. If at maximum, wraps to zero.
##
## Note: this only advances the event sequence. The message and millis components
## are unchanged. Callers needing fresh timestamps for new messages should construct
## a new EventTime via from_parts.
advance_event : EventTime -> EventTime
advance_event = |@EventTime(packed)|
    ev = Num.bitwise_and(packed, event_seq_mask)
    if ev == event_seq_mask then
        @EventTime(Num.bitwise_and(packed, Num.bitwise_xor(event_seq_mask, Num.max_u64)))
    else
        @EventTime(packed + 1)

## Strict less-than comparison (helper for tests)
is_less : EventTime, EventTime -> Bool
is_less = |@EventTime(a), @EventTime(b)| a < b

# ===== Tests =====

expect
    et = from_parts({ millis: 1000, message_seq: 5, event_seq: 3 })
    millis(et) == 1000 and message_seq(et) == 5 and event_seq(et) == 3

expect
    et = from_parts({ millis: 0, message_seq: 0, event_seq: 0 })
    millis(et) == 0 and message_seq(et) == 0 and event_seq(et) == 0

expect
    et = from_parts({ millis: millis_max, message_seq: 0x3FFF, event_seq: 0xFF })
    millis(et) == millis_max and message_seq(et) == 0x3FFF and event_seq(et) == 0xFF

expect
    et1 = from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    et2 = from_parts({ millis: 1000, message_seq: 1, event_seq: 0 })
    et1 != et2

expect
    et1 = from_parts({ millis: 1000, message_seq: 99, event_seq: 99 })
    et2 = from_parts({ millis: 1001, message_seq: 0, event_seq: 0 })
    is_less(et1, et2)

expect
    et1 = from_parts({ millis: 1000, message_seq: 0, event_seq: 99 })
    et2 = from_parts({ millis: 1000, message_seq: 1, event_seq: 0 })
    is_less(et1, et2)

expect
    et1 = from_parts({ millis: 1000, message_seq: 5, event_seq: 0 })
    et2 = from_parts({ millis: 1000, message_seq: 5, event_seq: 1 })
    is_less(et1, et2)

expect
    et = from_parts({ millis: 1, message_seq: 0, event_seq: 0 })
    is_less(min_value, et)

expect
    et = from_parts({ millis: 1000, message_seq: 0, event_seq: 0 })
    is_less(et, max_value)

expect
    et = from_parts({ millis: 1000, message_seq: 5, event_seq: 3 })
    et2 = advance_event(et)
    event_seq(et2) == 4 and message_seq(et2) == 5 and millis(et2) == 1000

expect
    et = from_parts({ millis: 1000, message_seq: 5, event_seq: 0xFF })
    et2 = advance_event(et)
    event_seq(et2) == 0 and message_seq(et2) == 5 and millis(et2) == 1000
