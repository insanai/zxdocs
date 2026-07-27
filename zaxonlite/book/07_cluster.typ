#import "theme.typ": *
#import "figures.typ": *

= Role-aware clusters

#objectives([
  By the end of this chapter you should be able to name the five node roles
  and say which of them vote, trace every connection in a running cluster,
  explain why a vote is never processed before its payload bytes are
  durable, and follow a chosen value from the leader to a learner that
  never voted on it.
])

#checkpoint([storage], [
  Chapter 6 defined the journal, the content-addressed payload store, and
  the snapshot generation. This chapter assumes all three. If "payload by
  digest" does not ring a bell, read chapter 6 first.
])

In chapter 1 you started three voters, killed the leader, and watched a
write land anyway. This chapter explains the machinery behind that demo.
Who talks to whom. Who votes. And what every byte must survive before a
node is allowed to act on it.

== Topology

`zaxon serve` hosts one node behind one TCP endpoint. Peer traffic and
client traffic share that endpoint. The first frame on any connection is a
`hello` that says which kind of connection this is. A single local node
may instead listen on a Unix-domain socket (chapter 2); cluster links
always require TCP, so a unix-mode server rejects configured peers.

Connections follow the roles. Voters dial every storage node. Learners dial
only voters, so they can return payload ACKs and payload requests. A link
between two learners would carry no protocol information, so it does not
exist. Each connection sends in one direction only; the inbound side is
receive-only. Every direction therefore has one unambiguous stream order.
Gateways proxy client streams and never appear in the peer topology. Every
link reconnects on its own with backoff, and every re-establishment runs
protocol repair (`reconnected`).

#book_figure([
  Who does what in a full cluster. The three voters vote and decide. The
  standby and the read replica learn chosen values but never vote. The
  gateway routes client connections and stores nothing.
], cluster_topology())

The thread model is direct. There is one accept loop, one reader
per connection, one sender per peer, and one tick thread. Each sender owns
a bounded frame queue. The tick thread drives elections, heartbeats, and
retransmission. A single mutex guards the node. The write path's fsyncs
serialize under that mutex, exactly as the ordering contract requires.
Admission is bounded. The server caps concurrent connections — peers,
clients, and transfer streams together — at four per configured member
plus sixteen by default, sized for a small cluster; an over-limit
connection is closed at accept, and admission is refused during
shutdown. An accepted connection must complete hello and authentication
within a handshake deadline, 10 seconds by default, or the tick loop
closes it. Established connections have a five-minute idle deadline and each
peer is capped at two overlapping inbound connections. Remote SQL additionally
has the row, byte, text, and VM-step budgets described in chapter 13.

== Registry, voter membership, and scale

Every node starts from the same role registry. At bootstrap, when no
decided registry exists yet, the shared `database_id` is derived
deterministically from the sorted voter ids, plus an optional
`--cluster-id`. The derivation runs only then. Afterwards the decided
registry carries the database identity: changed flags cannot re-derive
it, and a conflicting startup is refused (`RegistryMismatch`). A voter
replacement changes the voter set without ever changing the database. A
mis-configured process therefore cannot join the wrong database. The
`hello` handshake rejects it. Election priority is the node id. That
gives deterministic tie-breaking and does not affect safety.

Only two roles enter Paxos quorums: `data-voter` and `witness`. A data
voter may campaign, and it materializes SQLite. A witness votes but cannot
campaign and does not serve SQL. The other storage roles are learners.
A `standby` and a `read-replica` both store the chosen log and materialize
SQLite, but they never send a promise or an accepted vote. A standby is
promotion-eligible by an operator. A read replica is not. A `gateway`
stores nothing and routes end-to-end authenticated client connections;
chapter 12 covers it in detail.

Two registry rules are enforced at startup. Every registry must contain at
least one data voter. An all-witness quorum would be safe, but it could
never make progress, so it is rejected.

The first release bounds one Paxos group to one through nine voters. The
bound keeps the fixed-size core state reviewable. The product registry is
allocator-backed and may hold any runtime-sized number of learners and
gateways, subject to host resources. Paxos has no theorem that limits a
deployment to three or nine nodes. The implementation bound is a choice. Be
clear about what extra replicas buy you: better read placement and better
failure placement. They do not buy write throughput. SQLite has a single
writer. Aggregate write scale requires independent databases or shards.

== The decided registry and voter replacement

A network-hosted `zaxon serve` cluster persists its membership as a
decided registry: the consensus-decided mapping from configuration ID to
node IDs, roles, and endpoints. Bootstrap flags create configuration 1.
From then on the durable registry is authoritative, and conflicting
startup flags are a startup error. Embedded clusters and unix-socket
local nodes keep flag-fixed membership and write no registry.

The registry backs exactly one online membership change: replacing one
data voter with one fresh data voter. The operation is operator-initiated
and privileged. It requires an administrator certificate
(`zaxon-admin-<name>`) named in the server's allow-list, and it needs at
least three voters, because the survivors alone must still satisfy the
sealed configuration's read quorum. Chapter 2 documents the
`zaxon replace-voter` and `zaxon membership status` commands.

The lifecycle rides the epoch machinery from chapter 6:

+ The old configuration's voters choose a stop sign whose `zx2` metadata
  binds the checkpoint, the digest of the next registry, and a bounded
  replacement seed: the operation ID, the old node, the new node, and
  its endpoint. The next registry is therefore a pure function of the
  current registry and the chosen stop sign.
+ Survivors rebuild the next registry deterministically from the seed,
  verify its digest against the decided metadata, and activate it
  through an in-process transport swap: client TCP connections stay
  open, peer senders and admission rebuild from the registry, and
  writes pause briefly. A crash on either side of the durable
  `REGISTRY` pointer converges by restart.
+ The replacement voter enrolls only after the stop is chosen. It
  fetches the decided registry blob during snapshot install, verifies it
  against the quorum-confirmed proof digest, installs it durably, and
  only then votes.
+ The removed voter stays permanently sealed on its final configuration.
  Admission rejects its node ID even with a still-valid certificate, and
  the monotonic node-ID allocation fence retires the ID forever.

Retrying a replacement is idempotent while its record is retained: the
registry keeps a fixed ring of the 32 newest replacement records, and an
expired operation ID is rejected. While an operation runs,
`membership status` reports the live `phase`, `quorum_available`, and
`installation_state` fields (chapter 2). Automatic replacement remains
out of scope: nothing detects a failed voter or chooses its successor
for you.

== Payload gating: votes never outrun bytes

Chapter 5 split a transaction into a small descriptor and a large payload.
The descriptor travels inside Paxos messages. The payload travels beside
them. That split creates a hazard: a message can name bytes its receiver
does not have.

#predict([
  A follower's connection drops and comes back. The leader holds an
  `accept` for slot 40 whose payload the follower may have missed. May the
  leader send the `accept` first and the payload bytes afterwards? Decide
  what could go wrong before reading on.
])

The transport closes the hazard with one correctness-critical rule: a
member never processes a value-bearing promise, accept, or commit whose
payload bytes are not durable and digest-verified in its own local store.
A vote is a durable promise about a value. The rule makes sure the value's
bytes are at least as durable as the vote.

On the normal path, the sender enforces the rule:

#transcript((
  [1], [Leader], [Builds an `accept` for slot 40 that names payload hash
    `h`. It holds no storage ACK for `h` from voter 2 yet.],
  [2], [Leader], [Queues `payload_data` carrying `h` and then the dependent
    `accept` on the same ordered stream. Its own journal barrier runs in
    parallel.],
  [3], [Voter 2], [Recomputes the digest over the received bytes. On a
    match it fsyncs and atomically installs the object in its payload
    store.],
  [4], [Voter 2], [Only after storage completes does its read loop reach the
    adjacent `accept`. It may also return `payload_stored` to cache readiness.],
  [5], [Voter 2], [Verifies `h` against its store, journals the accept, crosses
    its own barrier, and only then returns `accepted`. The vote cannot outrun
    the bytes.],
  [6], [Leader], [Processes `accepted` only after the leader's own barrier has
    completed, so no volatile local vote can count toward the quorum.],
))

Races can still deliver an envelope early. A reconnect or a dropped frame
can hand a receiver an `accept` whose payload it lacks. Then the receiver
enforces the rule itself:

+ It holds the envelope in a bounded queue. It does not step it.
+ It sends `payload_request` for the missing hash.
+ When `payload_data` arrives, it stores and fsyncs the bytes, then steps
  every held envelope for that hash.
+ Bounded means bounded. On overflow the envelope is dropped, and Paxos
  retransmission recovers it later.

Why are promises gated too? Because the core may complete phase one and
emit recovery accepts inside the same `step` transition. A promise can
carry a value the new leader must re-propose. Its bytes must be present
before the step runs.

The reward for this discipline is a strong invariant. A follower stores
the payload before it votes. So any chosen value has its bytes durable at
a write quorum. Recovery can always fetch the payload by digest from some
surviving voter. And a node missing a payload for a committed slot refuses
to serve rather than invent state.

#callout(title: [Production TCP is mTLS], tone: "warning")[
  Protocol v7 can authenticate possession of a provider-file PSK with a
  challenge-response: a fresh nonce, a connection-unique session key, and a
  monotonically sequenced HMAC on every post-handshake frame. A wrong
  proof, a replay, tampering, or a version downgrade closes the stream.
  The same PSK is used by all nodes and clients, while the plain `hello`
  supplies the claimed peer ID and connection kind. It therefore does not
  authenticate a distinct configured node, and HMAC does not encrypt SQL
  or page data. The mutual TLS transport closes both gaps: with
  `--tls-cert`/`--tls-key`/`--tls-ca`, every TCP connection — peer and
  client — runs TLS 1.3 with certificates verified against the cluster CA
  in both directions, and a peer connection's certificate common name must
  be exactly `zaxon-node-<id>` for the node id its hello claims, checked
  on the accepting and the dialing side alike. The mechanisms compose:
  when both are configured, the PSK challenge runs inside the TLS
  channel. Production startup rejects every TCP listener without TLS. The
  narrow `--dev-psk` exception is explicit and numeric-loopback-only; it is
  useful for the one-machine quickstart but retains the PSK's identity and
  confidentiality limits. Plaintext TCP remains behind a failpoint-gated test
  option. A local single-node service can use the owner-only Unix-domain socket
  instead (chapter 2).
]

Certificate bootstrap is intentionally smaller than cluster membership.
An existing mTLS operator may request a one-time token for a non-revoked node
already named in the decided registry. That node creates its key and CSR
locally, and the configured issuer signs only the exact `zaxon-node-<id>`
identity. Token issuance checks the decided registry, so a replacement voter
can enroll only after the stop sign choosing its membership is decided. The
exchange neither changes the voter set nor grants a new role. Chapter 13 gives
the operational sequence.

== How a learner learns

A standby or a read replica holds a full copy of the database, yet it never
votes. So how does it find out what was chosen? The leader tells it, with a
certificate.

The message is `learner_commit(configuration, slot, entry)`. It is not a
vote, and the learner never treats it as one. It is a statement from a
configured voter that this slot was chosen with this entry. The leader
sends it only after the referenced payload has received that learner's
durable storage ACK. Learners pass through the same payload gate as
voters.

#transcript((
  [1], [Leader], [Applies slot 41. Its cursor for the standby still reads
    slot 40, so the standby is behind.],
  [2], [Leader], [Reads the entry at slot 41. It names payload hash `h`,
    and the standby has not ACKed `h`. Sends `payload_data` first.],
  [3], [Leader], [Encodes `learner_commit` for slot 41 and gates it behind
    the storage ACK for `h`. Advances the cursor once the certificate is
    queued.],
  [4], [Standby], [Stores and fsyncs the payload, then replies
    `payload_stored`.],
  [5], [Leader], [The ACK releases the certificate, and `learner_commit`
    goes out.],
  [6], [Standby], [Checks that the sender is a configured voter and that
    the epoch matches. Verifies `h` in its store. Journals the entry and
    applies it in contiguous slot order. Remembers the sender as its
    leader hint.],
))

A learner checks the claimed sender against its registry. It rejects
certificates from claimed non-voters. Under the PSK transport this is a
protocol invariant, not a hostile-peer security boundary, because any PSK
holder can claim a configured voter ID in the hello; under mutual TLS the
claimed peer ID is additionally bound to the sender's certificate name. It rejects other epochs and
conflicting duplicates. It applies slots
only contiguously and buffers at most a compile-time-bounded reorder
window. A reconnect resets the leader's cursor and replays the chosen
prefix; the replay is idempotent. The certifying voter also serves as the
learner's redirect hint when a client sends it a leader-only request
(chapter 12).

A learner also needs to know how fresh it is. The leader emits a learner
heartbeat every 20 ticks, which is 500 ms at the default tick, carrying its
current decided slot. A local `any` read may include `freshness_ms`. The
learner rejects the read if leader contact is older than that bound, or if
the heartbeat says the learner is behind. Without a freshness bound, `any`
explicitly permits an arbitrarily stale local snapshot. Chapter 8 places
`any` in the full read-level contract.

== Commit, apply, and the follower image

Only the leader executes SQL. A follower never replays SQL text. It learns
commits and applies the payload pages offline to `current.db`, using the
same deterministic apply that recovery uses. Every follower image is
therefore a function of the decided log alone.

Leadership changes create one subtle hazard. The old leader's live WAL may
hold frames Paxos never decided, because an in-flight write lost its slot
to the new leader. The host detects every such case in commit accounting.
It closes the capture connection, discards the WAL, and rebuilds the image
from the decided log before serving again. No undecided frame can leak
into the served database.

#callout(title: [Epoch fencing on the wire], tone: "note")[
  Every envelope frame carries the sender's configuration id. A frame from
  an older epoch is dropped. A frame from a newer epoch means this member
  missed a sealed rollover, and it triggers a snapshot transfer. The Paxos
  messages themselves never cross epochs.
]

== Catch-up and snapshot transfer

A member can fall behind in two ways. Each way has its own repair.

Within an epoch, the core protocol repairs a lagging voter. Reconnection
sends `learn`. The leader resends missing commits. The tick loop requests
catch-up whenever heartbeats reveal a decided slot ahead of the local one.
A lagging learner is repaired the same way it learns everything else: the
leader replays voter-certified chosen entries.

Across a sealed epoch, the journal alone is not enough. The member requests
a snapshot instead. The peer streams the installed generation: the manifest
first, then the database image in 1-MiB chunks. The receiver verifies the
digest, installs `CURRENT` and `identity`, starts the new epoch's journal
empty, rebuilds its image from the snapshot, and catches up the remaining
suffix normally. The cluster test exercises exactly this path: a member
stopped across a rollover rejoins and converges to byte-identical content.

#callout(title: [Snapshot transfer confirms the existing proof], tone: "note")[
  Normal rollover already gets consensus on the physical snapshot: the
  versioned stop metadata (`zx1 <name> <manifest-sha256>` on a
  registry-less host, `zx2` with the next-registry digest on a
  registry-backed server) is the decided Paxos stop sign, and every
  caught-up member independently requires the same digest. The receive
  path carries a canonical `ZXP2` proof encoding of that stop sign. The
  authenticated source counts as one matching voter report, and the receiver
  obtains enough independent matching probe replies to form a read quorum
  before replacing state. It then verifies the manifest and physical image.
  This is neither a second consensus phase nor signatures over SQLite files.
]

== Failpoints

How do we know the crash matrix in chapter 8 holds on a real cluster? We
kill real processes at chosen lines. A failpoint calls `_exit(137)` with no
cleanup, which behaves like a SIGKILL at that line. The sites bracket the
write path: before and after payload sync, after journal append, after
journal sync, before follower apply, and before the client reply. A test
controller arms them at runtime through an RPC. Only servers started with
`--enable-failpoints` honor it. Zaxonlite intentionally has no internal
administrator role, so every caller admitted to this single-principal
interface could invoke an enabled failpoint. Never enable it outside
disposable tests.

The cluster scenario's centerpiece is the retry you will meet again in
chapter 8. It kills the leader after quorum choice and before the client
reply. It retries the same session sequence at the new leader. And it
proves the write applied exactly once.

#exercise(7, [
  Extend the chapter 1 cluster with a read replica: start a fourth node
  with `--role read-replica` and list it on every voter as
  `--peer 4@.../read-replica`. Write through the cluster, stop the
  replica, write again, and restart it. Explain which messages repair it,
  why it never affected the write quorum, and what an `any` read against
  it can and cannot promise.
], hint: [
  The repair is the learner path: payload data, storage ACK, then
  voter-certified `learner_commit` replay from the leader's reset cursor.
])

#teach_back([
  Explain payload gating to a colleague in four sentences. Name the rule,
  name who enforces it on the normal path, name who enforces it after a
  reconnect race, and finish with the invariant it buys: every chosen
  value has its bytes durable at a write quorum.
])
