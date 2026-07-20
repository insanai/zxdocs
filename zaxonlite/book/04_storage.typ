#import "theme.typ": *

= Storage and recovery

== The file set

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

Authority is unambiguous: *journal plus payloads plus snapshots* are the
database. `current.db` is a cache of applying them; `current.db-wal` and
`-shm` are working artifacts of the live connection and are deleted on
every open before rebuild.

== Ordering rules

The host enforces five write-ordering invariants, and the crash tests
exist to catch any violation:

+ payload fsync and an explicit `payload_stored` ACK *before* a value-bearing
  promise, accept, or commit is released to that peer;
+ journal append + fsync *before* any dependent message leaves the
  process (sync-before-send) — structurally guaranteed because
  `consumeEffects` journals before it fills the outbox;
+ parent-directory sync after every authoritative create/link/rename, so
  journal names, payload objects, `identity`, `CURRENT`, and snapshot
  generations survive with their synced contents;
+ commit *before* apply, applied contiguously in slot order;
+ session-row update inside the captured transaction *before*
  acknowledgement (acknowledge-after-session-update).

== Recovery sequence

`Node.open` performs, in order: lock the directory; load or create
`identity`; open the payload store; open the epoch journal and replay it
into `DurableState` (truncating a torn final record; rejecting interior
corruption); restore the protocol node; validate the installed snapshot's
identity, epoch relation, manifest fields, and image digest; resume an
interrupted snapshot install if required; *(one-member only)* campaign; rebuild
the materialized image by always deleting `current.db`/`-wal`/`-shm`, copying
the snapshot base, then chain-validating and offline-applying every committed
batch; complete a pending epoch rollover if a decided stop sign was replayed;
finally validate that the image's recorded `batch_id` equals the last committed
descriptor's.

#callout(title: "Torn tail versus interior corruption", tone: "warning")[
  A record that fails to parse *and* touches end-of-file is a torn
  append: it is truncated and recovery proceeds — that vote or commit
  was never confirmed to anyone. A record that fails *inside* the valid
  prefix is corruption of state the node may have promised: the node
  refuses to open rather than vote with amnesia.
]

== Snapshots and epoch rollover

An epoch holds at most 256 slots; the host checkpoints before the bound
(reserving four slots so the stop sign always fits). A snapshot is a
*decided* object:

+ materialize: truncating checkpoint on the leader's capture connection
  (followers are already fully materialized offline);
+ build `snapshots/tmp-<config>/` with the database copy and a manifest
  (database id, sealed configuration, applied slot, chain, db SHA-256),
  then rename it into place;
+ propose `checkpoint(metadata)` where the metadata is
  `zx1 <name> <manifest-sha256>` — the stop sign seals the epoch;
+ when the stop sign commits, every member verifies its local generation
  against the decided digest (followers build theirs from the offline
  image; byte-determinism makes the digests match), installs `CURRENT`,
  bumps `identity`, starts the next epoch's journal, and re-elects.

Rollover is crash-resumable at every step: the decided stop sign in the
sealed journal replays on restart and the completion re-runs
idempotently.

== Garbage collection

After a rollover the node keeps: the new epoch's journal, the sealed
epoch's journal (fallback generation), the two newest snapshot
generations, and every payload referenced by a retained journal.
Everything older is covered by the installed snapshot and deleted. A
payload is never collected because of age or ballot change — only when
no retained journal references it.

== The journal format

Each record:

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
entries; an entry is a command descriptor or a stop sign (configuration
id, members, metadata).
