#import "theme.typ": *

= The three-voter cluster

== Topology

`zaxon serve` hosts one node behind one TCP endpoint that carries both
peer and client traffic (the first frame on any connection is a `hello`
that says which). Each member dials one outgoing connection to every
peer and sends only on it; inbound connections are receive-only. The
result is a full mesh with unambiguous stream ordering per direction,
automatic reconnect with backoff, and protocol repair
(`reconnected`) on every re-establishment.

Threads are few and boring by design: one accept loop, one reader per
connection, one sender per peer (owning a bounded frame queue), one tick
thread driving elections, heartbeats, and retransmission. A single mutex
guards the node; the write path's fsyncs serialize under it exactly as
the ordering contract requires.

== Identity and membership

All members are configured with the same member list; the shared
`database_id` is derived deterministically from the sorted member ids
(plus an optional `--cluster-id`), so a mis-configured process cannot
join the wrong database — the `hello` handshake rejects it. Election
priority is the node id, giving deterministic tie-breaking without
affecting safety.

== Payload gating: votes never outrun bytes

The correctness-critical transport rule: *a member never processes an
accept or commit whose payload bytes are not durable in its local
store.*

+ The leader pushes `payload_data` on the same ordered stream *before*
  the first accept that references its hash (deduplicated per
  connection); TCP ordering makes the payload arrive first.
+ If a receiver still lacks the payload (reconnect races, drops), it
  *holds* the envelope in a bounded queue, requests the payload by hash,
  and only steps the envelope after the bytes are stored and fsynced.
  Bounded means bounded: overflow drops the envelope and Paxos
  retransmission recovers it.

Because a follower stores the payload before it votes, any chosen value
has its bytes durable at a write quorum — the recovery path can always
fetch by digest from some surviving voter, and a node missing a payload
for a committed slot refuses to serve rather than invent state.

== Commit, apply, and the follower image

Only the leader executes SQL. Followers learn commits and apply the
payload pages offline to `current.db` — the same deterministic apply as
recovery. When leadership changes, the old leader's live WAL may hold
frames Paxos never decided (its in-flight write lost the slot); the host
detects every such case in commit accounting, closes the capture
connection, discards the WAL, and rebuilds the image from the decided
log before serving again.

#callout(title: "Epoch fencing on the wire", tone: "note")[
  Every envelope frame carries the sender's configuration id. Frames
  from an older epoch are dropped; frames from a newer epoch mean this
  member missed a sealed rollover and triggers a snapshot transfer. The
  Paxos messages themselves never cross epochs.
]

== Catch-up and snapshot transfer

Within an epoch, a lagging member is repaired by the core protocol:
reconnection sends `learn`, the leader resends missing commits, and the
tick loop requests catch-up whenever heartbeats reveal a decided slot
ahead of the local one. Across a sealed epoch the journal alone is not
enough: the member requests a snapshot, the peer streams the installed
generation (manifest, then the database image in 1-MiB chunks), and the
receiver verifies the digest, installs `CURRENT` and `identity`, starts
the new epoch's journal empty, rebuilds its image from the snapshot, and
catches up the suffix normally. The cluster test exercises exactly this:
a member stopped across a rollover rejoins and converges to
byte-identical content.

== Failpoints

The crash matrix is automated with process-killing failpoints
(`_exit(137)`, no cleanup — a SIGKILL at a chosen line): before/after
payload sync, after journal append, after journal sync, before follower
apply, and before the client reply. A test controller arms them at
runtime through an RPC that only servers started with
`--enable-failpoints` honor. The cluster scenario's centerpiece kills
the leader *after quorum choice, before the client reply*, retries the
same session sequence at the new leader, and proves the write applied
exactly once.
