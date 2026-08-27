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
  from a hex dump, read a journal segment, manifest, state anchor, and
  identity file, decode a decided registry blob, name every wire frame
  kind and what its body carries, and state the exact size and layout of
  one replicated command.
])

A format is a contract. Once a byte layout has reached a disk or a socket,
every future version of Zaxonlite must still read it. This chapter states
each contract precisely enough to check a hex dump against it. Two
conventions hold everywhere. Integers are little-endian unless a field says
otherwise. Every hash is SHA-256.

One caveat bounds the contract. The ZDS 0011 release was a clean format
cut with no bridge: journal format 2, wire protocol 9, and the durable
state anchor replaced their predecessors outright. Legacy artifacts —
a `paxos-*.log` journal, a `CURRENT` pointer, a `ZXP2` checkpoint
proof — are not read; a node opening a directory that holds one fails
closed as unsupported, and wire version 9 speaks only to version 9.

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

== Journal segment ("ZXS2", "ZXR2", "ZXT2")

The `consensus/` directory holds the lifetime journal as immutable
segments plus one active segment, each named `{x:0>16}.zxj` by its first
global slot. Names are hints; the header and the manifest are the
authority. The 64-byte segment header:

#field_table(
  [0 / 4], [`magic`], [`0x3253585a` ("ZXS2")],
  [4 / 1], [`version`], [2],
  [5 / 3], [reserved], [zero],
  [8 / 16], [`database_id`], [must match the node's identity],
  [24 / 8], [`first_global_slot`], [the first slot this segment covers],
  [32 / 32], [`previous_segment_digest`], [chains to the prior sealed
    segment; all-zero for the first retained segment],
)

Records follow, each framed so replay can tell a torn tail from
corruption:

#field_table(
  [0 / 4], [`magic`], [`0x3252585a` ("ZXR2")],
  [4 / 1], [`version`], [2],
  [5 / 1], [`kind`], [write tag: promise 0, accept 1, commit 2,
    trim_anchor 3],
  [6 / 2], [reserved], [zero],
  [8 / 8], [`sequence`], [strictly increasing from 1 for the database's
    lifetime],
  [16 / 8], [`slot`], [the global slot the record addresses; zero for
    slot-less kinds (promise, trim_anchor)],
  [24 / 4], [`payload_len`], [encoded write length],
  [28 / 4], [`crc32`], [over header-sans-crc plus payload],
  [32 / n], [`payload`], [canonical little-endian `Write` encoding],
)

Writes encode ballots (`round:u64, priority:u32, node:u32`), 64-bit
global slots, and entries. An entry is either a command descriptor or a
stop sign carrying a configuration id, the members, and the metadata
string. A segment seals at 16,384 records with a trailer:

#field_table(
  [0 / 4], [`magic`], [`0x3254585a` ("ZXT2")],
  [4 / 8], [`last_global_slot`], [greatest slot in the segment],
  [12 / 8], [`record_count`], [records between header and trailer],
  [20 / 16], [`max_promised`], [ballot rollup: the highest promise or
    accept ballot the segment recorded],
  [36 / 8], [`chosen_through`], [the writer's contiguous chosen prefix
    at seal time],
  [44 / 4], [`sparse_count`], [entries in the sparse slot index],
  [48 / 16n], [`sparse[]`], [`slot:u64, offset:u64` per entry, one per
    64 records, for seek without a full scan],
  [.. / 32], [`segment_digest`], [SHA-256 over every byte before it:
    header, records, and trailer prefix],
  [.. / 4], [`trailer_len`], [total trailer length, read from the end
    of the file],
)

A sealed segment either replays exactly or fails closed: `openSealed`
verifies the digest over the whole file first. The `max_promised`
rollup is load-bearing: promise records carry no slot, so once trimming
unlinks the segments that held them, only this rollup — carried forward
by the manifest — keeps a restarted acceptor from promising backwards.

== Journal manifest ("ZXM2")

`consensus/MANIFEST` names the current segment generation. It is
replaced atomically on every rotation and trim; a file the manifest
does not name is garbage.

#field_table(
  [0 / 4], [`magic`], [`0x324d585a` ("ZXM2")],
  [4 / 2], [`version`], [2],
  [6 / 2], [reserved], [zero],
  [8 / 8], [`generation`], [monotonic manifest generation],
  [16 / 16], [`database_id`], [must match the node's identity],
  [32 / 16], [`max_promised`], [ballot rollup across deleted history
    plus the retained run],
  [48 / 8], [`chosen_through`], [the writer's chosen prefix],
  [56 / 8], [`trim_id`], [the adopted trim's monotonic id],
  [64 / 8], [`trimmed_through`], [the durable trim anchor slot],
  [72 / 32], [`trim_history_hash`], [history hash at the trim anchor],
  [104 / 8], [`active_first_slot`], [first slot of the active segment],
  [112 / 4], [`segment_count`], [retained sealed segments, at most
    65,536],
  [116 / 48n], [`segments[]`], [`first_slot:u64, last_slot:u64,
    digest:[32]u8` per retained segment],
  [.. / 32], [`checksum`], [SHA-256 over everything before it],
)

Validation is structural as well as cryptographic: retained segments
must form contiguous ascending ranges starting exactly one above
`trimmed_through`, or the manifest fails closed.

== Durable state anchor ("ZXAP")

`consensus/APPLIED.0` and `APPLIED.1` alternate by generation; each is
one fixed 180-byte record. Recovery selects the valid record with the
greatest generation.

#field_table(
  [0 / 4], [`magic`], [`0x5041585a` ("ZXAP")],
  [4 / 2], [`version`], [1],
  [6 / 2], [reserved], [zero],
  [8 / 8], [`generation`], [alternates the target file by parity],
  [16 / 16], [`database_id`], [must match the node's identity],
  [32 / 8], [`global_slot`], [greatest contiguous chosen slot whose
    pages are synchronized into `current.db`],
  [40 / 8], [`configuration_id`], [configuration in effect at the
    anchor slot],
  [48 / 32], [`history_hash`], [the global history hash H at the
    anchor slot],
  [80 / 4], [`sqlite_page_size`], [image geometry],
  [84 / 8], [`sqlite_page_count`], [image geometry],
  [92 / 8], [`last_data_slot`], [batch-chain cursor at the anchor],
  [100 / 16], [`last_batch_id`], [zero when no batch precedes],
  [116 / 32], [`last_chain`], [cumulative batch chain at the anchor],
  [148 / 32], [`checksum`], [SHA-256 over everything before it],
)

A record failing magic, version, identity, or checksum is ignored;
selection falls back to the other generation or to conservative
replay from slot one. It never advances the frontier on faith.

== Trim state ("ZXTR")

`consensus/TRIM` is the durable local authority for the adopted cluster
trim and any active transfer leases. It is a fixed-size record,
replaced atomically.

#field_table(
  [0 / 4], [`magic`], [`0x5254585a` ("ZXTR")],
  [4 / 2], [`version`], [1],
  [6 / 2], [reserved], [zero],
  [8 / 8], [`trim_id`], [monotonic; a same-id different-anchor record
    is corruption],
  [16 / 8], [`through_slot`], [every slot at or below it is chosen],
  [24 / 32], [`history_hash`], [history hash at the trim anchor],
  [56 / 8], [`configuration_id`], [configuration that chose the trim],
  [64 / 1], [`lease_count`], [active transfer leases, at most 4],
  [65 / 24n], [`leases[]`], [`lease_id:u64, receiver_id:u32,
    base_slot:u64, expiry_ticks_left:u32` per lease; the table is
    zero-padded to four slots],
  [161 / 32], [`checksum`], [SHA-256 over everything before it],
)

== Stop metadata ("zx3")

A stop sign exists only for membership change now, and its metadata is a
short space-separated string:
`zx3 <next-registry-sha256-64hex> <operation-id-16hex>
<old-node-id-8hex> <new-node-id-8hex> <endpoint>`. The seed fields let
every survivor rebuild the next decided registry deterministically and
verify it against the bound digest. The host metadata capacity is 512
bytes. The `zx1` and `zx2` forms, which named a snapshot generation and
its manifest digest, are gone with the epoch rollover; a `zx3` string
carries no snapshot binding because there is no snapshot to bind.

== Global history hash

Every chosen entry advances one domain-separated SHA-256 chain:

```text
H_0 = SHA256(0x00 || LE16(1) || LE128(database_id))
L_s = SHA256(0x01 || leaf_bytes(s))
H_s = SHA256(0x02 || H_{s-1} || L_s)
```

`leaf_bytes(s)` is a fixed-width canonical encoding: the leaf version
(1), the database id, the configuration id, the global slot, a kind
byte (noop 0, transaction_batch 1, read_barrier 2, trim 3,
transfer_lease 4, lease_complete 5, stop 6), the zero-padded canonical
entry bytes, then the payload digest and the batch `result_chain_hash`
(both all-zero for entries without them). Unlike the per-batch chain
hash of chapter 4, which deliberately skips noops, stops, and retention
records, this chain commits to the complete chosen order, and it folds
the batch chain in rather than competing with it. Anchors `(s, H_s)`
bind `APPLIED` records, trim records, and state-transfer manifests to
one exact prefix. It is an integrity commitment for crash-fault
recovery, not a Byzantine proof.

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
hex characters, the configuration ID, with a strict length check. It is
replaced atomically. The handover write order is fixed: the registry
blob, then `REGISTRY`, then identity. A crash between any two of those
writes recovers to a consistent state, because each earlier file
validates the later ones.

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

== Wire frames

Every connection speaks one framing: a `u32 total_len` (body length plus
one), a `u8 kind` byte, then the body. A body of 64 MiB or more is a
protocol error. The largest legal body is one byte under 64 MiB. One
declared state or backup transfer — the size announced by
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
    envelope: `from:u32`, `to:u32`, `tag:u8`, message fields. Every slot
    and frontier field is `u64`.],
  [3], [`payload_data`], [`hash:[32]u8`, then the payload bytes. The
    receiver verifies the hash.],
  [4], [`payload_request`], [`hash:[32]u8`.],
  [5], [`fence_request`], [ballot as `u64`, `u32`, `u32`, then
    `fence_id:u64`, `fence_slot:u64`.],
  [6], [`fence_ack`], [`fence_id:u64`, `ok:u8`, the promised ballot.],
  [7], [`snapshot_request`], [`applied_slot:u64`: the requester's applied
    frontier. The sender declines while its retained journal still
    covers the gap; range recovery is cheaper.],
  [8], [`snapshot_begin`], [The transfer manifest: `configuration_id:u64`,
    `anchor_slot:u64`, `history_hash:[32]u8`, `db_size:u64`,
    `image_sha256:[32]u8`, `sqlite_page_size:u32`, `last_data_slot:u64`,
    `last_batch_id:u128`, `last_chain:[32]u8`, `registry_digest:[32]u8`.
    The receiver stages nothing until a read quorum vouches
    `(anchor_slot, history_hash)`.],
  [9], [`snapshot_chunk`], [`offset:u64`, then image bytes.],
  [10], [`snapshot_end`], [Empty. The receiver verifies `image_sha256`
    over the staged file before installing.],
  [11, 12], [`rpc_request`, `rpc_response`], [One JSON object.],
  [13], [`payload_stored`], [`hash:[32]u8`. Sent only after verified
    durable installation.],
  [14, 15], [`auth_challenge`, `auth_response`], [A fresh nonce and mutual
    HMAC-SHA256 proofs.],
  [16], [`backup_begin`], [`size:u64`, `sha256:[32]u8`.],
  [17], [`backup_chunk`], [`offset:u64`, then backup bytes.],
  [18], [`backup_end`], [Empty.],
  [19], [`learner_commit`], [`configuration_id:u64`, `slot:u64`, then one
    canonical chosen entry. Accepted only from a configured voter.],
  [20], [`learner_heartbeat`], [`configuration_id:u64`,
    `decided_through:u64`. Drives bounded-staleness checks. Carries no
    vote.],
  [21, 22], [`checkpoint_proof_request`, `checkpoint_proof_reply`],
    [The history probe: `nonce:u64`, `slot:u64`, `hash:[32]u8`. A voter
    that can vouch for the hash at that slot echoes the probe back on
    kind 22; one that cannot stays silent. Matching configured-voter
    replies form the state-transfer read quorum.],
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
  [28], [`state_report`], [`configuration_id:u64`,
    `durable_state_slot:u64`, `history_hash:[32]u8`, `executed_slot:u64`,
    `persisted_slot:u64`, `local_delete_floor:u64`,
    `retained_first_slot:u64`. Only `durable_state_slot` may authorize
    trimming; the rest is lag monitoring.],
  [29], [`range_request`], [`configuration_id:u64`, `first_slot:u64`,
    `count:u32` (at most 256), `credit:u8` pipelining allowance.],
  [30], [`range_data`], [`configuration_id:u64`, `first_slot:u64`,
    `more:u8`, `record_count:u16`, then per record `slot:u64, kind:u8,
    len:u16, bytes`: chosen journal evidence for a bounded range.],
)

The current `hello` version is 9, the ZDS 0011 format cut: 64-bit
global slots on every frame, the chunked `promise_range` phase-one
reply, bounded range recovery, durable-state reports, and the
anchor-pinned state transfer with its history probe. It shares no frame
encodings with version 8 and there is deliberately no bridge. Older
versions are rejected outright, never silently downgraded: acceptance
stays exact-major, so version 9 speaks only to version 9. Earlier
versions added, in order: the storage-ACK gate and promise payload
gating (2), mutual authentication and backup streaming (3), certified
learner delivery and freshness heartbeats (4), quorum-confirmed
transfer (5), the bounded one-time token/CSR enrollment exchange (6),
the decided registry transfer (7), and `installation_ready` (8). The
enrollment exchange is unchanged in v9: a certificate-less TLS
connection is accepted only by a deliberately configured issuer, only
for connection kind 2, and only for the single bounded request; the
opaque owner-only `ZXET` bundle binds the random token to the CA,
endpoint, issuer, database, target node, and expiry, and the issuer's
`ZXER` record stores only its domain-separated hash. Chapter 14 gives
the operational contract and
`docs/zds/records/0004-zaxonlite-format.typ`, as amended by ZDS 0011,
freezes the encodings.

After authentication, every application body is wrapped as
`sequence:u64 || body || hmac:[32]u8`. The receiver requires the exact next
sequence. That rule rejects replayed frames.

The envelope message tags are: prepare 0, promise 1, promise_range 2,
accept 3, accepted 4, commit 5, learn 6, nack 7, heartbeat 8. Each carries
exactly the fields of the core protocol's message type; `promise_range`
carries the acceptor's trim anchor (`trim_id`, `chosen_trim_slot`,
`history_hash`), its chosen-through, the advertised accepted range, and
a `more` flag for chunked phase one. Log entries inside
them use the same canonical codec the journal uses. One encoder serves the
disk and the wire, so they can never disagree.

== The replicated command encoding

A `Command` encodes into a fixed 153-byte canonical form: one tag byte, two
`u128` fields (32 bytes), two `u64` fields (16 bytes), three 32-byte hashes
(96 bytes), and two `u32` fields (8 bytes). Fields a tag does not use must
be zero, and decode enforces that padding. Tag 0 is `noop`. Tag 1 is
`transaction_batch` and uses every descriptor field in order. Tag 2 is
`read_barrier` and uses the nonce. Tag 3 is `trim`
(`trim_id:u64, through_slot:u64, history_hash:[32]u8,
configuration_id:u64, policy:u8`, where 0, all data replicas, is the
only valid v1 policy). Tag 4 is `transfer_lease` and tag 5 is
`lease_complete`, the reserved lease entries no v1 path proposes.
Non-canonical padding and unknown tags
are decode errors. One byte pattern has one meaning. That property is what
lets equal chain hashes mean equal history.

#exercise([16.1], [
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

== Search capability manifest

The search feature makes the database image depend on build
capabilities for the first time: a schema containing `USING vec0`
cannot even be opened for queries by a binary without the module. Every
release therefore records the exact search surface, and the image
records which feature version it requires.

#table(
  columns: (auto, 1fr),
  table.header([*Recorded fact*], [*Value in this release*]),
  [SQLite version and FTS5], [3.50.4, `SQLITE_ENABLE_FTS5`, asserted by
    a unit test via `compileOptionUsed`],
  [sqlite-vec], [v0.1.9, statically linked amalgamation, filesystem
    helpers compiled out (`SQLITE_VEC_OMIT_FS`); release zip SHA-256
    `b87cdda12112657ba5ab8842f0088a4090982eaf41f22b2bd6d495b81765a8c9`],
  [Vector element formats], [little-endian float32 BLOBs and one-bit
    coarse vectors; big-endian binaries are rejected at compile time],
  [Fusion API], [version 1: `rrf`, `dbsf`, `stddev_samp`],
  [Distance kernel], [version 1: 128-bit SIMD cosine with scalar
    fallback; the selected backend is reported by `zaxon_search_debug()`
    and node status],
  [Mapped-I/O compile maximum], [1 GiB (`SQLITE_MAX_MMAP_SIZE`); the
    runtime default is zero on every target],
)

The image side is one replicated metadata key: `search_feature_version`
in `__zaxon_meta`. A fresh database records version 1 at schema
bootstrap. An image that predates the feature has no key, reads as
version 0, and serves normally. A binary refuses to serve an image
whose recorded version is newer than it implements, before it serves
anything. Upgrading an old image is the explicit
`enable-search-feature` operation, run once, after every member already
serves a compatible binary; rolling the binary out first and activating
second is what keeps a mixed cluster impossible.

#teach_back([
  Explain to a colleague why the feature version lives inside the
  replicated image rather than in each node's configuration file, and
  what a configuration-file version could get wrong during a state
  transfer to a freshly replaced voter.
])
