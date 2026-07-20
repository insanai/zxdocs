#import "theme.typ": *
#import "figures.typ": *

#part_page("V", [Reference and evidence], [
  This part collects the facts you look up rather than reread: byte formats,
  wire frames, and the desk tables for commands, errors, and limits. It closes
  with the verification work that gives us the right to print them.
])

= Format reference

#objectives([
  By the end of this chapter you should be able to decode a payload header
  from a hex dump, read a snapshot manifest and an identity file, name every
  wire frame kind and what its body carries, and state the exact size and
  layout of one replicated command.
])

A format is a contract. Once a byte layout has reached a disk or a socket,
every future version of Zaxonlite must still read it. This chapter states
each contract precisely enough to check a hex dump against it. Two
conventions hold everywhere. Integers are little-endian unless a field says
otherwise. Every hash is SHA-256.

== Payload ("ZXPL")

A payload is the immutable object that a descriptor's `payload_hash` names.
Chapter 5 explains how one is captured from the SQLite WAL. Here is its
header:

#field_table(
  [0 / 4], [`magic`], [`0x4c50585a` ("ZXPL")],
  [4 / 1], [`version`], [1],
  [5 / 3], [reserved], [zero],
  [8 / 4], [`page_size`], [power of two, 512--65536],
  [12 / 16], [`database_id`], [must match the node's identity],
  [28 / 4], [`transaction_count`], [≥ 1],
  [32 / 4], [`frame_count`], [≥ 1],
)

Three regions follow the header. First come `transaction_count` records of
32 bytes each: `session_id:u64`, `sequence:u64`, `first_frame:u32`,
`frame_count:u32`, `change_count:i64`. Then come `frame_count` records of
8 bytes each: `page_number:u32` and `commit_size:u32`. SQLite stores those
two values big-endian in the WAL. The capture path converts them, so the
descriptors in a payload are already native. The raw page images close the
object.

Validation is strict, because a payload becomes evidence. The transactions
must tile the frame range in order, with no gap and no overlap. Each
transaction must end on a commit frame. A payload that fails any check is
rejected before Paxos state may reference it.

== Snapshot manifest

Every snapshot generation carries a manifest of plain `key=value` lines.
The whole file is hashed for the stop-sign digest:

```text
format=1
database_id=<32 hex>
sealed_configuration_id=<decimal>
applied_slot=<decimal>          # slot before the stop sign
chain=<64 hex>
db_sha256=<64 hex>
```

The stop-sign metadata is the string `zx1 <snapshot-name-16hex>
<manifest-sha256>`. During normal local rollover,
`completeClusterRollover` requires the manifest to hash to this decided
value. Followers reproduce the physical file from the same decided WAL page
frames and require the identical manifest digest. The network
snapshot-install path does not yet carry or confirm that decided stop-sign
evidence before accepting a self-consistent future manifest. The planned
`CheckpointProofV1` packages the existing stop-sign tuple and requires an
mTLS read quorum to confirm its digest before activation; it does not add
snapshot signatures or another Paxos phase.

== Identity file

```text
format=2
node_id=<decimal>
database_id=<32 hex>
configuration_id=<decimal>
role=<data-voter|witness|standby|read-replica>
```

Format 1 omitted `role`. A node reads such a file as `data-voter` and
upgrades it to format 2 on the next identity write. Opening a directory
under a different role is refused. That refusal protects safety. A restart
must never silently turn a voter into a learner, or the reverse. Gateways
keep no identity file because they hold no state.

== Wire frames

Every connection speaks one framing: a `u32 total_len` (body length plus
one), a `u8 kind` byte, then the body. A body of 64 MiB or more is a
protocol error. The largest legal body is one byte under 64 MiB.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Kind*], [*Name*], [*Body*]),
  [1], [`hello`], [`version:u16`, `kind:u8` (0 peer, 1 client),
    `node_id:u32`, `database_id:u128`, `configuration_id:u64`.],
  [2], [`envelope`], [`configuration_id:u64`, then the encoded Paxos
    envelope: `from:u32`, `to:u32`, `tag:u8`, message fields.],
  [3], [`payload_data`], [`hash:[32]u8`, then the payload bytes. The
    receiver verifies the hash.],
  [4], [`payload_request`], [`hash:[32]u8`.],
  [5], [`fence_request`], [ballot as `u64`, `u32`, `u32`, then
    `fence_id:u64`, `fence_slot:u32`.],
  [6], [`fence_ack`], [`fence_id:u64`, `ok:u8`, the promised ballot.],
  [7], [`snapshot_request`], [Empty.],
  [8], [`snapshot_begin`], [`configuration_id:u64`, `name:[16]u8`,
    `db_size:u64`, `manifest_len:u32`, the manifest.],
  [9], [`snapshot_chunk`], [`offset:u64`, then image bytes.],
  [10], [`snapshot_end`], [Empty.],
  [11, 12], [`rpc_request`, `rpc_response`], [One JSON object.],
  [13], [`payload_stored`], [`hash:[32]u8`. Sent only after verified
    durable installation.],
  [14, 15], [`auth_challenge`, `auth_response`], [A fresh nonce and mutual
    HMAC-SHA256 proofs.],
  [16], [`backup_begin`], [`size:u64`, `sha256:[32]u8`.],
  [17], [`backup_chunk`], [`offset:u64`, then backup bytes.],
  [18], [`backup_end`], [Empty.],
  [19], [`learner_commit`], [`configuration_id:u64`, `slot:u32`, then one
    canonical chosen entry. Accepted only from a configured voter.],
  [20], [`learner_heartbeat`], [`configuration_id:u64`,
    `decided_through:u32`. Drives bounded-staleness checks. Carries no
    vote.],
)

The current `hello` version is 4. Older versions are rejected outright,
never silently downgraded. Version 2 added the storage-ACK gate and applied
payload materialization to value-bearing phase-one promises. Version 3
added mutual authentication and backup streaming. Version 4 added durable
voter-certified chosen-entry delivery and freshness heartbeats for
non-voting learners.

After authentication, every application body is wrapped as
`sequence:u64 || body || hmac:[32]u8`. The receiver requires the exact next
sequence. That rule rejects replayed frames.

The envelope message tags are: prepare 0, promise 1, promise_done 2,
accept 3, accepted 4, commit 5, learn 6, nack 7, heartbeat 8. Each carries
exactly the fields of the core protocol's message type. Log entries inside
them use the same canonical codec the journal uses. One encoder serves the
disk and the wire, so they can never disagree.

== The replicated command encoding

A `Command` encodes into a fixed 153-byte canonical form: one tag byte, two
`u128` fields (32 bytes), two `u64` fields (16 bytes), three 32-byte hashes
(96 bytes), and two `u32` fields (8 bytes). Fields a tag does not use must
be zero, and decode enforces that padding. Tag 0 is `noop`. Tag 1 is
`transaction_batch` and uses every descriptor field in order. Tag 2 is
`read_barrier` and uses the nonce. Non-canonical padding and unknown tags
are decode errors. One byte pattern has one meaning. That property is what
lets equal chain hashes mean equal history.

#exercise([15.1], [
  A payload header begins `5a 58 50 4c 01 00 00 00 00 10 00 00`. Read off
  the magic, the version, and the page size. Then explain which later check
  would still reject this payload if its one transaction did not end on a
  commit frame.
], hint: [
  The integers are little-endian. `0x1000` is 4096.
])

#teach_back([
  Explain to a colleague why payload validation runs before Paxos may
  reference the payload, and what could go wrong if a node accepted a
  descriptor whose payload bytes it had never verified. Use the words
  payload gate and safety.
])
