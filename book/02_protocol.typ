#import "theme.typ": *
#import "figures.typ": *

#part_page("II", [The complete ballot], [
  We execute one ballot. We stop at every write, every reply, and every failure.
  At the end we can recover after a crash without guessing.
])

= The four roles

Paxos names proposers, acceptors, and learners. Applications add clients. One
process may perform all four roles. The names describe duties, not machines.

#book_figure(
  [A client supplies intent. Paxos orders that intent. The state machine gives
  the intent application meaning.],
  role_map(),
)

The proposer owns one ballot number. The acceptor owns durable promises and
votes. The learner owns knowledge of chosen values. A client owns the request
identity that lets it retry safely.

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Role*], [*Question*], [*Durable fact*]),
  [Proposer], [Which value may this ballot propose?], [No proposer state is
    required for safety after a crash.],
  [Acceptor], [May I vote, and what did I vote for?], [Highest promise and last
    accepted vote.],
  [Learner], [Which value was chosen?], [Known commits and applied index.],
  [Client], [Did my logical request execute?], [Stable client and request IDs.],
)

= Phase one

== Prepare

The candidate chooses a ballot greater than every ballot it has attempted,
promised, or observed in a rejection. It sends:

```text
prepare { ballot }
```

The message contains no value. This is important. The candidate does not yet
know whether it may use the client's value.

== Promise

An acceptor compares the prepare ballot with its durable promise.

#table(
  columns: (1fr, 1fr, 1fr),
  table.header([*Comparison*], [*Action*], [*Reason*]),
  [New ballot is lower.], [Send `nack`.], [An earlier promise forbids the vote.],
  [New ballot is equal.], [Repeat the reply.], [The message is a duplicate.],
  [New ballot is greater.], [Persist the promise, then reply.], [A reply must
    survive restart.],
)

For one slot, the reply contains either no accepted vote or one pair:

```text
promise {
    ballot,
    accepted_ballot,
    accepted_value,
}
```

The word "promise" has exact force. After promising ballot 11, the acceptor
will not accept ballot 10. It may accept ballot 11 or 12.

#warning([Never reply first], [
  If the promise reply reaches the candidate before the disk write is durable,
  a crash may erase the promise. Another proposer can then collect a vote that
  should have been forbidden.
])

== Complete quorum replies

The candidate waits for a quorum. It does not wait for every member. Waiting for
all would let one failed member stop progress.

For a single slot, each reply is one message. For the bounded Multi Paxos log,
one reply may contain many accepted entries. The library sends one entry message
per accepted slot and a final count. This count lets the receiver detect a final
marker that arrived before an entry.

We shall return to that detail in Part III.

== Choose a value

The candidate examines the complete quorum.

```text
if no accepted vote was reported:
    choose the client value
else:
    choose the value from the greatest accepted ballot
```

The candidate is now a leader for this ballot. It may begin phase two.

= Phase two

== Accept

The leader sends:

```text
accept {
    ballot,
    slot,
    value,
}
```

An acceptor again checks its promise. This second check is necessary. A higher
prepare may have arrived after the phase one reply.

If the ballot is current or greater, the acceptor persists the ballot and value.
Only then does it send:

```text
accepted { ballot, slot }
```

If the ballot is lower, it sends a rejection with the highest promise it knows.

== Local acceptance

The leader is also an acceptor. It need not send a network message to itself.
The Zig library writes the local acceptance directly into the effect batch. It
then sends accept messages only to remote peers. This saves one outbound message
and still makes the write before send order explicit.

```zig
self.durable.promised = self.ballot;
self.durable.accepted[index] = .{
    .ballot = self.ballot,
    .value = value,
};
effects.addWrite(.{ .accept = .{
    .ballot = self.ballot,
    .slot = slot,
    .value = value,
} });
```

The local acknowledgement is then marked in memory. A three node leader needs
one remote acknowledgement to reach a quorum of two. It still sends to both
peers so the other replica can catch up.

== Chosen and learned

When a quorum has accepted the same ballot and value, the value is chosen. The
leader records a commit and sends the value to peers.

A commit message is evidence supplied by a correct Paxos participant. It does
not carry a magic proof. In the crash fault model, nodes follow the algorithm,
so a leader announces commit only after a quorum. A Byzantine design would need
signed quorum evidence or another certificate.

= A complete trace

Let nodes 1, 2, and 3 begin empty. Node 1 proposes `tea` with ballot `(1, 1)`.

#transcript((
  [1], [N1], [Creates ballot `(1, 1)` and sends prepare to all three nodes.],
  [2], [N1], [Persists promise `(1, 1)` before its local promise reply.],
  [3], [N2], [Persists promise `(1, 1)` and reports no accepted value.],
  [4], [N1], [Has a quorum of complete promises. No old value exists.],
  [5], [N1], [Persists local acceptance of `tea` in slot 1.],
  [6], [N1], [Sends accept for `tea` to N2 and N3.],
  [7], [N2], [Persists the acceptance and replies accepted.],
  [8], [N1], [Local N1 plus remote N2 form a quorum. `tea` is chosen.],
  [9], [N1], [Persists commit and sends commit to N2 and N3.],
  [10], [All], [Release slot 1 to their state machines when learned.],
))

N3 may receive its accept after the value is already chosen. Its vote is useful
for redundancy but is not needed for the fact of choice.

== Message cost

Election is excluded from the steady path. For one new value on three nodes:

#table(
  columns: (1fr, auto, 1fr),
  table.header([*Step*], [*Messages*], [*Comment*]),
  [Accept to remote peers], [2], [The leader accepts locally.],
  [Accepted replies], [2], [One reply completes a quorum.],
  [Commit to remote peers], [2], [The leader learns locally.],
  [Total], [6], [No serialization or transport framing included.],
)

= Duplicate and reordered messages

The network is allowed to repeat every message. We therefore ask whether each
handler is idempotent.

== Duplicate prepare

If the ballot equals the durable promise, the acceptor repeats its report. It
does not write a second promise. A reply that was lost can therefore be retried.

== Duplicate accept

If the same ballot, slot, and value were already accepted, the acceptor repeats
the acknowledgement without another write. If the same ballot and slot carry a
different value, the library returns `error.ConflictingValue`. One unique ballot
must not have two values.

== Duplicate acknowledgement

Acknowledgements are stored by member index in a fixed Boolean array. Repeating
one does not create a second voter.

== Duplicate commit

The same value is harmless. A different value for an already committed slot is
`error.ConflictingCommit`. The error marks a violated safety boundary.

== An old accept arrives late

The acceptor compares it with the highest promise. A lower ballot receives a
rejection. The old message cannot turn time backward.

#exercise([8.1], [
  List every durable write in the complete trace. For each write, name the first
  outbound message that would be unsafe if it left before that write completed.
])

= Rejection and another campaign

A rejection carries two ballots.

```text
nack {
    rejected,
    promised,
}
```

The candidate acts only if `rejected` is its current ballot and `promised` is
greater. It becomes a follower and remembers the observed round. Its next
campaign chooses a round above that value.

The rejection itself is not a promise made by the receiving node. The receiver
must not copy another node's promise into its own durable promise. The library
keeps `highest_observed_round` as volatile campaign guidance.

= Progress and the distinguished proposer

Safety does not require one leader. Two candidates may prepare higher and higher
ballots forever. Each prevents the other's accept phase from finishing. No two
values are chosen, but no value is chosen either.

Progress needs an eventual distinguished proposer. This is usually supplied by
a failure detector and randomized timeouts. The detector may be wrong for a
while. That affects speed, not safety.

The library contains no clock. The host decides when to call `campaign`. This
keeps time out of the safety core and lets a simulator control elections exactly.

#callout([The liveness assumption], [
  A quorum can exchange messages, and after some time one candidate starts a
  ballot that no higher candidate interrupts.
], kind: "idea")

= Crash points

We now inspect the dangerous moments.

#table(
  columns: (1.15fr, 1fr, 1.5fr),
  table.header([*Crash point*], [*Durable state*], [*Recovery*]),
  [Before promise sync], [Old promise.], [No promise reply was allowed to leave.],
  [After promise sync, before reply], [New promise.], [A repeated prepare gets a
    valid reply.],
  [Before accept sync], [No new vote.], [No accepted reply was allowed to leave.],
  [After accept sync, before reply], [New vote.], [Phase one of a later leader
    discovers it.],
  [After quorum, before commit], [Votes exist on a quorum.], [A later leader must
    recover the chosen value.],
  [After commit sync, before send], [Local commit.], [Catch up sends it later.],
)

This table is the operational form of the proof. A system that cannot explain a
crash at each row is not ready to run Paxos.

= One decision as a library instance

Classic Paxos is the bounded protocol with one slot.

```zig
const Synod = paxos.Protocol(Command, .{
    .max_members = 3,
    .max_slots = 1,
});
```

Campaign once. Propose once. After slot 1, `propose` returns
`error.SlotLimitReached`. The next part shows how independent decisions form a
log and how one successful phase one can serve many of them.
