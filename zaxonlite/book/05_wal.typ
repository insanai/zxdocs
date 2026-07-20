#import "theme.typ": *
#import "figures.typ": *

= WAL-frame replication

#objectives([
  By the end of this chapter you should be able to explain why Zaxonlite
  replicates page images instead of SQL text, walk one committed
  transaction from `COMMIT` to a named payload, apply a captured payload
  to an offline database file by hand, and state the determinism
  property that recovery, follower apply, and resync all rely on.
])

#checkpoint([write path], [
  Place "capture the committed frames" inside chapter 4's write-path
  transcript without looking back. If you cannot say what is already
  durable at that step, reread the write path first.
])

This is the one-idea chapter of the book. Everything else in Part II is
careful engineering around a single decision: consensus decides page
images, not SQL. Take the time to understand this chapter and the rest
of the machine follows from it.

== Why frames, not SQL

Suppose we replicated the SQL text instead, and had every replica
execute each statement locally. Now consider one statement:

```sql
insert into audit(token) values (randomblob(16));
```

Every replica computes a different blob. The databases diverge, and no
error tells you so. Nondeterministic functions are only the most obvious
hazard. To make SQL replay safe, every statement must be deterministic,
every schema hook must fire identically, and every SQLite version in the
cluster must behave the same. Each of those is a standing obligation on
every future application and every future upgrade.

WAL-frame replication removes the entire class. The leader's SQLite
computes the transaction once. Consensus then decides the resulting page
images. A replica applies bytes; it never re-executes anything, so
determinism of the SQL stops mattering. dqlite and rqlite arrived at
related designs by patching or wrapping SQLite. Zaxonlite's Phase-0
spike proved the capture can be done with public, stable SQLite
interfaces only.

#book_figure([
  One committed transaction, from SQLite pages to log identity. The page
  images travel as a SHA-256-named payload. Paxos decides only the
  fixed-size descriptor that names them.
], wal_capture())

== The capture technique

First, a fact about SQLite in WAL mode: a commit never rewrites a page
in the main database file. It appends the new page images to
`current.db-wal` as frames. A later checkpoint folds frames back into
the main file. Zaxonlite's node runs one writer connection configured so
that capture can trust this behavior:

```text
pragma journal_mode = wal;        -- append frames, never rewrite pages
pragma wal_autocheckpoint = 0;    -- checkpoints only at snapshots
pragma synchronous = normal;      -- journal fsync is the durability
sqlite3_wal_hook(db, hook, ...)   -- committed frame count per commit
```

With automatic checkpoints disabled, the WAL only grows between
snapshots, and a written frame is never moved or rewritten. That
stability is what makes the next step legal.

After every commit, the hook reports the total number of committed
frames now in the WAL. We remember the previous total. The frames
between the old count and the new count are exactly this transaction's
committed pages. We read their bytes directly from the file, and the
layout is fixed:

+ the file starts with a 32-byte WAL header;
+ each frame is a 24-byte frame header followed by the raw page image;
+ the frame header stores the page number big-endian at offset 0 and
  the commit size, the database size in pages, at offset 4.

A rolled-back transaction never advances the hook count, so its frames
are invisible to capture. Rollbacks cost the cluster nothing.

Here is one insert moving through the whole pipeline. The frame numbers
are illustrative; the mechanics are exact.

#transcript((
  [1], [You], [Run `insert into notes(body) values ('hello')` through
    the leader.],
  [2], [SQLite], [Appends the changed pages to `current.db-wal` as
    frames 13 and 14, then returns from `COMMIT`.],
  [3], [Hook], [Fires with a committed frame count of 14. The previous
    count was 12, so this transaction owns frames 13 and 14.],
  [4], [Capture], [Reads both frames straight from the file: two
    24-byte headers and two raw page images.],
  [5], [Capture], [Builds the `ZXPL` payload and hashes it. The SHA-256
    becomes the payload's name in the store and the `payload_hash` in
    the descriptor.],
  [6], [Consensus], [Decides the descriptor. The page images travel to
    voters through the payload store, never inside a Paxos message.],
))

#callout(title: "Why reading the file directly is safe", tone: "note")[
  Only the capture connection writes the WAL. Checkpoints are disabled.
  Capture runs synchronously after `COMMIT` returns and before the next
  write begins. So the `[from, to)` frame range is immutable by the time
  it is read. The WAL format has one famous subtlety: frame checksums
  are cumulative and seeded per WAL file. It does not matter here,
  because Zaxonlite never splices frames into another WAL. It applies
  pages offline instead.
]

== The apply technique

A committed payload is applied offline. No SQLite connection is open on
the file while it happens. The whole algorithm is three steps:

+ for each frame, write the page image at byte offset
  `(page_number - 1) * page_size`;
+ truncate the file to the commit frame's database size in pages;
+ fsync.

SQLite is not consulted at apply time. We are performing the same page
placement a checkpoint would perform, with nothing else in the way.

Now the property everything depends on. Given the same base image and
the same frames, this transition is deterministic. It is also
idempotent: applying any decided prefix again, from any intermediate
state, converges to the same bytes. One property, three payoffs. It
powers recovery, which rebuilds from a snapshot plus the committed
suffix. It powers follower apply, which materializes the image offline.
It powers resync after a leadership change. It also makes crash timing
across the entire apply path harmless, because a half-applied batch is
repaired by applying it again.

== The proof: byte-identical rebuild

#predict([
  The test workload below includes `randomblob()` and `random()`. Can a
  second database built only from captured frames still match the
  leader's file byte for byte? Decide, and say why, before reading on.
])

It can, and the reason is the point of this chapter. The nondeterminism
is resolved exactly once, on the leader, when SQLite executes the
transaction. The frames carry the outcome, not the recipe. A replica
applying those frames cannot diverge, because it never rolls the dice.

The spike test, kept as a permanent unit test, runs a hostile workload
on a live database while capturing every committed transaction: DDL with
triggers and indexes, DML, 20-KiB blobs, savepoints with partial
rollbacks, `ALTER TABLE`, full rollbacks, and nondeterministic
`randomblob()`/`random()` traffic. It then applies the captured payloads
offline to a second image, checkpoints the original with truncation, and
compares the two files byte for byte. The seeded fuzz harness extends
the same oracle to randomized workloads with restarts, torn journal
tails, and image deletion.

== The fallback that was not needed

The plan reserved a custom VFS as a fallback: intercept `xWrite` on the
WAL file if the public interfaces proved insufficient. They did not
prove insufficient. The VFS remains a documented escape hatch in case a
future SQLite release changes the WAL contract.

#exercise(5, [
  Watch a WAL frame with your own eyes. In a scratch directory, open a
  database with the `sqlite3` shell, set `pragma journal_mode = wal` and
  `pragma wal_autocheckpoint = 0`, create a table, and insert one row.
  Hexdump the `-wal` file. Find the 32-byte WAL header, the first
  24-byte frame header, and the big-endian page number at its offset 0.
  Then insert a second row and explain which bytes changed.
], hint: [
  Each frame occupies 24 bytes plus one page. `pragma page_size` tells
  you the page size, so frame $n$ starts at byte $32 + (n - 1) times
  (24 + "page_size")$.
])

#teach_back([
  Explain to a colleague why `randomblob()` is fatal to SQL-statement
  replication and harmless to WAL-frame replication. Use the words
  execute, capture, and apply, and name the one place in the cluster
  where nondeterminism is allowed to run.
])
