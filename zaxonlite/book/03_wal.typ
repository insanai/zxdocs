#import "theme.typ": *

= WAL-frame replication

== Why frames, not SQL

Replaying SQL text on replicas requires every statement to be
deterministic, every schema hook to fire identically, and every SQLite
version to behave the same. WAL-frame replication removes the whole
class: the leader's SQLite computes the transaction once, and consensus
decides the resulting page images. dqlite and rqlite arrived at related
designs by patching or wrapping SQLite; Zaxonlite's Phase-0 spike proved
the capture can be done with *public, stable* SQLite interfaces only.

== The capture technique (decided ADR)

The node runs one writer connection in WAL mode with automatic
checkpoints disabled:

```text
pragma journal_mode = wal;        -- append frames, never rewrite pages
pragma wal_autocheckpoint = 0;    -- checkpoints only at snapshots
pragma synchronous = normal;      -- journal fsync is the durability
sqlite3_wal_hook(db, hook, ...)   -- committed frame count per commit
```

After every commit, the hook reports the total number of committed frames
in the WAL. The frames between the previous count and the new count are
exactly this transaction's committed pages, and their bytes are read
directly from the `current.db-wal` file: a 32-byte WAL header, then
per-frame 24-byte headers (big-endian page number at offset 0, commit
size at offset 4) followed by the raw page image. A rolled-back
transaction never advances the hook count, so its frames are invisible
to capture.

#callout(title: "Why this is safe to read directly", tone: "note")[
  Only the capture connection writes the WAL, checkpoints are disabled,
  and capture happens synchronously after `COMMIT` returns and before the
  next write begins. The `[from, to)` frame range is immutable by the
  time it is read. The one WAL subtlety that matters — cumulative frame
  checksums seeded per-WAL — is irrelevant because Zaxonlite never
  splices frames into another WAL; it applies pages offline.
]

== The apply technique

A committed payload is applied *offline* — no SQLite connection open on
the file:

+ for each frame, write the page image at
  `(page_number - 1) * page_size`;
+ truncate the file to the commit frame's database size in pages;
+ fsync.

Given the same base image and the same frames, this transition is
deterministic and idempotent: applying any decided prefix again from any
intermediate state converges to the same bytes. That single property
powers recovery (rebuild from snapshot plus suffix), follower apply, and
leadership-change resync, and makes crash timing across the whole apply
path harmless.

== The proof: byte-identical rebuild

The spike test — kept as a permanent unit test — runs DDL with triggers
and indexes, DML, 20-KiB blobs, savepoints with partial rollbacks,
`ALTER TABLE`, full rollbacks, and nondeterministic
`randomblob()`/`random()` traffic on a live database while capturing
every committed transaction. It then applies the captured payloads
offline to a second image and compares the files *byte for byte* after a
truncating checkpoint of the original. The seeded fuzz harness extends
the same oracle to randomized workloads with restarts, torn journal
tails, and image deletion.

== The fallback that was not needed

The plan reserved a custom VFS (intercepting `xWrite` on the WAL) as
fallback if public interfaces proved insufficient. They did not; the VFS
remains a documented escape hatch should a future SQLite change the WAL
contract.
