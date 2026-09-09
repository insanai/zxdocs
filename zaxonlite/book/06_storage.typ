#import "theme.typ": *
#import "figures.typ": *

= Storage and recovery

#objectives([
  By the end of this chapter you should be able to name every file in a
  node's data directory and say which ones are authoritative, state the
  five write-ordering rules and the invariant each protects, walk the
  recovery sequence in order and predict its behavior at any crash
  point, and explain how state anchors and certified trimming keep the
  journal bounded.
])

== The file set

One data directory holds everything a node knows:

```text
data/
  LOCK                     exclusive process lock (flock)
  identity                 node id, database id, current configuration
  consensus/               the lifetime segmented consensus journal
    MANIFEST               the authoritative list of retained segments
    <firstslot16hex>.zxj   immutable sealed segments + one active segment
    APPLIED.0, APPLIED.1   alternating durable state anchors
    TRIM                   adopted trim anchor and transfer leases
  payloads/aa/<62hex>      immutable frame payloads, named by SHA-256
  current.db               materialized SQLite image
  registries/<config16hex> canonical decided registry blobs (TCP serve)
  REGISTRY                 16-hex pointer to the active registry blob
  PENDING-OP               the one in-flight replacement request
  JOIN                     one-shot join descriptor on a replacement
  .ZX-DELETED              transient delete tombstone (crash debris)
```

Hold onto one rule: the journal, the payloads, and the anchored image
are the database. Above the durable anchor, `current.db` is a cache of
applying the journal; below the anchor, it is the authoritative record
of history whose journal segments have been trimmed away. The `-wal`
and `-shm` files are working artifacts of the live connection, and
every open deletes them before replaying. This is why the prediction
exercise in chapter 1 was safe: on a database whose journal is still
retained from slot one, deleting `current.db` on a stopped node deletes
a cache, and recovery rebuilds it. Once trimming has removed history,
the image plus its anchor is the local base, and losing it means a
state transfer from a peer (or, on a single node, your backups).

The last four entries exist only on a network-hosted `zaxon serve` node,
which persists its membership as a decided registry (chapter 7). Each
blob under `registries/` is a canonical, digest-trailed encoding of one
configuration's membership, and the `REGISTRY` pointer names the active
one; both are authoritative, the same way the journal is. `PENDING-OP`
holds the one in-flight replacement request, and `JOIN` is the one-shot
join descriptor `zaxon enroll --data <dir>` writes on an enrolling
replacement, consumed on first start. All four use the same atomic
write-sync-rename discipline as the journal `MANIFEST`. Deleting `PENDING-OP` or
`JOIN` renames it to the `.ZX-DELETED` tombstone first, so the removal
itself can be flushed on every platform; a leftover tombstone is
harmless crash debris and is cleaned up on the next durable delete. The blob directory is named
`registries`, not `registry`, because common case-insensitive
filesystems would collide that name with the `REGISTRY` pointer file.
Embedded and unix-socket local nodes keep flag-fixed membership and
write none of these files.

== The five ordering rules

The host enforces five write-ordering rules, and the crash tests exist
to catch any violation. Each rule exists to protect one invariant, so we
state them as pairs.

+ *Payload before vote.* A sender queues payload bytes immediately before a
  dependent voter envelope on one ordered TCP/TLS stream. The receiver verifies
  and fsyncs the object before reading the next frame; its bounded missing-value
  gate covers reordering and reconnects. `payload_stored` caches readiness for
  later sends rather than serializing the normal accept. The invariant:
  every vote that can count toward a quorum is backed by a payload that
  is durable on the voter that cast it. A committed slot can therefore
  always be materialized. This is safety.
+ *Sync before durable claim.* Promise evidence, accepted replies, recovered
  values, commits, and client replies remain behind the journal barrier. The
  sole early class is a phase-two `accept` request: it asks another voter to
  persist a vote but does not claim the sender's own vote is durable. The host
  stays serialized until its barrier completes. The invariant: a node never
  claims durable state it could forget in a crash. A forgotten promise would
  let two quorums stop intersecting, so this rule is safety too.
+ *Name with the bytes.* Every authoritative create, link, or rename is
  followed by a sync that persists the new name. The invariant: an
  authoritative file survives a crash together with its directory
  entry. Without this rule, journal segments, payload objects,
  `identity`, the `MANIFEST`, and the anchor records could sync their
  contents and still vanish from the directory. Which handle carries that sync is a
  platform question, answered later in this chapter.
+ *Commit before apply.* A batch is applied only after its slot
  commits, and batches are applied contiguously in slot order. The
  invariant: the materialized image only ever reflects a decided
  prefix. Combined with chapter 5's deterministic apply, any anchored
  image plus any committed suffix rebuilds the same image.
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
precedes every vote acknowledgement, recovered value, and client
acknowledgement (the sync-before-durable-claim rule above), so every counted vote still implies
durable payload bytes at its consumer. Rarer transitions that create
their own commit points — segment seals, manifest generations, the
`APPLIED` anchors, the `TRIM` record, backups — keep their own full
barriers.

The steady-state cluster path overlaps those per-node barriers. The sender
queues an immutable payload immediately before its phase-two accept. TCP order
means the follower finishes the payload file and shard-directory fsyncs before
it reads the accept; the receiver's bounded missing-payload gate covers
reordering and reconnect races. Meanwhile the leader performs its own journal
barrier. The leader mutex prevents accepted replies from entering Paxos until
that barrier completes. Only an `accept` request is eligible for this early
release: promises and accepted replies assert durable facts and remain behind
the barrier. A later commit-only journal marker is derived from the durable
accepting quorum and is omitted; phase one reconstructs it after a crash. The
materialized follower database is likewise a rebuildable cache, so page apply
does not add another full barrier.

== Where a name becomes durable

Rule 3 says the name must survive with the bytes. It does not say which
handle carries that promise, because the two platform families disagree.

POSIX keeps the name in the parent directory, so the parent is what gets
synced, and it is synced after the rename. Windows keeps it somewhere else.
NTFS is write-ahead logged: `$LogFile` is one sequential metadata journal per
volume, so flushing it through a given record persists every record before it,
and flushing a file forces the log through that file's last update. Microsoft
documents the file rather than the directory as the durable unit — the way to
be sure a newly created empty file has reached disk is to flush the file.
There is no directory sync on Windows and none is needed.

The consequence is an ordering flip, and it is easy to get wrong. POSIX syncs
the file, renames, then syncs the parent. Windows syncs the file, renames,
then syncs the file again. Turning the directory sync into a no-op without
moving the barrier leaves nothing flushed after the rename: it compiles, it
passes the crash matrix — process death loses nothing under any sync mode —
and it drops acknowledged writes on power loss. `syncPathnameTransition` hides
the difference so no call site has to remember which way round it goes.

A directory sync may still be skipped where a later barrier is named, which is
the `...BeforeBarrier` contract from the previous section. The payload
install qualifies: an object becomes load-bearing only when a journal
record names it, and the journal barrier that precedes every vote lands
both together. Transitions with no such successor — manifest
generations, anchor records, enrollment tokens, published identities,
backups, segment creation — take their barrier immediately.

The model needs POSIX rename semantics and a metadata log, so Windows is
supported from release 1809 and Server 2019 on NTFS. Rather than read a
version number, a node probes: it creates a file, holds it open, and renames a
second file over it. Replacing an open file is exactly what the older Windows
rename cannot do, so one operation rejects old releases, FAT volumes, and
network filesystems that quietly degrade. ZDS 0006 records the reasoning, and
is candid that the log-ordering property is an inference from how NTFS is
built rather than a documented guarantee.

== The recovery sequence

#book_figure([
  Restart never trusts the volatile tail of the materialized database
  file. The image is resumed at the newest valid durable anchor, the
  committed journal suffix above it is replayed, and the result is
  checked against the log before the node serves.
], recovery_flow())

`Node.open` performs these steps, in this order:

+ take the exclusive directory lock;
+ load or create `identity`, honoring a decided registry or a `JOIN`
  descriptor where one exists;
+ open the payload store;
+ refuse to open over any legacy artifact: a `CURRENT` pointer or a
  `paxos-*.log` journal fails closed as unsupported, with no bridge;
+ open the `consensus/` journal: load the `MANIFEST`, sweep orphan
  segment files a crashed rotation or trim left behind, resume the
  active segment (truncating a torn final record, refusing interior
  corruption), and stream-replay every retained record into
  `DurableState`, restoring the `max_promised` rollup for history the
  trim deleted;
+ load the durable `TRIM` state;
+ materialize the image: delete `-wal` and `-shm`, select the newest
  valid `APPLIED` anchor, and offline-apply the contiguous committed
  suffix above it. Without a usable anchor, rebuild from slot one when
  the journal is still retained from genesis, and otherwise refuse and
  request a state transfer;
+ restore the protocol node at the consumed floor, so its consensus
  window resumes exactly where the host left off;
+ campaign, in a one-member configuration only;
+ resume a pending membership handover if a decided stop sign was
  replayed;
+ validate that the image's recorded `batch_id` equals the last
  committed descriptor's.

Startup cost follows the anchor cadence, not the history size: the
replayed suffix is at most the writes since the last anchor, however
old the database is.

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

== The segmented journal

Global slots are `u64` and never reset, so the journal is one lifetime
structure, not a file per configuration. It lives in `consensus/` as a
run of immutable sealed segments plus one active segment. A segment is
named by its first global slot (`{x:0>16}.zxj`), starts with a `ZXS2`
header binding the database identity and that first slot, and carries
framed, CRC-checksummed records. When the active segment reaches its
record capacity (16,384 records), the writer seals it with a `ZXT2`
trailer — last slot, record count, a sparse slot index, a digest over
the whole file, and a `max_promised` ballot rollup — publishes a new
`MANIFEST` generation naming it, syncs the directory, and only then
opens the next active segment. Nothing is ever renamed, so a crash at
any point of that rotation resolves by inspection at the next open, and
files the manifest does not name are swept as garbage.

The `max_promised` rollup is the one subtle field. Promise records
carry no slot, so once trimming deletes the segments that held them,
only the rollup — carried forward by every trailer and manifest — keeps
a restarted acceptor from promising backwards and double-voting.

Chapter 16 gives the exact byte layouts. The v1 one-file-per-epoch
journal (`paxos-*.log`) is not read; a directory holding one fails
closed as unsupported.

Retained reads open each manifest-listed segment as a sealed segment,
verify its digest, and stop at the record boundary before its trailer.
This applies to image resynchronization after leadership loss, restart
rebuilding, range catch-up, and integrity checks. Version 0.6.2 corrects
these reads so a valid trailer is not mistaken for a corrupt record;
actual digest or record corruption still fails closed. The active segment
has no trailer and is read only through its current written boundary.

== State anchors

The journal cannot grow forever, and replaying a lifetime of history at
startup would not be acceptable either. The durable state anchor solves
both. Periodically — promptly after the first applied write, then every
10,000 slots — a data replica checkpoints the SQLite WAL into
`current.db`, synchronizes the file, and publishes an `APPLIED` record
binding the applied global slot, the history hash at that slot, the
page geometry, and the batch-chain cursor. The two files `APPLIED.0`
and `APPLIED.1` alternate by generation, so one valid record always
survives a torn write; recovery selects the newest valid one and
replays only the suffix above it.

The anchor never copies or hashes the whole database. Its cost is the
dirty pages the checkpoint folds in plus two synchronized small writes,
whatever the database size. That is the difference from the retired
epoch rollover, whose full image copy and hash priced every 2,044
commits at the size of the database.

#book_figure([
  One global slot line. The chosen trim G marks history whose journal
  segments have been physically unlinked; the anchored image covers
  everything through the durable anchor A; only the suffix above A is
  replayed at restart.
], anchor_trim())

== Certified trimming

Deletion is a consensus decision, not a local judgement. Each data
replica reports its durable frontier — the anchored slot and its
history hash — in authenticated state reports. The leader computes the
conservative candidate `G = min A_i` over every current data replica
and proposes `Trim(G, H_G)` as an ordinary chosen entry. Once chosen,
every node adopts the trim: it persists the `TRIM` record, then unlinks
the sealed segments that lie wholly at or below its own local delete
floor — never past its own anchor, and never past an active transfer
lease. Payload garbage collection follows: an object is deleted only
when no retained journal record references it. Age and ballot changes
never delete a payload.

The minimum over *all* data replicas is deliberate. A lagging replica
freezes the trim rather than being trimmed past; it can always recover
from its own anchor plus the retained suffix. A permanently failed data
voter freezes trimming until it is replaced through the decided
`replace-voter` operation (chapter 7). Witnesses vote but never
materialize SQLite, so they never constrain the candidate.

A single-node database is its own only data replica: each `anchor`
degenerates the candidate to the fresh anchor, and the node chooses,
adopts, and reclaims inline.

What answers Phase 1 for deleted slots? The chosen trim record itself.
A trimmed acceptor's promise carries its trim anchor — "everything
through G is chosen under H_G" — and an elected leader never proposes
at or below the greatest anchor a complete quorum reports. Bytes
disappear; the protocol fact that the prefix is closed does not.

== Garbage collection

Trimming leaves three kinds of garbage, each cleaned without risk to
retained state. Segment files a crashed rotation or trim left behind
are swept at the next open, because the `MANIFEST` is the authority on
what is retained. Payload objects are swept by streaming the retained
journal to rebuild the reachable set — a crash can leak an object,
never delete a reachable one. On a registry-backed server, superseded
registry blobs are collected with the same retention discipline.

#teach_back([
  Walk a colleague through one anchor-and-trim cycle, from "the leader
  collects state reports" to "segments unlinked", using the words
  durable frontier, chosen trim, `TRIM` record, and delete floor. Then
  name the point in the sequence after which a crash can no longer
  resurrect the deleted history, and say why a lagging replica can
  still recover.
])
