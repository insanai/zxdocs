#import "theme.typ" : *

#part_page("VII", [Desk reference], [
  This part collects messages, state, errors, formulas, and answers in one place.
])

= Consensus Desk Reference

== Message reference

This table summarizes all core protocol messages exchanged between nodes in our Multi-Paxos implementation:

#table(
  columns: (auto, 1.2fr, 1.5fr),
  table.header([*Message*], [*Fields*], [*Meaning*]),
  [`prepare`], [`ballot, decided_through`], [Ask an acceptor to promise this ballot and report
    accepted state above `decided_through`.],
  [`promise`], [`ballot, slot, accepted`], [Report one accepted slot for phase
    one recovery.],
  [`promise_done`], [`ballot, accepted_count, decided_through`], [State how many distinct promise
    entries complete this reply and report peer's decided through index.],
  [`accept`], [`ballot, slot, value`], [Ask an acceptor to vote.],
  [`accepted`], [`ballot, slot, decided_through`], [Acknowledge a durable vote and report peer's decided through index.],
  [`commit`], [`slot, value`], [Teach a chosen value to a learner.],
  [`learn`], [`from_slot`], [Ask a peer for known commits.],
  [`nack`], [`rejected, promised, decided_through`], [Reject work below a durable promise and report peer's decided through index.],
  [`heartbeat`], [`ballot, decided_through`], [Leader heartbeat reporting its decided through index.],
)

== Durable writes

These are the three critical records that acceptors must write to stable disk storage before sending any replies over the network:

#table(
  columns: (auto, 1fr, 1.5fr),
  table.header([*Write*], [*Fields*], [*Required before sending...*]),
  [`promise`], [`ballot`], [Promise replies for that ballot.],
  [`accept`], [`ballot, slot, value`], [Accepted acknowledgement.],
  [`commit`], [`slot, value`], [Application delivery and catch up claim.],
)

== Node state

This table maps the internal fields of a consensus node (`Consensus.Node`) to their persistence lifecycle:

#table(
  columns: (auto, 1fr, auto),
  table.header([*Field*], [*Meaning*], [*Lifetime*]),
  [`durable.promised`], [Highest ballot this acceptor permits.], [Durable],
  [`durable.accepted`], [Last accepted ballot and value per slot.], [Durable],
  [`durable.committed`], [Known chosen value per slot.], [Durable],
  [`role`], [Follower, preparing, or leader.], [Volatile],
  [`ballot`], [Current local attempt.], [Volatile],
  [`highest_observed_round`], [Round learned from higher traffic.], [Volatile],
  [`next_slot`], [Next free proposal slot or zero.], [Rebuilt],
  [`delivered_through`], [Prefix emitted in this process.], [Volatile],
  [`promise_*`], [Phase one receipt accounting.], [Volatile],
  [`recovered`], [Greatest accepted report per slot.], [Volatile],
  [`proposals`], [Leader value per active slot.], [Volatile],
  [`acknowledgements`], [Member votes per slot.], [Volatile],
)

== Error reference

This list describes the operational errors returned by the public library methods:

#table(
  columns: (auto, 1fr),
  table.header([*Error*], [*Meaning*]),
  [`EmptyMembership`], [No voter was supplied.],
  [`TooManyMembers`], [Membership exceeds `max_members`.],
  [`InvalidNodeId`], [Node zero was supplied.],
  [`DuplicateNodeId`], [One identity occurs twice.],
  [`NotMember`], [A local or source identity is outside membership.],
  [`WrongRecipient`], [The envelope target is not this node.],
  [`NotLeader`], [Proposal was attempted before completed phase one.],
  [`BallotExhausted`], [No greater `u64` round exists.],
  [`InvalidSlot`], [Slot zero was supplied where a real slot is required.],
  [`SlotLimitReached`], [The bounded log has no free slot.],
  [`InvalidPromise`], [A reply count exceeds the slot bound.],
  [`MissingNoop`], [Recovery needs a no op but none was supplied.],
  [`ConflictingValue`], [One ballot and slot carried two values.],
  [`ConflictingCommit`], [One slot was taught two committed values.],
  [`PromiseRegression`], [Journal replay tried to move a promise backward.],
)

== Formula sheet

Quick mathematical references for cluster design:

#table(
  columns: (1.3fr, auto, 1.2fr),
  table.header([*Quantity*], [*Formula*], [*Example*]),
  [Uniform majority quorum], [`floor(N / 2) + 1`], [`N=5` gives `3`.],
  [Crash tolerance], [`N - quorum`], [`5 - 3` gives `2`.],
  [Stable messages, this three node path], [`2(N - 1) + (N - 1)`],
    [`2 + 2 + 2 = 6`.],
  [Epoch duration], [`slots / slots_per_second`], [`10M / 200 = 50,000 s`.],
  [Accept payload egress], [`payload * peers * rate`],
    [`8 KiB * 4 * 200`.],
)

== Invariants for review

Review these ten rules to double-check any change to the protocol:

- *Ballot Uniqueness*: Ballot numbers must be globally unique and totally ordered.
- *Quorum Intersection*: Any two quorums in the same epoch must share a node.
- *Promise Invariant*: An acceptor must never accept a proposal with a ballot lower than its promise.
- *Single Value per Ballot*: One ballot and slot can have at most one proposed value.
- *Highest Vote Recovery*: A new leader must propose the value from the highest ballot number reported in its complete Phase One quorum.
- *Consensus Boundary*: A value is chosen only when a quorum has accepted it.
- *Commit Consistency*: A slot has at most one committed value.
- *Contiguous Application*: Committed entries must be applied to the state machine sequentially in slot order.
- *Write-Before-Send*: Acceptors must sync votes to disk before sending messages.
- *Epoch Limits*: Slots must never be reused within the same epoch.

== Answers to selected exercises

=== Exercise 1.1
A majority of five is three. Two nodes may be offline while three remain active to form a quorum and make progress.

=== Exercise 2.1
`{A1, A2}` and `{A3, A4}` do not intersect. If both were quorums, they could choose conflicting values independently, violating safety.

=== Exercise 4.1
The new candidate must propose `apple` because it is associated with ballot 9, which is the highest accepted ballot number reported. The fact that ballot 3 succeeded does not change this; ballot 9 was already forced to carry `apple` by induction.

=== Exercise 8.1
The promise write must precede the promise reply. The accept write must precede the accepted reply. The commit write must precede application delivery and catch-up.

== Glossary

#table(
  columns: (auto, 1fr),
  table.header([*Term*], [*Meaning*]),
  [Accepted], [One acceptor durably voted for a ballot, slot, and value.],
  [Applied], [The application state machine executed a committed entry.],
  [Ballot], [A unique ordered proposal attempt.],
  [Chosen], [A quorum accepted one value in one slot.],
  [Commit], [A learner's record of a chosen value.],
  [Epoch], [One period with fixed membership and nonreused slots.],
  [Leader], [A candidate that completed phase one for its ballot.],
  [Learner], [A role that discovers chosen values.],
  [No op], [A valid application value that changes no state.],
  [Promise], [An acceptor's durable refusal to accept lower ballots.],
  [Quorum], [A voter set that intersects every other legal quorum.],
  [Slot], [A one based position in the replicated log.],
)

== Further study

For readers who wish to dive deeper into the theoretical and engineering aspects of consensus, we recommend the following literature and implementations:

=== Core Theoretical Papers

- *Leslie Lamport, "The Part-Time Parliament" (1998)*: The original Paxos paper, presenting the algorithm through the metaphor of a Greek island's legislature. Safe but notoriously difficult to read.
- *Leslie Lamport, "Paxos Made Simple" (2001)*: A classic, much more direct explanation of Paxos derived from first principles.
- *Heidi Howard et al., "Flexible Paxos: Quorum Intersection Revisited" (2016)*: A major breakthrough showing that Paxos does not require majorities for both phases—only that every Phase 1 (prepare) quorum intersects with every Phase 2 (accept) quorum. This allows cheap, small write quorums at the cost of larger recovery quorums.

=== Reconfiguration and Snapshots

- *Leslie Lamport et al., "Reconfiguring a Replicated State Machine" (Vertical Paxos) (2009)*: Explains how to change configuration on the fly using auxiliary consensus instances to choose the configuration sequence.
- *Diego Ongaro and John Ousterhout, "In Search of an Understandable Consensus Algorithm" (Raft) (2014)*: While presenting a different protocol, it provides an excellent discussion on joint consensus reconfiguration and log compaction via snapshots.

=== Alternative Protocols and Scaling

- *M. Moraru et al., "There Is More Consensus in an Egalitarian Parliament" (EPaxos) (2013)*: An egalitarian Paxos variant where any replica can act as a leader for any command, resolving conflicts dynamically to achieve lower latency.
- *Michael Whittaker et al., "Compartmentalized Paxos" (2020)*: Deconstructs the single-leader bottleneck by splitting the leader's tasks (batching, sequencing, replication) across independent, scale-out proxy nodes.

=== Real-World Implementations for Study

- *TigerBeetle (Zig)*: A production distributed financial accounting database built in Zig. It utilizes a Viewstamped Replication/Paxos variant designed around the TigerStyle coding system (zero-allocation, static bounds).
- *OmniPaxos (Rust)*: A modern Rust library that implements a Multi-Paxos engine, including active leader lease management and built-in reconfiguration.
- *LibPaxos3 (C)*: A clean, minimal C library implementing a Multi-Paxos core with event-driven transport, useful for understanding low-level message buffering.

=== Recommended Web Resources

- #link("https://lamport.azurewebsites.net/pubs/paxos-simple.pdf")[Lamport's Paxos Made Simple (PDF)]
- #link("https://arxiv.org/abs/1608.06696")[Flexible Paxos Paper (arXiv)]
- #link("https://github.com/tigerbeetle/tigerbeetle")[TigerBeetle Codebase on GitHub]
- #link("https://omnipaxos.com/")[OmniPaxos Documentation]
- #link("https://bitbucket.org/sciascid/libpaxos")[LibPaxos3 Core Repository]
- #link("https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md")[TigerStyle Guide]

== Closing note

Paxos is not a bag of messages. It is one rule carried through time. A later
ballot must respect what an earlier quorum may have chosen. Quorum intersection
finds a witness. Stable storage lets the witness remember. Phase one asks the
witness. Phase two records the next fact. Slots put facts in order.

The rest is engineering. That phrase does not mean the rest is easy. It means
the proof has given the engineering a fixed point. Every queue, disk write,
retry, snapshot, and benchmark can now be judged by whether it preserves that
point.
