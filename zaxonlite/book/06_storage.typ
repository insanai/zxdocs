#import "theme.typ": *
#import "figures.typ": *

= Storage and recovery

#objectives([
  By the end of this chapter you should be able to name every file in a
  node's data directory and say which ones are authoritative, state the
  five write-ordering rules and the invariant each protects, walk the
  recovery sequence in order and predict its behavior at any crash
  point, and explain how a snapshot seals an epoch.
])

== The file set

One data directory holds everything a node knows:

```text
data/
  LOCK                     exclusive process lock (flock)
  identity                 node id, database id, current configuration
  paxos-<config16hex>.log  framed, checksummed protocol journal (per epoch)
  payloads/aa/<62hex>      immutable frame payloads, named by SHA-256
  snapshots/<config>/      db image + manifest per sealed epoch
  snapshots/tmp-*          in-progress generations (crash debris, GC'd)
  CURRENT                  installed snapshot pointer
  current.db               materialized SQLite image (rebuildable)
```

Hold onto one rule: the journal, the payloads, and the snapshots are the
database. `current.db` is a cache of applying them. The `-wal` and
`-shm` files are working artifacts of the live connection, and every
open deletes them before rebuilding. This is why the prediction exercise
in chapter 1 was safe. Deleting `current.db` on a stopped node deletes a
cache, and recovery rebuilds it from the authoritative files.

== The five ordering rules

The host enforces five write-ordering rules, and the crash tests exist
to catch any violation. Each rule exists to protect one invariant, so we
state them as pairs.

+ *Payload before vote.* A payload is fsynced, and the receiving peer
  has acknowledged it with `payload_stored`, before any value-bearing
  promise, accept, or commit is released to that peer. The invariant:
  every vote that can count toward a quorum is backed by a payload that
  is durable on the voter that cast it. A committed slot can therefore
  always be materialized. This is safety.
+ *Sync before send.* The journal append is fsynced and confirmed
  before any dependent message leaves the process. This is guaranteed
  structurally: `consumeEffects` journals before it fills the outbox.
  The invariant: a node never tells a peer anything it could forget in
  a crash. A forgotten promise would let two quorums stop
  intersecting, so this rule is safety too.
+ *Name with the bytes.* The parent directory is synced after every
  authoritative create, link, or rename. The invariant: an
  authoritative file survives a crash together with its directory
  entry. Without this rule, journal names, payload objects, `identity`,
  `CURRENT`, and snapshot generations could sync their contents and
  still vanish from the directory.
+ *Commit before apply.* A batch is applied only after its slot
  commits, and batches are applied contiguously in slot order. The
  invariant: the materialized image only ever reflects a decided
  prefix. Combined with chapter 5's deterministic apply, any snapshot
  plus any committed suffix rebuilds the same image.
+ *Acknowledge after session update.* The session row is updated inside
  the captured transaction, and the client is acknowledged only after
  that transaction is decided and applied. The invariant: exactly-once
  retries. If a client ever saw `ok`, the decided log contains the
  session row that records it, so a retry replays the saved result
  instead of applying twice.

== How far a sync reaches

The five rules say *when* to sync. The sync policy says what a sync
means. On Linux and the other supported platforms, `fsync(2)` flushes
the drive's write cache, so a confirmed sync is durable against power
loss. On macOS it does not: `fsync` hands the bytes to the drive but
leaves them in its volatile cache, and a power cut can drop writes the
kernel already confirmed. For rule 2 that is not mere data loss. A
voter that forgets an acknowledged promise or accept can vote again,
and two quorums stop intersecting — the same amnesia the
interior-corruption rule below refuses to open with, inflicted by
hardware instead of a damaged file.

The policy therefore has two modes, set once at startup for the whole
process. `full`, the default for real binaries, makes every
authoritative barrier on macOS issue `fcntl(F_FULLFSYNC)`, which
flushes the drive cache; a filesystem that refuses the request falls
back to plain `fsync`. `os` keeps plain `fsync` and is
development-only on macOS: process-crash recovery is identical under
both modes, and only power-loss durability differs. On the other
supported platforms the two modes are the same syscall. The CLI sets
the policy with `--sync` (chapter 2), embedded hosts call
`zaxonlite.durability.setSyncMode` before opening a node, and test
builds default to `os`, because the crash campaigns simulate process
death, which loses nothing either way.

Full mode does not flush the drive cache once per file. `F_FULLFSYNC`
empties the drive's entire cache, so one barrier per commit point
covers every block already handed to the drive: a payload install
flushes its object and directory entries with plain `fsync` — into the
drive, not yet to stable media — and the journal sync that follows is
the single full barrier that lands both together. That journal barrier
precedes every vote, recovered value, and client acknowledgement (the
sync-before-send rule above), so every counted vote still implies
durable payload bytes at its consumer. Rarer transitions that create
their own commit points — snapshot generations, epoch installs, the
`CURRENT` pointer, backups — keep their own full barriers.

== The recovery sequence

#book_figure([
  Restart never trusts the materialized database file. The image is
  discarded and rebuilt from the snapshot and the committed journal
  suffix, then checked against the log before the node serves.
], recovery_flow())

`Node.open` performs these steps, in this order:

+ take the exclusive directory lock;
+ load or create `identity`;
+ open the payload store;
+ open the epoch journal and replay it into `DurableState`, truncating
  a torn final record and refusing to open on interior corruption;
+ restore the protocol node from the replayed state;
+ validate the installed snapshot: its identity, its epoch relation,
  its manifest fields, and its image digest, resuming an interrupted
  snapshot install if one is pending;
+ campaign, in a one-member configuration only;
+ rebuild the materialized image: always delete `current.db`, `-wal`,
  and `-shm`, copy the snapshot base, then chain-validate and
  offline-apply every committed batch;
+ complete a pending epoch rollover if a decided stop sign was
  replayed;
+ validate that the image's recorded `batch_id` equals the last
  committed descriptor's.

The last step closes the loop from chapter 4. The `batch_id` marker was
written inside the captured transaction, so a rebuilt image that passes
this check is provably the image the log describes.

#predict([
  Step 4 says the node may truncate the tail of its own journal during
  replay. Deleting protocol state sounds dangerous. When is it safe, and
  when would it violate a promise? Decide before reading the rule.
])

#callout(title: "Torn tail versus interior corruption", tone: "warning")[
  A record that fails to parse and touches end-of-file is a torn append.
  It is truncated and recovery proceeds, because rule 2 guarantees that
  an unconfirmed record was never mentioned to any peer. Nothing outside
  this process depends on it. A record that fails inside the valid
  prefix is different: it is corruption of state the node may have
  promised. The node refuses to open rather than vote with amnesia.
]

== Snapshots and epoch rollover

The journal cannot grow forever. An epoch holds at most 256 slots, and
the host checkpoints before the bound, reserving four slots so the stop
sign always fits. A snapshot is not a local maintenance action here. It
is a *decided* object, agreed through the same log it seals.

#book_figure([
  An epoch ends at a decided stop sign. Everything before the seal is
  covered by the installed snapshot, and the next epoch starts a fresh
  journal at slot 1.
], epoch_seal())

Rollover runs in four steps:

+ materialize: the leader runs a truncating checkpoint on its capture
  connection, while followers are already fully materialized offline;
+ build `snapshots/tmp-<config>/` with the database copy and a manifest
  recording the database id, the sealed configuration, the applied
  slot, the chain value, and the image's SHA-256, then rename the
  generation into place;
+ propose `checkpoint(metadata)` with metadata
  `zx1 <name> <manifest-sha256>`, the stop sign that seals the epoch;
+ when the stop sign commits, every member verifies its local
  generation against the decided digest, installs `CURRENT`, bumps
  `identity`, starts the next epoch's journal, and re-elects.

Why does a follower's digest match the leader's? Chapter 5 again:
followers build their generation from the offline image, and
byte-deterministic apply makes the two images identical, so their
digests agree. Consensus decides one manifest hash, and every member can
check itself against it.

Rollover is crash-resumable at every step. The decided stop sign lives
in the sealed journal, so a restart replays it, and the completion
re-runs idempotently until it succeeds.

== Garbage collection

After a rollover the node keeps the new epoch's journal, the sealed
epoch's journal as a fallback generation, the two newest snapshot
generations, and every payload referenced by a retained journal.
Everything older is covered by the installed snapshot and deleted. A
payload is collected only when no retained journal references it. Age
and ballot changes never delete a payload.

== The journal format

Each record is framed so that replay can tell a torn tail from
corruption:

#field_table(
  [0 / 4], [`magic`], [`0x315a584a` ("ZXJ1"), little-endian],
  [4 / 1], [`version`], [format version, 1],
  [5 / 1], [`kind`], [write tag: promise 0, accept 1, commit 2],
  [6 / 2], [`reserved`], [zero],
  [8 / 8], [`sequence`], [strictly increasing from 1 per epoch],
  [16 / 4], [`payload_len`], [encoded write length],
  [20 / 4], [`crc32`], [over header-sans-crc plus payload],
  [24 / n], [`payload`], [canonical little-endian `Write` encoding],
)

Writes encode ballots (`round:u64, priority:u32, node:u32`), slots, and
entries. An entry is either a command descriptor or a stop sign carrying
a configuration id, the members, and the metadata string.

#teach_back([
  Walk a colleague through one epoch rollover, from "epoch nearly full"
  to "next epoch elected", using the words stop sign, manifest,
  `CURRENT`, and `identity`. Then name the point in the sequence after
  which a crash can no longer lose the snapshot, and say which ordering
  rule makes that true.
])
