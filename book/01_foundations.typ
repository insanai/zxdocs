#import "theme.typ": *
#import "figures.typ": *

#part_page("I", [One decision], [
  We begin with one empty line in a ledger. We end with the safety rule that
  determines every legal Paxos message.
])

= Foundations of Consensus

== The empty ledger

Imagine three librarians sitting in separate rooms, each holding a copy of the same ledger. The next line of this ledger is currently blank, waiting for a decision. Now, two visitors arrive at the library. The first visitor sends a messenger to the librarians asking them to write `olive = 7` on that blank line. At the same time, the second visitor sends another messenger asking them to write `olive = 9`.

To make matters worse, the librarians cannot talk directly to each other; they can only send handwritten notes back and forth via messengers. These messengers are notorious for losing notes, falling asleep, or delivering them out of order. However, we assume that when a note does arrive, its content is exact—messengers may lose messages, but they do not alter the words on them.

Our goal is deceptively simple: we want the librarians to agree on exactly one value for this blank line. We do not require them to reach a decision immediately (especially if all messengers are lost in a storm). What we *do* require is absolute safety: if any librarian concludes that a value has been chosen, no other librarian must ever conclude that a different value was chosen for that same line.

This distinction between safety ("nothing bad ever happens") and liveness ("something good eventually happens") is our first and most important tool.

#definition([Safety], [
  Nothing bad happens. For Paxos, two different values are never chosen for the
  same ledger slot. Once a value is chosen, it is locked forever.
])

#definition([Liveness], [
  Something good eventually happens. For Paxos, a proposed value is eventually
  chosen when a quorum of nodes can communicate and one leader remains active long
  enough to coordinate them.
])

A stopped system is perfectly safe. It does no work, but it never contradicts itself. This fact lets us design safety rules first, without guessing how long a message might take to cross the network.

=== Three tempting answers

If we try to solve this consensus problem, we quickly run into three intuitive but flawed approaches:

1. *The Unanimous Vote ("Ask Everyone")*: We could require all three librarians to agree before writing a value. This works perfectly until one librarian leaves the room or falls ill. Now, the system is permanently stuck because we cannot obtain the final vote.
2. *The Free Majority ("Ask Any Two")*: Since two out of three form a majority, we might allow any two librarians to write a value. But what happens if they vote, restart their machines, and forget their previous votes? A later pair of librarians could meet and write a different value, violating safety.
3. *The Single Leader ("Designate a Dictator")*: We can appoint one librarian as the sole leader who decides all values. But what happens when the leader crashes? How does a newly elected leader safely discover what the old leader might have already decided and committed?

Each of these attempts contains a piece of the final solution. We need a *quorum* of nodes to survive failures, *durable memory* to prevent nodes from forgetting their votes, and a *leader election rule* that respects past decisions.

#exercise([1.1], [
  In a cluster of five nodes, how many nodes form a majority? How many nodes may be
  completely offline while the system remains capable of making new progress?
], hint: [Compute `floor(N / 2) + 1` for the majority size.])

=== The failure model

To build a consensus system that we can prove correct, we must define the rules of the universe in which it operates. We adopt the *Crash-Recovery* model:

+ *Honesty*: A node follows the algorithm exactly while it is running. It does not act maliciously, invent messages, or lie.
+ *Halt*: A node may stop executing at any instruction (a crash).
+ *Recovery*: A node may restart at any time. It recover its state from data written to stable storage (such as a disk journal).
+ *Asynchronous Network*: The network can delay, duplicate, lose, or reorder messages. However, any delivered message is uncorrupted.

If a node could lie or act maliciously, we would be in the *Byzantine* model, which requires more complex protocols and larger quorums. Paxos assumes nodes are correct but unreliable.

#warning([The disk is part of the proof], [
  A promise that was sent and then forgotten is a lie. If an acceptor replies to
  a leader before its state is durably written to disk, a sudden power failure
  can erase its memory, allowing it to violate its promise upon reboot.
])

== Quorums

How do we make progress when some nodes are dead? We use quorums. A quorum is a subset of nodes large enough that any two quorums must share at least one node. If we use simple majorities, this property is guaranteed mathematically.

#book_figure(
  [Two majority quorums overlap. The shared node acts as a witness, carrying
  knowledge of past decisions into the future.],
  quorum_picture(),
)

Consider three nodes: $A$, $B$, and $C$. The possible majority quorums of size two are:
$$ \{A, B\}, \quad \{A, C\}, \quad \{B, C\} $$
Pick any two of these sets. They *must* intersect. For example, $\{A, B\}$ and $\{B, C\}$ share node $B$. 

If a value is chosen by one quorum, and we later query another quorum, the overlapping node acts as a *witness*. It carries the memory of the chosen value to the next leader.

=== Why an odd count is common

In a cluster of four nodes, a majority quorum requires three nodes. The system can tolerate only $4 - 3 = 1$ crash. In a cluster of three nodes, a majority is two, which also tolerates $3 - 2 = 1$ crash. Adding the fourth node increased our costs (hardware, network traffic) without increasing our fault tolerance.

For this reason, production consensus clusters almost always consist of an odd number of nodes (typically 3 or 5). The Zig library uses uniform majority quorums by default, computed via `Membership.quorum`:

```zig
pub fn quorum(self: *const Membership) usize {
    return @as(usize, self.count) / 2 + 1;
}
```

Since Zig uses integer division, `5 / 2 + 1` evaluates to `3`.

=== Intersection is not memory

Imagine that quorum $\{A, B\}$ accepts a value $x$. Later, a candidate contacts quorum $\{B, C\}$. The candidate meets node $B$, which is the intersection. 

But what if node $B$ crashed and rebooted in the meantime, forgetting its vote? The intersection still exists on paper, but the *knowledge* of the decision is gone. Quorum intersection only works if nodes have stable memory.

#exercise([2.1], [
  Construct two quorums of size two in a four-node cluster $\{A, B, C, D\}$ that do not intersect. Why is it impossible to guarantee safety if we define a quorum as any two nodes in a four-node system?
])

== Ballots

If a leader never crashed, consensus would be trivial. Because leaders fail, we must support a sequence of attempts to make a decision. We call each attempt a *ballot*. Ballots must be unique and totally ordered.

In the Zig library, a ballot is defined as:

```zig
pub const Ballot = struct { round: u64, node: NodeId };
```

We compare ballots lexicographically: first by their `round` number, and then by their `node` ID to break ties.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Left Ballot*], [*Right Ballot*], [*Comparison Result*]),
  [`(4, 2)`], [`(5, 1)`], [Right is greater (higher round dominates).],
  [`(7, 1)`], [`(7, 3)`], [Right is greater (node ID breaks the tie).],
  [`(9, 4)`], [`(9, 4)`], [Ballots are equal.],
)

The node ID ensures that two candidates campaigning at the same time never issue the same ballot. If Node 2 uses `(11, 2)` and Node 3 uses `(11, 3)`, their ballots are distinct, and `(11, 3)` is greater.

=== Votes and success

A ballot represents an attempt to choose a value. It consists of:
1. A unique ballot number.
2. A proposed value.
3. A quorum of acceptors.

A ballot *succeeds* (and its value is chosen) when every member of its selected quorum accepts the proposal. The word "chosen" means that a quorum of acceptances exists. The proposer does not need to know that the quorum succeeded for the fact of choice to be true. If the final vote is written to disk, the value is chosen, even if the leader dies immediately afterward.

== Three invariants

Leslie Lamport defined the safety of Paxos using three conditions. Let us translate them into clear programmatic invariants:

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Invariant*], [*Rule*], [*Zig Implementation*]),
  [`B1`], [Every ballot number is unique.], [Lexicographical comparison of `(round, node)`.],
  [`B2`], [Any two ballot quorums intersect.], [Enforced majority sizing in `Membership.quorum`.],
  [`B3`], [A later ballot must choose the highest-numbered vote already accepted by any node in its phase one quorum.], [Phase one promise scanning and value selection logic.],
)

Invariant `B3` is the crown jewel of Paxos. It prevents a new ballot from overwriting or changing a value that might have already been chosen by an earlier ballot.

Suppose Candidate $C$ starts ballot 12. It queries a quorum of acceptors about what they last accepted. The replies are:

#table(
  columns: (auto, auto, 1fr),
  table.header([*Acceptor*], [*Highest Accepted Ballot*], [*Accepted Value*]),
  [`A1`], [`8`], [`red`],
  [`A2`], [`10`], [`blue`],
  [`A3`], [`null`], [`null`],
)

Candidate $C$ *must* propose `blue` for ballot 12 because `blue` was accepted in ballot 10, which is the highest ballot reported in the quorum. It cannot choose a new client value like `green`.

#callout([The Selection Rule], [
  If the quorum replies contain no previously accepted values, the candidate is
  free to propose its own client value. Otherwise, it *must* select the value
  associated with the highest ballot number reported.
], kind: "idea")

=== Why the greatest vote matters

Why does selecting the highest ballot preserve safety?

Assume ballot 6 succeeded in choosing `red`. Any later ballot, say ballot 10, must intersect ballot 6's quorum. Therefore, at least one node in ballot 10's quorum will report that it accepted `red` in ballot 6. By following rule `B3`, the leader of ballot 10 is forced to propose `red`. 

By induction, if ballot 6 chooses `red`, every ballot after 6 is forced to choose `red`. Safety is preserved through time.

#exercise([4.1], [
  A phase one quorum reports three accepted values: `(3, apple)`, `(9, apple)`, and `(7, pear)`. Which value must the new candidate propose? Does the answer change if ballot 3 is known to have successfully reached a quorum?
])

== From rules to messages

We have derived the protocol simply by thinking through the invariants. To safely propose a value:
1. The candidate needs a ballot number higher than any seen so far.
2. It must obtain a promise from a quorum of acceptors not to accept any lower ballots.
3. It must collect the highest votes those acceptors have already cast.
4. If a prior vote exists, it must use it; otherwise, it proposes its own value.

These four steps map directly to the classic Paxos messages:

#book_figure(
  [Phase one obtains promises and prior votes. Phase two broadcasts the proposal
  and collects acceptances to reach consensus.],
  phase_flow(),
)

In the next chapter, we will follow these messages through their handlers, disk writes, and failure states. We will see how every struct field in our Zig library pays rent by protecting one of these core safety invariants.
