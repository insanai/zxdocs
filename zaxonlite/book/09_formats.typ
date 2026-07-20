#import "theme.typ": *

= Format reference

All integers are little-endian unless noted. Hashes are SHA-256.

== Payload ("ZXPL")

The immutable object named by `payload_hash`:

#field_table(
  [0 / 4], [`magic`], [`0x4c50585a` ("ZXPL")],
  [4 / 1], [`version`], [1],
  [5 / 3], [reserved], [zero],
  [8 / 4], [`page_size`], [power of two, 512–65536],
  [12 / 16], [`database_id`], [must match the node's identity],
  [28 / 4], [`transaction_count`], [≥ 1],
  [32 / 4], [`frame_count`], [≥ 1],
)

followed by `transaction_count` records of 32 bytes
(`session_id:u64, sequence:u64, first_frame:u32, frame_count:u32,
change_count:i64`), then `frame_count` records of 8 bytes
(`page_number:u32, commit_size:u32` — big-endian values already
converted to native descriptors), then the raw page images. Validation
requires transactions to tile the frame range in order and each to end
on a commit frame.

== Snapshot manifest

Plain `key=value` lines, hashed whole for the stop-sign digest:

```text
format=1
database_id=<32 hex>
sealed_configuration_id=<decimal>
applied_slot=<decimal>          # slot before the stop sign
chain=<64 hex>
db_sha256=<64 hex>
```

The stop-sign metadata is `zx1 <snapshot-name-16hex> <manifest-sha256>`;
a generation is only installable when its manifest hashes to the decided
value.

== Identity file

```text
format=2
node_id=<decimal>
database_id=<32 hex>
configuration_id=<decimal>
role=<data-voter|witness|standby|read-replica>
```

Format 1 omitted `role` and is read as `data-voter`; a later identity write
upgrades it to format 2. Opening a directory under another role is rejected.
This prevents a restart from silently changing a voter into a learner or the
reverse. Gateways have no identity file.

== Wire frames

Every connection: `u32 total_len` (body length + 1), `u8 kind`, body.
Bodies over 64 MiB are protocol errors.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Kind*], [*Name*], [*Body*]),
  [1], [`hello`], [`version:u16, kind:u8 (0 peer, 1 client),
    node_id:u32, database_id:u128, configuration_id:u64`],
  [2], [`envelope`], [`configuration_id:u64`, then the encoded Paxos
    envelope (`from:u32, to:u32, tag:u8`, message fields)],
  [3], [`payload_data`], [`hash:[32]u8`, payload bytes (receiver
    verifies the hash)],
  [4], [`payload_request`], [`hash:[32]u8`],
  [5], [`fence_request`], [`ballot (u64,u32,u32), fence_id:u64,
    fence_slot:u32`],
  [6], [`fence_ack`], [`fence_id:u64, ok:u8, promised ballot`],
  [7], [`snapshot_request`], [empty],
  [8], [`snapshot_begin`], [`configuration_id:u64, name:[16]u8,
    db_size:u64, manifest_len:u32, manifest`],
  [9], [`snapshot_chunk`], [`offset:u64`, image bytes],
  [10], [`snapshot_end`], [empty],
  [11 / 12], [`rpc_request` / `rpc_response`], [one JSON object],
  [13], [`payload_stored`], [`hash:[32]u8`; emitted only after verified
    durable installation],
  [14 / 15], [`auth_challenge` / `auth_response`], [fresh nonce and mutual
    HMAC-SHA256 proofs],
  [16], [`backup_begin`], [`size:u64, sha256:[32]u8`],
  [17], [`backup_chunk`], [`offset:u64`, backup bytes],
  [18], [`backup_end`], [empty],
  [19], [`learner_commit`], [`configuration_id:u64, slot:u32`, then one
    canonical chosen entry; accepted only from a configured voter],
  [20], [`learner_heartbeat`], [`configuration_id:u64, decided_through:u32`;
    drives bounded-staleness checks but carries no vote],
)

The current hello version is 4. Version 2 added the storage-ACK gate and applied
payload materialization to value-bearing Phase-1 promises. Version 3 added
mutual authentication and backup streaming. Version 4 adds durable,
voter-certified chosen-entry delivery and freshness heartbeats to non-voting
learners. After
authentication, every
application body is wrapped as `sequence:u64 || body || hmac:[32]u8`; exact
next-sequence validation rejects replay. Older versions are rejected rather
than silently downgraded.

Envelope message tags: prepare 0, promise 1, promise_done 2, accept 3,
accepted 4, commit 5, learn 6, nack 7, heartbeat 8 — carrying exactly
the fields of the core protocol's message types, with entries encoded
by the same canonical codec the journal uses.

== The replicated command encoding

`Command` encodes into a fixed 149-byte canonical form (tag byte, then
fields, zero padding enforced on decode): tag 0 `noop`, tag 1
`transaction_batch` (all descriptor fields in order), tag 2
`read_barrier` (nonce). Non-canonical padding or unknown tags are
decode errors — one byte pattern, one meaning.
