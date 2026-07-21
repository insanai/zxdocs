#import "theme.typ": *
#import "figures.typ": *

= The product

#objectives([
  By the end of this chapter you should be able to state what an
  acknowledged write promises, explain why replicating WAL frames makes
  nondeterministic SQL safe, name the five node types and what each one
  may do, and list the things Zaxonlite refuses to do.
])

You have already run the product. In chapter 1 you built `zaxon`, wrote
through a cluster, and killed its leader. This chapter states precisely
what those commands promised you. Hold the book to these statements.
Chapter 17 maps each one to the test that exercises it.

== What Zaxonlite is

Zaxonlite is SQLite with a replicated, crash-consistent history. Your
application links one Zig library, or the C ABI, and opens one data
directory. It gets a full SQL database. Every committed write transaction
is decided by Multi-Paxos and recorded in a checksummed journal before it
is acknowledged. One library and one on-disk layout serve two deployments.

+ *One durable node* is a single process with no network. Every write is
  fsynced through the journal. This is the upgrade path for an application
  that outgrew plain SQLite's durability story.
+ *Role-aware clusters over TCP* run Paxos across one to nine configured
  voters. Witnesses vote without campaigning. Standbys and read replicas
  learn chosen entries without changing the quorum. Stateless gateways
  route clients.

The companion CLI is `zaxon`, the binary from chapter 1. With `--data` it
embeds a node directly. With `--connect` it speaks the client RPC protocol
to running servers and follows leader redirects on its own. Chapter 2
documents every command.

#callout(title: [Security model and current status], tone: "warning")[
  Zaxonlite is a single-application database, not a multi-user SQL server.
  The application authenticates its users and decides what SQL to issue.
  Production TCP is mutual TLS 1.3 only. Protocol v6 can still layer the
  optional shared-PSK challenge inside TLS. An explicit PSK-only development
  mode is restricted to numeric loopback, while plaintext TCP exists solely
  behind the failpoint-gated test switch. Mutual TLS
  (`--tls-cert`/`--tls-key`/`--tls-ca`) gives every node a certificate chained
  to one cluster CA, binds a peer connection to the node id its certificate
  names, and encrypts the wire. After the initial CA and issuer identity are
  provisioned, the one-time token/CSR flow automates issuance for a node
  already in the static registry without sending its private key. A single
  local node can instead serve over an
  owner-only Unix-domain socket (`--listen unix:<path>`), where filesystem
  permissions are the boundary.
  A narrow SQLite invariant guard screens every application statement:
  transaction control, `ATTACH`/`DETACH`, the reserved `__zaxon_*`
  namespace, and capture-critical pragmas are denied at prepare time, and
  loadable SQLite extensions are compiled out. The guard protects
  replication invariants for a trusted application; it is not a sandbox or
  multi-user RBAC. The detailed security plan is in
  `docs/zds/records/0003-zaxonlite-security-remediation-plan.typ`.
]

== The one idea

Most replicated-SQLite systems replay SQL text on every node, and hope the
replicas compute identical results. Hope is the weak point. One call to
`random()` and two replicas can disagree forever.

Zaxonlite replicates the bytes SQLite itself committed: the page frames of
the write-ahead log. The leader executes a transaction once. It captures
exactly the frames SQLite appended for that transaction, and it replicates
those frames. Nondeterministic SQL is therefore safe by construction.
`random()`, `randomblob()`, and date functions all resolve on the leader,
one time. The thing being decided is the page images, not the recipe that
produced them.

#callout(title: "Consequence: byte-identical replicas", tone: "decision")[
  Applying a committed frame payload is a deterministic page write plus a
  truncate. Given the same base image and the same decided history, every
  member's database file converges to the same bytes. The verification
  suite checks this literally. It compares SHA-256 digests of
  `VACUUM INTO` images across all three cluster members.
]

== User-visible guarantees

Five statements carry the product. Each is a claim you can test.

+ *Acknowledged means durable and decided.* A write is acknowledged only
  after three facts hold. Its descriptor is committed by the configured
  voter quorum. Its journal records are fsynced. The slot has been applied
  locally.
+ *Exactly-once retry.* A client session executes sequence $n$ at most
  once. Retrying the last sequence returns the recorded result without
  executing SQL. That holds across process crashes, leader changes, and
  restarts. Gaps and expired sequences fail without side effects. You used
  this in chapter 1; chapter 8 states the full contract.
+ *One-writer serializability.* All writes flow through the current
  leader, one replicated transaction at a time. A dependent slot is never
  proposed before its predecessor is chosen.
+ *Read levels you can name.* `any` reads locally, and may be stale on a
  follower; the response says so. `leader` reads the leader's applied
  state. `linearizable` first completes a quorum read fence.
+ *The journal is the database.* The SQLite file is a materialized image.
  Delete it, or restore a stale copy, and the node converges back to the
  decided state from snapshot plus journal suffix. You did this to
  `current.db` in chapter 1. Chapter 6 walks through the machinery.

#predict([
  A `linearizable` read must prove to a quorum that the leader still
  leads. Does that proof append to the log or sync any disk? Decide
  before reading on.
])

It does neither. The read fence is a quorum round with no log append and
no disk sync. Chapter 8 shows the fence message flow and what a failed
fence means for the client.

== Node types

Zaxonlite defines five node types. `data-voter` proposes, votes,
materializes SQLite, and serves SQL. `witness` votes and stores durable
payloads, but it cannot campaign and cannot serve SQL. `standby` and
`read-replica` are non-voting learners of the chosen log, each holding a
SQLite copy. Only the standby is marked promotion-eligible. `gateway` is a
byte-transparent router. It holds no Paxos state and no SQLite state.

#book_figure([
  Only the voters decide writes. The learners below them receive certified
  commits, so adding a standby or a read replica never changes the write
  quorum.
], cluster_topology())

== Quorum and scaling

For a voter set $V$, the majority is $q=floor(|V|/2)+1$. Learners are
absent from $V$, so adding them does not change the write quorum. The
implementation profile bounds voters at nine but allocates the total
member registry at runtime. That is a scaling boundary. It is not a
promise that millions of all-to-all sockets are practical.

== Explicit non-goals

Zaxonlite does not do multi-master writes. It does not do cross-database
transactions or SQL-visible replication controls. It does not replace a
failed voter automatically. It bounds one epoch at 2,048 slots and one
consensus group at nine voters. Both bounds are policy choices of the
`ReplicatedLog` instantiation, not Paxos theorems.

#teach_back([
  Explain to a colleague why `select random()` can never make two replicas
  diverge, and exactly what the acknowledgment promised when your chapter
  1 write returned `1 row(s) changed`. Use the words frames, quorum, and
  journal.
])
