#import "theme.typ": *
#import "figures.typ": *

#part_page("I", [One decision], [
  We begin with one empty line in a ledger. We end with the safety rule that
  determines every legal Paxos message.
])

= The empty ledger

Suppose that three librarians keep copies of one ledger. The next line is empty.
A visitor asks them to write `olive = 7`. Another visitor asks them to write
`olive = 9`. A librarian may leave the room. A messenger may lose a note. Notes
that do arrive are exact.

The required result is modest. We do not require a value to be chosen at every
moment. We require that if a value is chosen, no other value can ever be chosen
for that line.

This distinction is our first useful tool.

#definition([Safety], [
  Nothing bad happens. For Paxos, two different values are never chosen for the
  same decision.
])

#definition([Progress], [
  Something good eventually happens. For Paxos, a proposed value is eventually
  chosen when a quorum can communicate and one candidate remains active long
  enough.
])

A stopped system can be safe. It is not useful, but it has not contradicted
itself. This fact lets us design safety without guessing how long a message may
take.

== Three tempting answers

The first answer is "ask everybody." It works until one librarian leaves. One
missing reply stops all work.

The second answer is "ask any two." This is better. Any two of three form a
majority. Yet we have not said what a librarian remembers. If the two librarians
forget their earlier answer after a restart, a later pair can choose another
value.

The third answer is "let one leader decide." This moves the question. How does a
new leader learn what the old leader may already have decided?

All three answers contain a piece of Paxos. We need a quorum, durable memory,
and a leader recovery rule. None is sufficient alone.

#exercise([1.1], [
  In a cluster of five nodes, how many nodes form a majority? How many may be
  unavailable while progress remains possible?
], hint: [Compute `floor(N / 2) + 1`.])

== The failure model

We assume crash faults.

+ A node follows the algorithm while it runs.
+ A node may stop at any instruction.
+ A node may restart from data that reached stable storage.
+ A message may be lost, delayed, duplicated, or reordered.
+ A delivered message is not corrupted.

We do not assume that clocks agree. We do not assume a maximum message delay.
We do not defend against a node that invents votes or sends two lies. That is a
Byzantine problem and needs a different protocol.

#warning([The disk is part of the proof], [
  A promise that was sent and then forgotten is not a promise. If an acceptor
  replies before its state is durable, a restart can break quorum intersection.
])

= Quorums

A quorum is a set large enough that every two quorums share a member. For equal
voters, a strict majority has this property.

#book_figure(
  [Two majority quorums overlap. The shared node carries knowledge from one
  ballot to the next.],
  quorum_picture(),
)

For three nodes, every quorum has two nodes. The possible quorums are
`{A1, A2}`, `{A1, A3}`, and `{A2, A3}`. Pick any two of those sets. Their
intersection is not empty.

For five nodes, every quorum has three nodes. Two sets of three drawn from five
must share at least one node. The calculation is simple. If they did not meet,
they would contain six distinct nodes, but only five exist.

== Why an odd count is common

With four nodes, a majority is three. The cluster still tolerates only one
unavailable node. With three nodes, a majority is two and the cluster also
tolerates one. The fourth voter adds cost without adding failure tolerance.

This does not mean that every cluster must have an odd count. Failure domains,
weighted quorums, and geographic placement may justify another shape. The
current library uses uniform majority quorums. Its simple rule is visible in
`Membership.quorum`.

```zig
pub fn quorum(self: *const Membership) usize {
    return @as(usize, self.count) / 2 + 1;
}
```

The division is integer division. For `count = 5`, it yields `2 + 1 = 3`.

== Intersection is not memory

Let quorum `{A1, A2}` accept `x`. Later quorum `{A2, A3}` meets it at `A2`. If
`A2` remembers its vote, the later quorum has a witness. If `A2` forgets, the
sets still intersect on paper but no knowledge crosses the intersection.

Thus quorum intersection and stable storage form one idea. The set supplies a
witness. The disk lets the witness speak after a restart.

#exercise([2.1], [
  Construct two sets of two nodes in a four node cluster that do not intersect.
  Why can a quorum of two not be used there?
])

= Ballots

A single leader would make the choice easy. Failures create a sequence of
possible leaders. Paxos gives each attempt a ballot. Ballots are unique and have
a total order.

The library uses a pair.

```zig
pub const Ballot = struct {
    round: u64,
    node: NodeId,
};
```

Pairs are ordered from left to right. First compare the round. If rounds are
equal, compare the node.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Left*], [*Right*], [*Result*]),
  [`(4, 2)`], [`(5, 1)`], [The right ballot is greater.],
  [`(7, 1)`], [`(7, 3)`], [The right ballot is greater.],
  [`(9, 4)`], [`(9, 4)`], [The ballots are equal.],
)

The node component makes simultaneous ballots unique. Node 2 may use
`(11, 2)`. Node 3 may use `(11, 3)`. They cannot own the same ballot.

A node that sees a higher round remembers it. Its next campaign uses a still
higher round. The `u64` space is finite, so the library reports
`error.BallotExhausted` rather than wrapping.

== Votes and success

A ballot has four conceptual parts.

+ A ballot number.
+ A proposed value.
+ A quorum.
+ The members of that quorum that accepted the value.

A ballot succeeds when every member of its selected quorum accepts. An
implementation often sends to every member and waits for any quorum. The proof
is the same because the acknowledgements define the successful quorum.

The word "chosen" means that such a quorum exists. The proposer need not know
that it exists. Imagine that the final acknowledgement reaches the proposer,
the value becomes chosen, and the proposer crashes before announcing it. The
fact remains. A future leader must preserve it.

= Three invariants

Lamport gives three conditions. We shall state them in code language.

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Rule*], [*Statement*], [*Mechanism*]),
  [`B1`], [Every ballot number is unique.], [The pair `(round, node)`.],
  [`B2`], [Every two ballot quorums intersect.], [Majority membership.],
  [`B3`], [A later ballot preserves the highest earlier vote seen in its
    phase one quorum.], [Prepare, promise, and value selection.],
)

The first two rules are easy to enforce. The third is the heart of Paxos.

Suppose a candidate starts ballot 12. It asks a quorum what each member last
accepted. The replies are:

#table(
  columns: (auto, auto, 1fr),
  table.header([*Acceptor*], [*Accepted ballot*], [*Value*]),
  [`A1`], [`8`], [`red`],
  [`A2`], [`10`], [`blue`],
  [`A3`], [`null`], [`null`],
)

The candidate must propose `blue` because ballot 10 is the highest reported
ballot. It may not choose `green`, even if `green` was the client's request.

#callout([The recovery choice], [
  If no reply contains an accepted value, use the new value. Otherwise use the
  value attached to the greatest accepted ballot in the quorum replies.
], kind: "idea")

== Why the greatest vote matters

Assume that ballot 6 chose `red`. A later successful ballot must also use `red`.
Its quorum intersects the quorum for ballot 6. At least one reply has knowledge
that begins with `red`. There may be intermediate ballots. The greatest prior
vote reported by the new quorum carries the value that those intermediate
ballots were themselves required to preserve.

This is an induction. The base case is ballot 6. The induction step says that a
later ballot takes the greatest earlier vote from an intersecting quorum. It
therefore cannot be the first later ballot to change the value.

We can phrase the proof as a minimal counterexample. Suppose some later ballot
is the first ballot after 6 to use another value. Its quorum meets ballot 6's
quorum. Every reported vote between 6 and this first bad ballot still contains
`red`, by the choice of "first." The greatest report therefore contains `red`.
The ballot was required to choose `red`. This contradicts the assumption that it
was bad.

#exercise([4.1], [
  A phase one quorum reports `(3, apple)`, `(9, apple)`, and `(7, pear)`. Which
  value must the new ballot use? Does the answer change if ballot 3 is known to
  have succeeded?
])

= From rules to messages

We now have enough facts to predict the protocol.

The candidate needs a fresh ballot. It needs a quorum to promise not to vote in
older ballots. It needs each promise to include the last accepted vote. Then it
can choose the required value and ask the quorum to accept it.

Those sentences give the message names.

#book_figure(
  [Phase one obtains promises and prior votes. Phase two obtains acceptances.
  A quorum of votes makes the value chosen.],
  phase_flow(),
)

The next part follows every message, including its disk write and rejection
case. Nothing will be added merely because a textbook says so. Each field will
pay rent by protecting one invariant.
