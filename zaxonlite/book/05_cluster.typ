#import "theme.typ": *

= Role-aware clusters

== Topology

`zaxon serve` hosts one node behind one TCP endpoint that carries both
peer and client traffic (the first frame on any connection is a `hello`
that says which). Voters dial every storage node; learners dial only voters so
they can return payload ACKs and requests. Learner-to-learner links carry no
protocol information and are omitted. A connection sends in one direction;
inbound connections are receive-only. Gateways proxy client streams and never
enter this topology. The result has unambiguous stream ordering per direction,
automatic reconnect with backoff, and protocol repair
(`reconnected`) on every re-establishment.

Threads are few and boring by design: one accept loop, one reader per
connection, one sender per peer (owning a bounded frame queue), one tick
thread driving elections, heartbeats, and retransmission. A single mutex
guards the node; the write path's fsyncs serialize under it exactly as
the ordering contract requires.

== Registry, voter membership, and scale

All nodes are configured with the same role registry; the shared
`database_id` is derived deterministically from the sorted voter ids
(plus an optional `--cluster-id`), so a mis-configured process cannot
join the wrong database — the `hello` handshake rejects it. Election
priority is the node id, giving deterministic tie-breaking without
affecting safety.

Only `data-voter` and `witness` nodes enter Paxos quorums. A data voter may
campaign and materializes SQLite; a witness votes but cannot campaign or serve
SQL. `standby` and `read-replica` are learners: they store the chosen log and
materialize SQLite without sending promises or accepted votes. A standby is
promotion-eligible by an operator; a read replica is not. A `gateway` stores
nothing and routes end-to-end authenticated client connections.
Every registry must contain at least one data voter; an all-witness quorum is
safe but cannot make progress and is rejected at startup.

The first release bounds one Paxos group to one through nine voters so its
fixed-size core state stays reviewable. The allocator-backed product registry
may contain any runtime-sized number of learners and gateways subject to host
resources. Paxos has no theorem limiting a deployment to three or nine nodes;
the implementation bound is deliberate. Adding replicas improves read and
failure placement, not the throughput of SQLite's single writer. Aggregate
write scale requires independent databases or shards.

== Payload gating: votes never outrun bytes

The correctness-critical transport rule: *a member never processes a
value-bearing promise, accept, or commit whose payload bytes are not durable
and digest-verified in its local store.*

+ The sender pushes `payload_data`; the receiver verifies, fsyncs, and
  atomically installs it, then returns `payload_stored`. Only that ACK releases
  matching envelopes from the sender's bounded per-peer gate.
+ If a receiver still lacks the payload (reconnect races, drops), it
  *holds* the envelope in a bounded queue, requests the payload by hash,
  and only steps the envelope after the bytes are stored and fsynced.
  Bounded means bounded: overflow drops the envelope and Paxos
retransmission recovers it.

Promises are gated because the core may complete Phase 1 and emit recovery
accepts in the same `step` transition. Protocol v4 supports provider-file PSK
challenge-response with a fresh nonce, a connection-unique session key, and a
monotonically sequenced HMAC on every post-handshake frame. A wrong proof,
replay, tampering, or version downgrade closes the stream. Without a provider,
the server refuses non-loopback addresses. HMAC does not encrypt SQL;
confidential deployments still need an encrypted tunnel.

Because a follower stores the payload before it votes, any chosen value
has its bytes durable at a write quorum — the recovery path can always
fetch by digest from some surviving voter, and a node missing a payload
for a committed slot refuses to serve rather than invent state.

The leader separately sends `learner_commit(configuration, slot, entry)` to
each non-voter only after the referenced payload has received that learner's
durable storage ACK. This is a chosen-value certificate from a configured
voter, never a vote by the learner. Learners reject other senders, epochs,
conflicting duplicates, and non-contiguous application; they buffer only the
compile-time-bounded reorder window. Reconnect resets the sender cursor and
replays the chosen prefix idempotently. The certifying voter is also the
learner's redirect hint for leader-only requests.

The leader emits a non-voting learner heartbeat every 20 ticks (500 ms with
the default tick) with its current decided slot. A local `any` read may include
`freshness_ms`; it is
rejected if leader contact is older than that bound or if the heartbeat says
the learner is behind. Without a freshness bound, `any` explicitly permits an
arbitrarily stale local snapshot.

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

Within an epoch, a lagging voter is repaired by the core protocol:
reconnection sends `learn`, the leader resends missing commits, and the
tick loop requests catch-up whenever heartbeats reveal a decided slot
ahead of the local one. A learner is repaired by replaying voter-certified
chosen entries. Across a sealed epoch the journal alone is not
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
