#import "theme.typ": *

#part_page("VIII", [Conformance], [
  One table from the paper to the code to the test oracles to the model:
  every safety-relevant rule is traceable in all four places.
])

= Lamport Conformance Appendix

This appendix maps the basic protocol of #emph[The Part-Time Parliament]
(section 2.3 and the appendix's algorithm) and the multi-decree refinements
(section 3) to `src/protocol.zig`, to the simulator's runtime oracles in
`sim/simulation.zig`, and to the TLC-checked model in `specs/Paxos.tla`.
Line references drift; function names are the stable anchors.

== The basic protocol, step by step

#table(
  columns: (auto, 1.5fr, 1.2fr, auto),
  table.header(
    [*Paper*], [*Rule*], [*Code (`protocol.zig`)*], [*Spec action*],
  ),
  [Step 1], [Choose a ballot greater than `lastTried`, owned by this
    priest.], [`startCampaign`: `round = max(own, promised, observed) + 1`
    with the node ID as tie-breaker; `Ballot.order`], [`Prepare`],
  [Step 2], [On `NextBallot(b)` with `b >= nextBal`, set `nextBal` and
    reply `LastVote` with the highest vote.], [`onPrepare`: `lessThan`
    guard, `Write.promise`, per-slot `promise` replies, `promise_done`
    completion marker; lower ballots are nacked], [`Promise`],
  [Step 3], [With `LastVote` from a majority, propose the decree of the
    highest-ballot vote, else any decree (B3).], [`onPromise` keeps the
    highest-ballot vote per slot; `maybeBecomeLeader` requires complete
    promises from a read quorum, re-drives recovered slots, fills gaps
    with the no-op decree], [`Accept` and `ChoosableFor`],
  [Step 4], [On `BeginBallot(b, d)` with `b >= nextBal`, cast the vote and
    record it in the ledger.], [`onAccept`: `lessThan` guard, `Write.accept`
    persisted before the `accepted` reply; same-ballot conflicts are
    `ConflictingValue`], [`Vote`],
  [Step 5], [With `Voted` from every quorum member, the decree passes.],
    [`onAccepted`: distinct-member count against `writeQuorum()`, then
    `recordCommit`], [`Decide`],
  [Step 6], [On `Success(d)`, write the decree in the ledger.],
    [`onCommit` / `recordCommit`; `emitContiguous` releases the decided
    prefix in order], [`Learn`],
)

== Multi-decree refinements

#table(
  columns: (auto, 1.6fr, 1.4fr),
  table.header([*Paper*], [*Rule*], [*Code*]),
  [Section 3.1], [One `NextBallot(b, n)` covers every decree instance; the
    reply carries votes for all instances after `n`.], [`onPrepare` loops
    slots above the proposer's `decided_through`; `promise_done` carries
    the count so leadership waits for a complete reply per member],
  [Section 3.1], [The reply also reports already-passed decrees the
    president may be missing.], [`onPrepare` reports a learned-only decree
    as a zero-ballot vote, which loses to every real vote and can never
    override the choosing quorum],
  [Section 3.1], [Fill gaps with the harmless "olive-day" decree.],
    [`maybeBecomeLeader` proposes the caller's no-op for unrecovered slots
    below the highest recovered slot],
  [Section 2.2 (B1)], [Ballot numbers are partitioned among priests.],
    [`Ballot = (round, priority, node)`; the node component makes reuse
    across owners impossible],
  [Section 2.2 (B2)], [Any two quorums intersect.], [`Membership.init`
    rejects `read + write <= count` (`NonIntersectingQuorums`); majority
    by default, flexible quorums allowed],
  [Progress], [Decrees eventually reach every ledger in the Chamber.],
    [Leader heartbeats advertise `decided_through`; a behind follower
    replies `learn`, which also corrects the leader's stale view of that
    follower; the leader re-releases its own prefix on election],
)

== Durable state

The paper's ledger variables map onto `DurableState`, and the host must
sync them before releasing messages, which the debug-build guard in
`Effects` enforces:

#table(
  columns: (auto, auto, 1.6fr),
  table.header([*Paper*], [*Code*], [*Persisted by*]),
  [`nextBal`], [`durable.promised`], [`Write.promise` (and every
    `Write.accept`, which also advances the promise)],
  [`prevBal`, `prevDec`], [`durable.accepted[slot]`], [`Write.accept`
    before the `accepted` reply may be sent],
  [`outcome`], [`durable.committed[slot]`], [`Write.commit` before the
    commit broadcast],
  [`lastTried`], [reconstructed], [not persisted directly: recovered as
    `promised.round + 1`, which is safe because any accept sent under a
    ballot implies the promise was durably advanced first],
)

A commit that disagrees with a stale local vote is legal and accepted
(the choosing quorum may not have included this node); two commits for
one slot that disagree are corruption (`ConflictingCommit`). The paper
never compares `outcome` against `prevDec`, and neither does the code.

== The oracles that watch the same rules

The simulator checks, after every observed transition: agreement against
a golden first-commit table, validity (proposed or no-op), promise
monotonicity per incarnation, monotone decided prefixes, journal replay
without error, and post-fault convergence. The TLC model checks
`Agreement`, `CommitUniqueness`, `PromisedDominatesVotes`, and `Validity`
over all reachable states of its finite configuration. The mapping from
spec action to handler is one-to-one with the first table above, so a
change to any handler should update this appendix, the simulator's
oracles, and the spec together.
