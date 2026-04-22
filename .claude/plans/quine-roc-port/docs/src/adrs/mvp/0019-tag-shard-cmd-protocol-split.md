# ADR-019: TAG_SHARD_CMD — Separate Wire Tag for Shard-Level Commands

**Status:** Accepted
**Date:** 2026-04-22
**Context:** The REST API needs to send standing query commands (register,
update, cancel) to shard workers. These are shard-level operations — they
affect the shard's query index, not a specific node. The existing
TAG_SHARD_MSG (0x01) framing expects a QuineId-targeted envelope, which
shard-level commands don't have.

**Related:** Bug fix for qr-oc9 (SQ command decode errors). MVP spec
`refs/specs/mvp-single-host.md` (M5/D3).

## Decision

Add a new top-level channel message tag **TAG_SHARD_CMD = 0x02** for
shard-level commands. Keep TAG_SHARD_MSG (0x01) for node-targeted messages.

## Wire Format

Messages on the shard channel are discriminated by their first byte:

```
0x01 TAG_SHARD_MSG      — node-targeted: [0x01][qid_len:U16LE][qid][msg...]
0x02 TAG_SHARD_CMD      — shard-level:   [0x02][cmd_tag][cmd_data...]
0xFD TAG_SHUTDOWN        — (reserved for graceful shutdown)
0xFE TAG_PERSIST_RESULT  — persistence reply
0xFF TAG_TIMER           — timer tick
```

Shard command sub-tags (after the 0x02 byte):

```
0x01 RegisterSq:   [global_id:U128LE][include_cancel:U8][mvsq_binary...]
0x02 UpdateSqs:    (no data)
0x03 CancelSq:     [global_id:U128LE]
```

## Alternative Considered

**Overload TAG_SHARD_MSG.** Check the second byte for SQ command tags
(0x10-0x12) before attempting `decode_shard_envelope`. This avoids a new
top-level tag but creates an ambiguous parse: the second byte of a shard
envelope is the low byte of `qid_len`, which could coincidentally equal an
SQ command tag. The disambiguation logic would be fragile.

## Rationale

Clean separation between node-targeted and shard-level messages at the
protocol level. The shard worker's dispatch (`match msg[0]`) handles each
tag independently. No ambiguity, no fallback parsing.

This also establishes a pattern for future shard-level commands (config
reload, shard migration, diagnostic queries) without polluting the
node-message namespace.

## Consequences

- Roc side needs `Codec.decode_shard_cmd` and `graph-app.handle_shard_cmd!`
  (both implemented in the qr-oc9 fix).
- Rust side needs `TAG_SHARD_CMD` in channels.rs and the shard worker match
  arm (implemented).
- The MVSQ AST is encoded in a custom binary format (not JSON) to match the
  Roc decoder. The Rust API has `encode_mvsq_binary` which must stay in sync
  with `Codec.decode_mvsq`. Currently supports UnitSq, LocalProperty,
  LocalId, AllProperties, and common ValueConstraint variants.
