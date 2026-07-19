#import "theme.typ": *

= The product

== What Zaxonlite is

Zaxonlite is SQLite with a replicated, crash-consistent history. An
application links one Zig library (or the C ABI), opens one data
directory, and gets a full SQL database whose every committed write
transaction is decided by Multi-Paxos and recorded in a checksummed
journal before it is acknowledged. The same library and the same on-disk
layout serve two deployments:

+ *one durable node*: a single process, no network, every write fsynced
  through the journal — an upgrade path for any application that outgrew
  plain SQLite's durability story;
+ *three voters over TCP*: three `zaxon serve` processes elect a leader,
  replicate WAL frames, survive the loss of any one machine, and catch a
  restarted or reimaged member back up automatically.

The companion CLI is `zaxon`. It embeds a node directly (`--data`) or
speaks the client RPC protocol to running servers (`--connect`),
following leader redirects.

== The one idea

Most replicated-SQLite systems replay SQL text on every node and hope the
replicas compute identical results. Zaxonlite replicates *the bytes
SQLite itself committed*: the page frames of the write-ahead log. The
leader executes a transaction once, captures exactly the frames SQLite
appended for it, and replicates those frames. Nondeterministic SQL —
`random()`, `randomblob()`, dates, all of it — is safe by construction,
because the decision being replicated is the page images, not the recipe
that produced them.

#callout(title: "Consequence: byte-identical replicas", tone: "decision")[
  Applying a committed frame payload is a deterministic page-write plus a
  truncate. Given the same base image and the same decided history, every
  member's database file converges to the same bytes. The verification
  suite checks this literally, with SHA-256 digests of `VACUUM INTO`
  images across all three cluster members.
]

== User-visible guarantees

+ *Acknowledged means durable and decided.* A write is acknowledged only
  after its descriptor is committed by the (one- or three-member) quorum,
  its journal records are fsynced, and the slot has been applied locally.
+ *Exactly-once retry.* A client session executes sequence $n$ at most
  once. Retrying the last sequence returns the recorded result — across
  process crashes, leader changes, and restarts — without executing SQL.
  Gaps and expired sequences fail without side effects.
+ *One-writer serializability.* All writes flow through the current
  leader, one replicated transaction at a time; a dependent slot is never
  proposed before its predecessor is chosen.
+ *Read levels you can name.* `any` reads locally (possibly stale on a
  follower and labeled as such); `leader` reads the leader's applied
  state; `linearizable` first completes a quorum read fence that performs
  no log append and no disk sync.
+ *The journal is the database.* The SQLite file is a materialized image;
  deleting it (or restoring a stale copy) converges back to the decided
  state from snapshot plus journal suffix.

== Explicit non-goals

Zaxonlite does not do multi-master writes, cross-database transactions,
SQL-visible replication controls, or dynamic membership beyond the
snapshot-sealed epoch mechanism. It bounds one epoch at 256 slots and one
cluster at three voters by compile-time configuration; both are policy
choices of the `ReplicatedLog` instantiation, not architectural limits.
