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
  from a hex dump, read a snapshot manifest and an identity file, decode a
  decided registry blob and its checkpoint proof, name every wire frame
  kind and what its body carries, and state the exact size and layout of
  one replicated command.
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

The stop-sign metadata is a short space-separated string. A registry-less
embedded or local host writes `zx1 <snapshot-name-16hex> <manifest-sha256>`.
A registry-backed host writes `zx2 <snapshot-name-16hex> <manifest-sha256>
<next-registry-sha256>`, binding the digest of the canonical next decided
registry into the stop sign Paxos chooses. When the stop sign carries a
voter replacement, the `zx2` string appends a bounded seed:
`<operation-id-16hex> <old-node-id-8hex> <new-node-id-8hex> <endpoint>`.
The host metadata capacity is 512 bytes, sized for the longest `zx2` form.
During normal local rollover, `completeClusterRollover` requires the
manifest to hash to the decided value. Followers reproduce the physical file
from the same decided WAL page frames and require the identical manifest
digest. The network install carries the canonical `ZXP2` proof described
below. The receiver validates its bindings and requires matching
proof-digest reports from a read quorum of the sealed voter set over mTLS
before activation. This adds neither snapshot signatures nor another Paxos
phase; it confirms the stop sign Paxos already chose.

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

== Decided registry ("ZXRG")

A registry-backed server derives its membership from a decided registry,
not from startup flags. One canonical encoding covers the registry for one
configuration. Two equal registries encode to identical bytes, regardless
of input order, and the registry digest is SHA-256 over exactly these
bytes. The fixed prefix:

#field_table(
  [0 / 4], [`magic`], [`0x47525a58` ("ZXRG")],
  [4 / 2], [`format`], [1],
  [6 / 16], [`database_id`], [must match the node's identity],
  [22 / 8], [`configuration_id`], [the configuration this registry governs],
  [30 / 8], [`predecessor_configuration_id`], [the configuration it
    succeeded],
  [38 / 4], [`highest_allocated_node_id`], [the node-ID allocation fence],
  [42 / 2], [`node_count`], [number of member records],
)

The allocation fence is monotonic and never wraps. Every node ID ever
admitted is at or below it, and a replacement's new ID must exceed it, so
a retired ID can never be reissued. `node_count` member records follow,
sorted ascending by id: `node_id:u32`, `role:u8`, `endpoint_len:u8`, then
`endpoint_len` bytes of endpoint text. An endpoint is printable, space-free
ASCII containing a colon, at most 64 bytes. After the members comes
`ring_count:u16`, then up to 32 operation records ascending by
`operation_id`: `operation_id:u64`, `expected_configuration_id:u64`,
`old_node_id:u32`, `new_node_id:u32`, `request_digest:[32]u8`,
`result_configuration_id:u64`. The ring retains the 32 newest decided
replacement outcomes, which is what makes an operator's retry idempotent: a
retained operation ID with the same request digest replays its recorded
result, and the same ID with a different digest is a conflicting reuse and
is refused.

On disk the blob is the canonical bytes plus a 32-byte SHA-256 trailer over
them, stored at `registries/<16-hex configuration id>`. The directory is
named `registries`, not `registry`, so it cannot collide with the
`REGISTRY` pointer file on a case-insensitive filesystem. A blob whose
trailer or interior validation fails is rejected; the node fails closed
rather than guessing at membership.

== Registry pointer and operation files

Three small files accompany the registry blobs.

`REGISTRY` is the pointer file naming the active blob: exactly 16 lowercase
hex characters, the configuration ID, with the same shape and strict length
check as `CURRENT`. It is replaced atomically. The rollover write order is
fixed: snapshot proof, then `CURRENT`, then `REGISTRY`, then identity. A
crash between any two of those writes recovers to a consistent state,
because each earlier file validates the later ones.

`PENDING-OP` is a small text record persisted before a replacement's stop
sign is proposed, so a crashed coordinator can resume or observe the
operation's fate:

```text
format=1
operation_id=<decimal>
expected_configuration_id=<decimal>
old_node_id=<decimal>
new_node_id=<decimal>
endpoint=<host:port>
phase=<prepared|proposed>
```

`JOIN` is the one-shot join descriptor that `zaxon enroll --data <dir>`
writes into a replacement node's fresh data directory. It tells the first
`serve` which database and configuration to join and which registry digest
to demand:

```text
format=1
database_id=<32 hex>
configuration_id=<decimal>
registry_digest=<64 hex>
```

== Checkpoint proof ("ZXP2")

The network snapshot install carries a canonical checkpoint proof. Version
2 replaces the `ZXP1` encoding; it adds the next-registry digest and the
next voter set. The layout, at most 768 encoded bytes:

#field_table(
  [0 / 4], [`magic`], [`0x32505a58` ("ZXP2")],
  [4 / 16], [`database_id`], [must match the receiver's identity],
  [20 / 8], [`sealed_configuration_id`], [the epoch the stop sign sealed],
  [28 / 8], [`next_configuration_id`], [must equal sealed plus one],
  [36 / 4], [`stop_slot`], [the stop sign's slot, nonzero],
  [40 / 4], [`applied_slot`], [must equal `stop_slot` minus one],
  [44 / 32], [`chain`], [the decided chain hash at the seal],
  [76 / 32], [`manifest_sha256`], [digest of the snapshot manifest],
  [108 / 32], [`next_registry_digest`], [all-zero on registry-less hosts],
  [140 / 2], [`sealed_count`], [voters in the sealed configuration],
  [142 / 2], [`next_count`], [must equal `sealed_count`],
  [144 / 2], [`metadata_count`], [length of the exact stop metadata],
)

The sealed member ids, the next member ids, and the stop metadata bytes
follow in that order. The equal-count rule is deliberate: a one-for-one
replacement never changes the voter count, so a proof whose sets differ in
size is invalid. Quorum confirmation counts distinct voters of the sealed
set only. The proposed next voter never counts toward its own admission,
and the threshold is the sealed set's majority.

== Wire frames

Every connection speaks one framing: a `u32 total_len` (body length plus
one), a `u8 kind` byte, then the body. A body of 64 MiB or more is a
protocol error. The largest legal body is one byte under 64 MiB. One
declared snapshot or backup transfer — the size announced by
`snapshot_begin` or `backup_begin` — is bounded by
`wire.max_transfer_bytes`, 4 GiB by default, sized for the small
embedded database profile. The server enforces its configured bound
(`ServeOptions.max_transfer_bytes`), and the client enforces the same
default on backup downloads.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Kind*], [*Name*], [*Body*]),
  [1], [`hello`], [`version:u16`, `kind:u8` (0 peer, 1 client, 2 enrollment),
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
    `db_size:u64`, `manifest_len:u32`, the manifest, `proof_len:u16`, and
    the bounded `ZXP2` proof.],
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
  [21, 22], [`checkpoint_proof_request`, `checkpoint_proof_reply`],
    [`nonce:u64`, `sealed_configuration_id:u64`, `proof_sha256:[32]u8`.
    Matching configured-voter replies form the install read quorum.],
  [23], [`enrollment_request`], [`secret:[32]u8`, `node_id:u32`,
    `database_id:u128`, `csr_len:u32`, then at most 16 KiB of CSR PEM.],
  [24], [`enrollment_response`], [`status:u8`, then on success
    `node_id:u32`, `database_id:u128`, `configuration_id:u64`,
    `registry_digest:[32]u8`, and at most 64 KiB of certificate PEM. A
    refused response is the one status byte.],
  [25], [`registry_request`], [`configuration_id:u64`. Asks a member for
    one stored registry blob.],
  [26], [`registry_data`], [`configuration_id:u64`, then the stored blob,
    canonical bytes plus digest trailer, at most 8 KiB. The receiver
    verifies the trailer and the expected digest.],
  [27], [`installation_ready`], [`configuration_id:u64`,
    `registry_digest:[32]u8`. The replacement sends it after durable
    installation and matching transport activation. Survivors accept it
    only from the decided replacement.],
)

The current `hello` version is 8. Older versions are rejected outright,
never silently downgraded. Version 2 added the storage-ACK gate and applied
payload materialization to value-bearing phase-one promises. Version 3
added mutual authentication and backup streaming. Version 4 added durable
voter-certified chosen-entry delivery and freshness heartbeats for
non-voting learners. Version 5 added checkpoint-proof transfer and quorum
confirmation.
Version 6 added the bounded one-time token/CSR enrollment exchange. A
certificate-less TLS connection is accepted only by a deliberately configured
issuer, only for connection kind 2, and only for this single request. The
opaque owner-only `ZXET` bundle binds the random token to the CA, endpoint,
issuer, database, target node, and expiry; the issuer's `ZXER` record stores
only its domain-separated hash. Chapter 13 gives the operational contract and
`docs/zds/records/0004-zaxonlite-format.typ` freezes both version-1 encodings.
Version 7 introduced the decided registry transfer used by one-for-one voter
replacement. The `ZXP2` proof replaced `ZXP1`, the enrollment response gained
its registry binding, and the two registry transfer frames joined the
protocol. Version 8 added `installation_ready`. This frame binds replacement
activation to the decided configuration and registry digest. ZDS 0008 carries
the new clauses. Acceptance stays exact-major: version 8 speaks only to
version 8.

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
