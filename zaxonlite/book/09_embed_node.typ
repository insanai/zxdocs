#import "theme.typ": *
#import "figures.typ": *

#part_page("III", [Embedding], [
  The same engine now runs inside your process, first as one durable node
  and then as a full cluster member. We embed it from Zig, then cross the
  C ABI so any language can follow.
])

= Embedding a node in Zig

#objectives([
  By the end of this chapter you should be able to open a durable
  single-member node from Zig, say what is synced before each call
  returns, choose between `exec`, `execPrepared`, and `execTransaction`,
  retry a write safely through a session, own the memory of every value
  the node returns, and name the extra surface a transport host must
  drive.
])

#checkpoint([the write path], [
  This chapter assumes you know what a captured WAL payload is
  (chapter 5) and why the journal outranks the SQLite image (chapter 6).
  The API below is those two chapters turned into function calls.
])

This chapter serves the single-durable-node embedder. That means one
process, one data directory, and no network. The same `Node` type also
serves cluster members. Where a cluster member has an extra obligation,
we say so explicitly.

== Lifecycle: `open` and `close`

#api_anchor(`Node.open(gpa, io, options) !*Node`,
  [Creates or recovers one node from one data directory and returns a
   heap-allocated handle owned by the caller.],
  source: [`zaxonlite/src/node.zig`])

```zig
const zaxonlite = @import("zaxonlite");

var node = try zaxonlite.Node.open(gpa, io, .{ .directory = "./data" });
defer node.close();
```

That is the whole lifecycle for a single durable node. The options
struct has six fields, and five of them have defaults:

#table(
  columns: (auto, auto, 1fr),
  table.header([*Field*], [*Default*], [*Meaning*]),
  [`directory`], [required], [The node's data directory. It is created
    when missing.],
  [`node_id`], [`1`], [This node's Paxos identity.],
  [`members`], [empty], [The full voting membership, including this
    node. Empty means a one-member configuration of just `node_id`.],
  [`leader_priority`], [`0`], [The election priority carried in this
    node's ballots.],
  [`database_id`], [`null`], [The database identity for a fresh
    directory. `null` draws a random one.],
  [`role`], [`.data_voter`], [The product role from chapter 7.],
)

Three of these fields are identity: `node_id`, `database_id`, and
`role`. The first `open` persists them in the directory's identity
file. Every later `open` checks the options against that file. Cluster
members must agree on `database_id`; a random one is only right for a
single node. `open` refuses to proceed when anything disagrees:

#table(
  columns: (auto, 1fr),
  table.header([*Open-time error*], [*When `open` returns it*]),
  [`error.NodeLocked`], [Another live process holds the directory's
    exclusive `LOCK` file. One process per directory is the rule.],
  [`error.NodeIdMismatch`], [The `node_id` option differs from the
    persisted identity.],
  [`error.DatabaseMismatch`], [The `database_id` option differs from
    the persisted identity.],
  [`error.NodeRoleMismatch`], [The `role` option differs from the
    persisted identity.],
  [`error.TooManyMembers`], [The membership names more than nine
    voters.],
  [`error.RoleHasNoLocalStore`], [The role is `.gateway`. A gateway
    owns no data directory, so it cannot be opened as a `Node`.],
  [`error.RoleMembershipMismatch`], [A voter is missing from
    `members`, or a non-voter appears in it.],
)

The directory is the database. It holds the identity file, the
exclusive `LOCK`, one `paxos-*.log` journal per epoch, the
content-addressed `payloads/` store, the `snapshots/` directory with
its `CURRENT` pointer, and the materialized `current.db` image. The
journal and the payload store are authoritative. The SQLite image is
not. Every `open` deletes the image and rebuilds it from the verified
snapshot plus the committed journal suffix. A tampered or deleted image
therefore never outranks Paxos state.

A one-member node campaigns during `open`. A one-member quorum
completes immediately, so `open` returns ready to serve. The
schema-bootstrap write runs on the first open.

#predict([
  `close` performs no flush of its own. Is that a durability hole?
  Decide before reading on.
])

It is not. Nothing is ever unflushed: every acknowledged write was
journaled and fsynced before its call returned. `close` releases
everything `open` acquired, including the `*Node` allocation itself.

== Your first write: `exec`

#api_anchor(`Node.exec(sql) !ExecResult`,
  [Executes one write transaction and replicates its captured WAL
   frames.],
  source: [`zaxonlite/src/node.zig`])

The SQL must be a null-terminated slice, typed `[:0]const u8`. The node
borrows it only for the duration of the call. Every write follows one
durability ordering, and `exec` does not return success until the
required prefix of it is done:

+ The SQL executes inside `BEGIN IMMEDIATE ... COMMIT` on the capture
  connection.
+ The committed WAL frames are captured and persisted as one payload in
  the content-addressed store. The payload is written, fsynced, and
  linked before anything may reference it.
+ The fixed-size descriptor is appended through the replicated log. The
  resulting durable writes are journaled and fsynced.
+ Only now may protocol messages leave the node. Only now is the slot
  committed and applied.

#book_figure([
  Every `exec` walks this path. Nothing leaves the node, and nothing is
  acknowledged, before the payload and journal syncs complete.
], write_path())

What the returned `ExecResult` means depends on the configuration. In a
one-member configuration the result carries `.changes` and `.slot`,
and the slot is already committed and applied locally. Acknowledged
means durable. In a cluster the same call returns once the local
journal write is durable. Commitment still needs a quorum. The
transport host must await the slot's commitment and check
`pendingBatchId` before acknowledging a client. Chapter 8 states that
acknowledgement rule precisely.

Failure has two sides, and they are not symmetric. A failed SQL
statement rolls back before capture. Nothing about it is replicated.
The SQLite message is readable through `lastSqliteMessage()`, bounded
at 512 bytes and valid until the next SQL call. An error between the
local commit and the log append marks the image for resync. The next
call repairs it automatically.

#callout(title: [A failed fsync is fatal and sticky], tone: "warning")[
  A journal or payload fsync failure poisons the node. Every later call
  returns `error.StorageFailed`. This protects the effects contract: a
  node that cannot make its state durable must stop talking. Stop using
  the node, repair the storage, and open the directory again. Recovery
  rebuilds from the verified journal.
]

One more refusal matters here. A sealed epoch returns
`error.LogSealed`. A one-member node avoids it by checkpointing
automatically as its 2,048-slot epoch fills.

== Prepared statements: `execPrepared`

String SQL is fine for schema work. Data should travel as typed
parameters. `execPrepared` binds values of type `prepared.Value`,
exported as `zaxonlite.Value`. The variants are `null_value`,
`integer: i64`, `real: f64`, `text: []const u8`, and
`blob: []const u8`. Parameter bytes are borrowed only for the duration
of the call. The value count must match the statement's placeholders,
or the call fails with `error.ParameterCountMismatch`.

```zig
const result = try node.execPrepared("insert into items(v) values (?1)",
    &.{.{ .text = "tea" }});
std.debug.assert(result.changes == 1);
```

== Multi-statement transactions: `execTransaction`

#api_anchor(`Node.execTransaction(*Transaction) !ExecResult`,
  [Commits a completed transaction builder as one replicated WAL
   transition.],
  source: [`zaxonlite/src/node.zig`, `zaxonlite/src/prepared.zig`])

A `zaxonlite.Transaction` is a builder, not a live SQLite transaction.
Each `txn.exec` copies its SQL and parameter bytes into the builder's
own arena. Nothing touches the database until you commit the builder.
This is deliberate. Application think-time never holds database locks.
No speculative SQLite state can survive a leadership change, because
none exists until commit.

```zig
var txn = zaxonlite.Transaction.init(gpa);
defer txn.deinit();
try txn.exec("insert into items(v) values (?1)", &.{.{ .text = "a" }});
try txn.exec("update items set v = ?1 where id = ?2",
    &.{ .{ .text = "b" }, .{ .integer = 1 } });
const result = try node.execTransaction(&txn);
```

You own the builder. Call `deinit` on it exactly once; the node keeps
no reference. The bounds are hard. A builder accepts at most 1024
statements (`error.TooManyStatements`) and 64 MiB of copied input
(`error.TransactionInputTooLarge`). An empty builder cannot be
committed (`error.EmptyTransaction`). The replicated payload itself is
bounded at 64 MiB minus framing (`error.TransactionTooLarge`).

A builder is single-use, even when execution fails. Reusing one returns
`error.TransactionFinished`. This is a safety choice, not a
convenience gap. Retry belongs to an idempotent session, never to
accidental re-submission.

== Exactly-once sessions

Chapter 8 defined the problem: an ambiguous outcome, such as a timeout,
leaves you unsure whether a write committed. Sessions are the node-level
answer. `openSession()` creates a replicated session row and returns
its `u64` id. A session permits one outstanding sequence, starting
at 1. `execIdempotent(session_id, sequence, sql)` then decides among
five cases:

+ The sequence is the permitted next one. The SQL executes exactly
  once. The session-row update rides inside the same captured
  transaction as your SQL, so the result and the data commit
  atomically.
+ The sequence equals the last executed one. The recorded result
  returns with `.replayed = true` and `.slot = 0`. No SQL executes.
+ The sequence is older than that: `error.ResultExpired`, and no SQL
  executes.
+ The sequence skips ahead: `error.SequenceGap`, and no SQL executes.
+ The session id is unknown: `error.UnknownSession`, and no SQL
  executes.

Only the last result is retained. That bound is why exactly one
sequence may be outstanding. The retry rule follows from the case
list. On an ambiguous outcome, retry the same session and the same
sequence with the same statement. Never re-execute blindly. The retry
either lands as the first execution or replays the recorded result.

```zig
const session = try node.openSession();
const sql = "insert into items(v) values ('x')";
const first = try node.execIdempotent(session, 1, sql);
// Ambiguous outcome? Retry the SAME sequence. Never re-execute blindly.
const again = try node.execIdempotent(session, 1, sql);
std.debug.assert(again.replayed and again.changes == first.changes);
```

Two helpers round out the surface. `checkSession(session_id, sequence)`
runs the same validation without executing anything. `expireSessions(retain)`
bounds the session table: as a normal replicated write, it deletes
every session more than `retain` session writes behind the newest one.
An expired id fails closed with `error.UnknownSession`.

== Reads: `query` and `queryPrepared`

`query(gpa, sql)` and `queryPrepared(gpa, sql, values)` run one
read-only statement. A write hiding inside a read is rejected with
`error.WriteInReadQuery`. The returned `QueryResult` owns its memory
through an internal arena on the `gpa` you pass. Column names and cell
bytes are copies. Nothing borrows from the node. You call
`rows.deinit()` exactly once. Cells arrive as SQLite text conversions,
typed `?[]const u8`, with `null` preserved.

```zig
var rows = try node.query(gpa, "select id, v from items order by id");
defer rows.deinit();
for (rows.rows) |row| std.debug.print("{s}\n", .{row[1] orelse "null"});
```

Which connection serves the read depends on the member. A node holding
the live capture connection reads through it. Any other member opens a
short-lived connection against the materialized image. A fresh member
with no image yet reports `error.NoDatabaseImage`.

Read levels (`any`, `leader`, `linearizable`) are the transport host's
vocabulary, defined in chapter 8. A `Node`-level query always answers
from the local applied state. On a single durable node that state is by
definition current, so every read is linearizable.

== Maintenance surface

#table(
  columns: (auto, 1fr),
  table.header([*Call*], [*Contract*]),
  [`snapshot()`], [Online checkpoint. It materializes every committed
    frame, seals the epoch with a stop sign, installs the snapshot
    generation, and starts the next epoch. One-member only (asserted).
    Cluster hosts call `prepareCheckpoint()` and finish with
    `completeClusterRollover()` once the stop sign is decided. No write
    may be in flight (`error.WriteInFlight`).],
  [`backup(destination)`], [Streams a consistent logical backup
    (`VACUUM INTO`) to a path. `openBackup()` instead returns a
    `BackupHandle` carrying the file, its size, and its SHA-256 for
    bounded streaming. The caller must `close` the handle, which
    deletes the temporary image.],
  [`contentHash() ![32]u8`], [Deterministic digest of the logical
    database content. Identical applied history gives an identical
    digest.],
  [`integrityCheck() !IntegrityReport`], [Verifies three things: the
    SQLite image (`sqlite_ok`), the descriptor chain across the decided
    epoch (`chain_ok`), and payload availability plus descriptor
    agreement (`payloads_ok`). `report.ok()` folds the three.],
  [`status() Status`], [A point-in-time view returned by value: node
    and database identity, configuration id, protocol role and product
    node type, leader, ballot, decided and applied slots, journal
    record count, the 2,048-slot epoch capacity, chain hash, page size,
    and installed snapshot name. The `role` and `node_type` strings are
    static.],
)

== Advanced: hosting the transport yourself

Everything above assumed the node drives itself. A cluster member does
not. Its host owns the sockets, so the host must also drive the
protocol, exactly as `server.zig` does. Most embedders should reach for
the `Embedded` facade in chapter 10 instead. Read this section when you
are building your own transport.

#table(
  columns: (auto, 1fr),
  table.header([*Call*], [*What it does*]),
  [`stepEnvelope(envelope)`], [Processes one protocol message from a
    peer.],
  [`tickProtocol()`], [Advances election, heartbeat, and retransmission
    timers. The host calls it on a steady cadence.],
  [`peerReconnected(peer)`], [Repairs protocol traffic after the
    transport re-establishes a peer connection.],
  [`requestCatchUp(peer)`], [Requests decided entries this node is
    missing, starting after its applied slot.],
  [`learnChosen(...)`], [Accepts a voter-certified chosen entry on a
    non-voting learner. The arguments are the sender, the slot, and the
    entry.],
  [`campaign()`], [Starts phase one explicitly.],
)

Each of these journals and fsyncs its durable effects before any
outbound envelope is queued. Sync-before-send is enforced inside the
node. It is not left to the host. Outbound messages accumulate in
`node.outbox`. The host drains the outbox after every protocol or
write call, then calls `clearRetainingCapacity()` on it. This is
exactly what `server.zig` does.

The remaining obligations are flags the host must poll and obey:

+ `needsResync()` demands `resyncImage()` before further service.
+ `ensureWriter()` opens the capture connection when leadership is
  gained.
+ `epochNearlyFull()` demands a checkpoint before the next append.
+ `storageFailed()` means stop voting and stop serving. Talking after
  a failed fsync would violate the effects contract.

`isLeader()`, `currentLeader()`, `pendingBatchId()`, and `lastAppend()`
complete the read-only view.

#exercise(1, [
  Write a program that opens a node, opens a session, and inserts one
  row with `execIdempotent` at sequence 1. Run the same call a second
  time. Predict the `changes`, `slot`, and `replayed` fields of both
  results before you run it. Then call sequence 3 and explain the error
  you get.
], hint: [
  Only one sequence may be outstanding, and only the last result is
  retained.
])

#teach_back([
  Without rereading, write down the ordered steps between
  `node.exec(sql)` being called and its `ExecResult` returning on a
  one-member node. Mark which steps are fsynced. Then reread the module
  comment at the top of `zaxonlite/src/node.zig` and list any step you
  missed or reordered. Most first attempts misplace the payload sync
  relative to the log append.
])
