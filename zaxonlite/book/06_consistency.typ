#import "theme.typ": *

= Consistency and the client contract

== Write acknowledgement

A client write returns one of three outcomes, and the distinction is the
contract:

+ *success*: the slot committed and the decided value at that slot is
  this client's `batch_id`. The transaction is durable at a quorum and
  applied.
+ *failure*: the SQL failed (rolled back, nothing replicated) or the
  session sequence was rejected — provably no side effect.
+ *ambiguous* (`ambiguous`, `timeout`, connection loss): the write may
  or may not have committed. The client retries the *same session
  sequence* — never a blind re-execution.

== Exactly-once sessions

A session is a replicated row: `(id, next_sequence, last_sequence,
last_changes, last_activity_slot)`. `exec` with `(session, sequence)`
checks the row first:

+ `sequence == last_sequence`: return the recorded result (`replayed`);
+ `sequence == next_sequence`: execute; the row update rides inside the
  captured transaction, so result and data commit atomically;
+ `sequence < next - 1`: `ResultExpired`; `sequence > next`:
  `SequenceGap`; unknown id: `UnknownSession` — none execute SQL.

Because the session table travels with the frames, a retry lands
correctly at a *new* leader after a crash: its image already contains
the session row the old leader committed. The cluster failpoint test
demonstrates the full loop.

Sessions are bounded. Every session write bumps a replicated activity
counter (`write_seq`) and stamps the session; `expire-sessions
--retain n` deletes sessions idle for more than the last `n` session
writes, as a normal replicated write. Storage stays proportional to
active sessions plus the result window, not to history.

== Read levels

#table(
  columns: (auto, 1fr, auto),
  table.header([*Level*], [*Semantics*], [*Cost*]),
  [`any`], [Local applied state of whichever member answered; may lag
    the leader. Labeled in the response.], [none],
  [`leader`], [The leader's applied state. Serializable against the
    single writer; can be stale only across an unnoticed leadership
    change.], [redirect],
  [`linearizable`], [Includes every write acknowledged before the read
    began, guaranteed current across leader changes.],
    [one fence round],
)

== The quorum read fence

The linearizable path performs no log append and no disk sync:

+ the leader records its ballot $b$ and fence slot
  $s = "decidedThrough"$;
+ it probes every peer: _"is $b$ still exactly the ballot you have
  promised?"_;
+ each peer answers from its durable `promised` — an equality check,
  no writes;
+ the fence completes when a read quorum (leader plus one, for three
  voters) confirms $b$ *and* the leader has applied through $s$; then
  the query runs on applied state.

*Why this is safe.* Ballots are totally ordered and a promise is
monotone. For a competing write to have been acknowledged after our
fence began, some higher ballot $b' > b$ must have completed a write
quorum of promises. Write and read quorums intersect, so some member of
our fence quorum would already have promised $b'$ — and its answer
would have failed the equality check. Contrapositive: a completed fence
at $b$ proves no higher-ballot write completed before the probe, so
applied-through-$s$ state contains every acknowledged write. A fence
also fails immediately if the leader's own ballot or role moves while
it is outstanding.

#callout(title: "The committed barrier stays as the oracle",
  tone: "note")[
  The log still carries a `read_barrier` command: appending one and
  waiting for it is the slow, obviously correct reference read. The test
  suites use it as a differential oracle for the fence path; production
  reads use the fence.
]

== The crash matrix

#table(
  columns: (1.35fr, 1fr, 1.5fr),
  table.header([*Crash point*], [*Client outcome*], [*Recovery oracle*]),
  [Before payload sync], [failure/unknown, never success], [No vote
    references the incomplete payload; the store's temp-file install
    leaves no partial object.],
  [After payload sync, before accept append], [unknown], [Payload may
    be orphaned garbage; GC collects it; nothing infers it chosen.],
  [After accept append, before journal sync], [unknown], [Torn tail is
    truncated; the vote never claimed to survive.],
  [After accept sync, before send], [unknown], [The vote survives replay
    and is available to a later leader.],
  [After quorum choice, before client reply], [unknown], [Election
    recovery preserves and commits the chosen value; the session retry
    replays the recorded result.],
  [After commit sync, before apply], [unknown/delayed], [Contiguous
    replay applies exactly once.],
  [After apply, before reply], [unknown], [Same sequence returns the
    stored result; never applies twice.],
  [During snapshot install], [existing traffic unaffected], [Restart
    picks a complete generation — old or new — never `tmp-*`.],
)

Every row is exercised: by the failpoint hooks in the write path, the
torn-tail and stale-image single-process tests, the fuzz harness's
random crash injection, and the cluster scenario's leader kill.
