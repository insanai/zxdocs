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
    guard, `Write.promise`, per-slot `promise` replies, `promise_range`
    chunk descriptor; lower ballots are nacked], [`Promise`],
  [Step 3], [With `LastVote` from a majority, propose the decree of the
    highest-ballot vote, else any decree (B3).], [`onPromise` keeps the
    highest-ballot vote per slot; `maybeResolveChunk` requires complete
    chunk descriptions from a read quorum; `resolveChunk` re-drives
    recovered slots above the quorum's trim and chosen fences and fills
    gaps with the no-op decree], [`Accept` and `ChoosableFor`],
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
    reply carries votes for all instances after `n`.], [`onPrepare` answers
    the bounded chunk `[first, first + chunk - 1]`; `promise_range` carries
    the count so leadership waits for a complete chunk per member, and its
    `more` flag drives the next `prepare`],
  [Section 3.1], [The reply also reports already-passed decrees the
    president may be missing.], [`onPrepare` reports a learned-only decree
    as a zero-ballot vote, which loses to every real vote and can never
    override the choosing quorum],
  [Section 3.1], [Fill gaps with the harmless "olive-day" decree.],
    [`resolveChunk` proposes the caller's no-op for unrecovered slots below
    known state; slots at or below a quorum-reported trim anchor or chosen
    prefix are released history, never gaps],
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

The paper's ledger variables map onto `DurableState`. The host must sync
them before releasing messages. The always-on guard in `Effects` enforces
the required call order in every build mode:

#table(
  columns: (auto, auto, 1.6fr),
  table.header([*Paper*], [*Code*], [*Persisted by*]),
  [`nextBal`], [`durable.promised`], [`Write.promise` (and every
    `Write.accept`, which also advances the promise)],
  [`prevBal`, `prevDec`], [`durable.cells`, slot-tagged, read through
    `acceptedAt(slot)`], [`Write.accept` before the `accepted` reply may be
    sent],
  [`outcome`], [`durable.cells`, slot-tagged, read through
    `committedAt(slot)`], [`Write.commit` before the commit broadcast],
  [`lastTried`], [reconstructed], [not persisted directly: recovered as
    `promised.round + 1`, which is safe because any accept sent under a
    ballot implies the promise was durably advanced first],
)

A commit that disagrees with a stale local vote is legal and accepted
(the choosing quorum may not have included this node); two commits for
one slot that disagree are corruption (`ConflictingCommit`). The paper
never compares `outcome` against `prevDec`, and neither does the code.

The ledger has one extension the paper does not need: `Write.trim_anchor`
persists an adopted chosen-trim anchor (ZDS 0011). After its journal bytes
below the anchor are gone, an acceptor still answers phase one correctly,
because the anchor states that the whole prefix is chosen, and the leader
selection rule never proposes into it.

== The oracles that watch the same rules

The simulator checks, after every observed transition: agreement against
a golden first-commit table, validity (proposed or no-op), promise
monotonicity per incarnation, monotone decided prefixes, journal replay
without error, and post-fault convergence. The TLC model checks
`Agreement`, `CommitUniqueness`, `PromisedDominatesVotes`, and `Validity`
over all reachable states of its finite configuration. A second model,
`specs/GlobalTrim.tla`, covers what the paper predates: the slot-tagged
window, host-licensed eviction, the trimmed-acceptor election fences, the
conservative cluster trim, and the joiner lease lifecycle. The mapping from
spec action to handler is one-to-one with the first table above, so a
change to any handler should update this appendix, the simulator's
oracles, and the spec together.
