#import "theme.typ": *
#import "figures.typ": *

= Consistency and the client contract

#objectives([
  By the end of this chapter you should be able to classify any write
  outcome as success, failure, or ambiguous, retry an ambiguous write
  without double-applying it, choose a read level and state exactly what
  it guarantees, and reconstruct the safety argument for the quorum read
  fence step by step.
])

#checkpoint([the cluster], [
  Chapter 7 showed how voters decide, and how payload bytes reach a
  quorum before any vote references them. This chapter states what a
  client may rely on because of that machinery. You first used sessions
  in chapter 1; chapter 13 shows the same contract at the wire level.
])

== Write acknowledgement: three outcomes, not two

We would like every write to either succeed or fail. A distributed system
cannot promise that. A reply can be lost after the work is done.

#predict([
  Your `exec` call times out. One second later the cluster is healthy
  again. Did your insert happen? Decide which answers are possible, and
  what a safe client may do next, before reading on.
])

A client write returns one of three outcomes. The distinction is the
contract:

+ *Success.* The slot committed, and the decided value at that slot is
  this client's `batch_id`. The transaction is durable at a quorum and
  applied.
+ *Failure.* The SQL failed and rolled back, or the session sequence was
  rejected. Provably nothing replicated. There is no side effect.
+ *Ambiguous.* An `ambiguous` reply, a timeout, or a connection loss.
  The write may or may not have committed. Both answers to the predict
  question are possible, and the client cannot tell which one happened.

The ambiguous case has exactly one safe response: retry the same session
sequence. Never re-execute the SQL blindly. If the write did commit and
you resend it as a fresh statement, it applies twice. Sessions exist to
make the disciplined retry cheap.

== Exactly-once sessions

A session is a replicated row: `(id, next_sequence, last_sequence,
last_changes, last_activity_slot)`. Every sessioned `exec` carries
`(session, sequence)`. The leader checks the row before it touches SQL:

+ `sequence == last_sequence`: this write already committed. Return the
  recorded result, marked `replayed`. No SQL runs.
+ `sequence == next_sequence`: this is the next write. Execute it. The
  row update rides inside the captured transaction, so the result and
  the data commit atomically or not at all.
+ `sequence < next_sequence - 1` returns `ResultExpired`. `sequence >
  next_sequence` returns `SequenceGap`. An unknown id returns
  `UnknownSession`. None of these execute SQL.

The atomicity in the second rule carries the whole guarantee. The session
row is not bookkeeping beside the data. It commits inside the same decided
value as the data. Whoever holds the data also holds the proof that
sequence `n` was spent.

Walk through the worst case. This is the exact schedule the failpoint
suite kills on purpose (chapter 7):

#transcript((
  [1], [Client], [Opens a session, then sends `exec` with sequence 7, an
    insert.],
  [2], [Leader], [Checks the row: 7 equals `next_sequence`, so it
    executes the insert. The session row update is captured inside the
    same transaction payload.],
  [3], [Cluster], [The slot reaches quorum choice. The write is decided.],
  [4], [Leader], [Crashes before sending the reply. The client sees a
    timeout. The outcome is ambiguous.],
  [5], [Voters], [The survivors elect a new leader. Phase-one recovery
    finds the chosen slot, commits it, and applies it. The new leader's
    image now holds the inserted row and the session row with
    `last_sequence = 7`.],
  [6], [Client], [Retries with the same session, the same sequence 7,
    and the same statement, now at the new leader.],
  [7], [New leader], [Checks the row: 7 equals `last_sequence`. It
    returns the recorded result, marked `replayed`. The insert exists
    exactly once.],
))

The session table travels inside the replicated frames. So the retry
lands correctly at any future leader, not only at the process that
executed the write. The cluster failpoint test demonstrates this full
loop.

Sessions are bounded. Every session write bumps a replicated activity
counter (`write_seq`) and stamps the session. `expire-sessions
--retain n` deletes sessions idle for more than the last `n` session
writes, as a normal replicated write. Storage stays proportional to
active sessions plus the result window, not to history.

== Read levels

You choose how much a read costs and how much it promises:

#table(
  columns: (auto, 1fr, auto),
  table.header([*Level*], [*Semantics*], [*Cost*]),
  [`any`], [The local applied state of whichever member answered. It may
    lag the leader, and the response says so in a label.], [none],
  [`leader`], [The leader's applied state. It is serializable against
    the single writer, and it can be stale only across an unnoticed
    leadership change.], [redirect],
  [`linearizable`], [It includes every write acknowledged before the
    read began, and it stays current across leader changes.],
    [one fence round],
)

The default is `linearizable`, as you saw in chapter 1. Chapter 7
explains the `freshness_ms` bound that tightens `any` on a learner, and
chapter 13 shows how a client requests each level.

== The quorum read fence

How do we make a read linearizable without writing to the log? The leader
proves that it is still the leader. The proof is a fence. It performs no
log append and no disk sync:

+ The leader records its current ballot $b$ and a fence slot
  $s = "decidedThrough"$.
+ It probes every peer with one question: is $b$ still exactly the
  ballot you have promised?
+ Each peer answers from its durable `promised`. The answer is an
  equality check. Nothing is written.
+ The fence completes when a read quorum confirms $b$ and the leader has
  applied through $s$. For three voters, that quorum is the leader plus
  one.
+ Only then does the query run, on applied state.

#book_figure([
  A linearizable read costs one fence round and no disk writes. The
  leader may answer only after a quorum confirms its exact ballot and it
  has applied through the fence slot.
], read_fence())

Why is this safe? We argue it in five steps.

+ Ballots are totally ordered, and a member's promise only moves upward.
+ Suppose some write was acknowledged after our fence began but is
  missing from our state applied through $s$. That write completed under
  a higher ballot $b' > b$, and completing it required a write quorum of
  promises at $b'$.
+ Every write quorum intersects every read quorum. So at least one
  member of our fence quorum had already promised $b'$ when we probed
  it.
+ That member answers with an equality check against its durable
  promise. Having promised $b'$, it no longer answers "exactly $b$". It
  would have failed our fence.
+ Our fence completed, so every probed member did answer "exactly $b$".
  The supposed write cannot exist. The state applied through $s$ holds
  every acknowledged write, and the read is linearizable.

A fence also fails immediately if the leader's own ballot or role moves
while the fence is outstanding.

#callout(title: [The committed barrier stays as the oracle],
  tone: "note")[
  The log still carries a `read_barrier` command. Appending one and
  waiting for it is the slow, obviously correct reference read. The test
  suites use it as a differential oracle for the fence path. Production
  reads use the fence.
]

== The crash matrix

Chapter 4 gave a write fixed stations: store the payload, append the
accept, release the accept request while the local journal sync runs,
make a quorum of votes durable, reach quorum choice, apply, reply. The
leader does not sync a separate commit marker: a durable accepting
quorum is the recovery proof, and the materialized SQLite file is
rebuildable state. Now pull the power cord between each pair of stations
and ask two questions. What does the client see? And what does recovery
do with the pieces?

Three answers repeat across the matrix, so learn them once:

+ Before any vote references the payload, the write simply does not
  exist. Nothing can be inferred from leftover bytes, and the client
  never saw success.
+ After a vote is durable but before quorum choice, the write's fate is
  open. A later leader's phase one may recover it or may not. That is
  exactly why the client outcome is "unknown" and why the retry uses the
  session sequence.
+ After quorum choice, the write's fate is sealed. Recovery must
  preserve and commit it, apply is contiguous and exactly-once, and the
  session retry turns "unknown" into the recorded result.

The full matrix pins each boundary:

#table(
  columns: (1.35fr, 1fr, 1.5fr),
  table.header([*Crash point*], [*Client outcome*], [*Recovery oracle*]),
  [Before payload sync], [failure or unknown, never success], [No vote
    references the incomplete payload. The store's temp-file install
    leaves no partial object.],
  [After payload sync, before accept append], [unknown], [The payload may
    be orphaned garbage. GC collects it. Nothing infers it was chosen.],
  [After accept append, while the local barrier runs], [unknown], [The local
    torn tail is truncated. A pipelined phase-two request may already have made
    another acceptor's vote durable; phase one preserves it if a quorum chose
    it. No client success has been returned.],
  [After accept sync, before a durability-bearing reply], [unknown], [The local
    vote survives replay and is available to a later leader. Promise evidence
    and accepted replies never leave before this point.],
  [After quorum choice, before client reply], [unknown], [Election
    recovery preserves and commits the chosen value. The session retry
    replays the recorded result.],
  [After chosen, before apply], [unknown or delayed], [The local commit marker
    is derived rather than separately synced. Phase-one recovery reconstructs
    the choice from durable accepts and contiguous replay applies it once.],
  [After apply, before reply], [unknown], [The same sequence returns the
    stored result. It never applies twice.],
  [During snapshot install], [existing traffic unaffected], [Restart
    picks a complete generation, old or new, and never a `tmp-*`
    directory.],
)

One honesty note. The hooks and harnesses exist, but the current
automated suite does not yet exercise every row in both one-node and
three-node roles. It covers torn tails, stale and corrupt image
replacement, both snapshot transition prefixes, and the cluster leader
kill after choice and before reply. Completing the remaining rows with
the required schedule counts is a release blocker in the product plan.

#exercise(8, [
  Take the crash matrix and mark every row where the write may actually
  have committed even though the client outcome says unknown. For each
  marked row, state what a retry of the same session sequence returns at
  the recovered cluster, and why the answer is never a second apply.
], hint: [
  Split the rows at quorum choice. Before it, recovery may lawfully
  drop the write, and the retry executes fresh. From quorum choice
  onward, the retry must return the recorded result.
])

#teach_back([
  Explain the fence to a colleague, then answer their follow-up: why
  must the peer confirm the exact ballot $b$, and not "any ballot at
  least $b$"? Use the quorum intersection step of the safety argument in
  your answer.
])
