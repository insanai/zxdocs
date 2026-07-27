#import "theme.typ": *

#part_page("VII", [Desk reference], [
  Messages, effects, APIs, errors, invariants, exercise answers, and research
  sources collected beside one another.
])

= Consensus Desk Reference

== Message reference

#table(
  columns: (auto, 1.2fr, 1.55fr),
  table.header([*Message*], [*Fields*], [*Meaning*]),
  [`prepare`], [`ballot, decided_through`], [Ask an acceptor to promise this
    ballot and report accepted state above the candidate's prefix.],
  [`promise`], [`ballot, slot, accepted`], [Report one accepted slot for
    phase-one recovery.],
  [`promise_done`], [`ballot, accepted_count, decided_through`], [State the
    number of distinct entries that completes this acceptor's reply.],
  [`accept`], [`ballot, slot, value`], [Ask an acceptor to vote.],
  [`accepted`], [`ballot, slot, decided_through`], [Acknowledge a durable vote
    and report the local released prefix.],
  [`commit`], [`slot, value`], [Teach a value that a correct sender knows was
    chosen.],
  [`learn`], [`from_slot`], [Request known commits from a nonzero slot.],
  [`nack`], [`rejected, promised, decided_through`], [Reject a stale ballot and
    report the higher promise and local prefix.],
  [`heartbeat`], [`ballot, decided_through`], [Leader traffic for a matching
    durable promise.],
)

== Effect ordering

#table(
  columns: (auto, 1.1fr, 1.65fr),
  table.header([*Write*], [*Fields*], [*Must be durable before*]),
  [`promise`], [`ballot`], [`promise`, `promise_done`, or other evidence that
    depends on the promise.],
  [`accept`], [`ballot, slot, value`], [`accepted` and any later claim based on
    that vote.],
  [`commit`], [`slot, value`], [Commit broadcast from the leader, application
    delivery, and catch-up claims based on that record.],
)

Consume one batch as: append writes in order; sync the batch; call
`confirmWritesDurable`; send messages; apply released entries in order. Do not
call another transition before draining the batch. On append or sync failure,
discard the already-mutated live node and restore from verified durable state.
Every optimize mode enforces the confirmation step: reading `messagesSlice`
first stops the process with `paxos: messagesSlice before
confirmWritesDurable`, and resetting an unconfirmed batch stops it with
`paxos: reset discarded unconfirmed writes`.

== Core API

#table(
  columns: (1.3fr, 1.7fr),
  table.header([*Symbol*], [*Contract*]),
  [`Protocol(Value, Options)`], [Creates fixed-membership bounded Paxos types;
    `Value` must contain no pointer, slice, or reference recursively.],
  [`Membership.init(ids)`], [Validates nonzero unique IDs and quorum sizes.],
  [`Node.init`, `initWithPriority`], [Bootstrap an empty member.],
  [`Node.restore`, `restoreWithPriority`], [Restore protocol durable state;
    application state remains host-owned.],
  [`campaign(noop)`, `tick(noop)`], [Start phase one explicitly or advance
    deterministic liveness counters.],
  [`step(envelope)`], [Process one authenticated, decoded member envelope for
    this recipient.],
  [`propose`, `proposeBatch`], [Assign slots after phase one; return
    `NotLeader` otherwise.],
  [`reconnected`, `requestCatchUp`], [Repair one peer path or emit a same-epoch
    `learn` request.],
  [`committedAt`, `readDecided`], [Inspect the local decided log; not an
    application read protocol.],
  [`currentLeader`, `decidedThrough`], [Diagnostic leader hint and contiguous
    released prefix.],
  [`Effects.init/reset`], [Initialize or clear active counts without clearing
    backing storage. Public transitions reset automatically. `reset` stops the
    process if the batch holds unconfirmed writes.],
  [`Effects.confirmWritesDurable`], [Host statement that the pending batch is
    durable; required before `messagesSlice` in every optimize mode.],
  [`DurableState.apply`], [Reference replay semantics for ordered `Write`
    records; not a disk format.],
  [`host_managed.Protocol(Value, Options)`], [Same types without the runtime
    ordering check; the host owns the durability boundary. An audited
    exception for grouped-barrier hosts only.],
)

== Replicated-log API

`ReplicatedLog(Value, Options)` wraps `Protocol` with an `Entry` union of
`command` and `stop`. Its bound is named `max_entries`, not `max_slots`.

#table(
  columns: (1.35fr, 1.65fr),
  table.header([*Symbol*], [*Contract*]),
  [`init(id, configuration_id, membership)`], [Start a nonzero configuration.],
  [`campaign`, `tick`, `step`], [Core operations with application `Value`
    no-ops wrapped as commands.],
  [`append`, `appendBatch`], [Propose commands unless a stop is pending or
    decided.],
  [`reconfigure(id, members, metadata)`], [Propose a strictly newer stop sign
    and seal local appends.],
  [`checkpoint(metadata)`], [Propose same-membership stop with ID plus one; does
    not create or verify a snapshot.],
  [`isReconfigured()`], [Return the *decided* stop, which permits host
    handover.],
  [`initFromStop`], [Validate the stop's member slice and start its
    configuration.],
  [`read`, `decidedThrough`, `currentLeader`], [Inspect this bounded
    configuration.],
  [`configurationId`], [Return the host-supplied durable epoch identity.],
)

== State lifetime

#table(
  columns: (auto, 1fr, auto),
  table.header([*Field*], [*Meaning*], [*Lifetime*]),
  [`durable.promised`], [Highest ballot this acceptor permits.], [Durable],
  [`durable.accepted`], [Highest stored ballot/value per slot.], [Durable],
  [`durable.committed`], [Known chosen value per slot.], [Durable],
  [`role`, `ballot`, `leader_hint`], [Local leadership state.], [Volatile],
  [`highest_observed_round`], [Largest round seen in higher traffic.], [Volatile],
  [`next_slot`], [Next proposal slot or zero.], [Rebuilt],
  [`delivered_through`], [Prefix released in this process.], [Volatile],
  [`promise_*`, `recovered`], [Phase-one completion and recovery state.], [Volatile],
  [`proposals`, `acknowledgements`], [Leader state per active slot.], [Volatile],
  [`configuration_id`], [Replicated-log epoch identity.], [Host must persist],
  [`stop_pending`, `stop_sign`], [Seal state derived from core state/effects.], [Rebuilt],
)

== Error reference

#table(
  columns: (auto, 1fr),
  table.header([*Error*], [*Meaning*]),
  [`EmptyMembership`, `TooManyMembers`], [Membership length violates bounds.],
  [`InvalidNodeId`, `DuplicateNodeId`], [ID zero or duplicate ID.],
  [`InvalidReadQuorum`, `InvalidWriteQuorum`], [Configured size is zero or
    exceeds actual membership.],
  [`NonIntersectingQuorums`], [`read + write <= member_count`.],
  [`NotMember`, `WrongRecipient`, `InvalidPeer`], [Invalid envelope or peer
    identity for this operation.],
  [`NotLeader`], [Proposal attempted before completed phase one.],
  [`BallotExhausted`], [No greater `u64` round exists.],
  [`InvalidSlot`, `SlotLimitReached`], [Slot zero or no remaining bounded slot.],
  [`EmptyBatch`, `SlotBufferTooSmall`, `BatchTooLarge`], [Invalid batch input or
    output capacity.],
  [`ReadBufferTooSmall`], [Caller output cannot hold the available prefix.],
  [`InvalidPromise`, `MissingNoop`, `MissingProposedValue`], [Incomplete or
    inconsistent leader recovery state.],
  [`PromiseRegression`, `ConflictingValue`, `ConflictingCommit`], [Replay or
    transition contradicts durable monotonicity.],
  [`InvalidConfigurationId`, `ConfigurationIdRegression`], [Zero or non-newer
    configuration ID.],
  [`ConfigurationIdExhausted`], [No next `u64` configuration ID.],
  [`MetadataTooLarge`, `LogSealed`], [Stop metadata exceeds its bound or the
    current configuration no longer accepts commands.],
)

`paxos.explainError(err)` supplies operator-oriented prose. Errors from host
I/O have no protocol-specific explanation and must retain their original
storage or transport context.

== Formula sheet

#table(
  columns: (1.4fr, auto, 1.2fr),
  table.header([*Quantity*], [*Formula*], [*Example*]),
  [Majority], [`floor(N / 2) + 1`], [`N=5` gives 3.],
  [Majority crash tolerance], [`N - majority`], [`5 - 3` gives 2.],
  [Uniform flexible safety], [`Q1 + Q2 > N`], [`4 + 2 > 5`.],
  [Stable-path logical messages], [`3(N - 1)`], [`N=3` gives 6: accepts,
    accepted replies, commits.],
  [Approximate epoch duration], [`remaining_slots / peak_slot_rate`], [Reserve
    capacity for recovery and the stop sign.],
  [Accept payload egress], [`payload_bytes * peers * proposals_per_second`],
    [Excludes headers, retransmits, and commit payloads.],
)

== Invariants for review

1. Complete ballots are unique and totally ordered.
2. Every allowed phase-one quorum intersects every allowed phase-two quorum.
3. An acceptor never accepts below its durable promise.
4. One ballot and slot never carry two different values.
5. A new leader selects the value with the greatest accepted ballot in each
   slot across a complete phase-one quorum, or uses a no-op for a required hole.
6. A value is chosen when a phase-two quorum has accepted it; knowledge and
   commit dissemination may occur later.
7. A committed slot never changes value.
8. Application release is a contiguous slot prefix.
9. Every effect-dependent message waits for all writes in its batch to sync.
10. Slots are not reused within an epoch, and a new epoch begins only after a
    decided stop sign and correct host state transfer.

== Answers to selected exercises

=== Exercise 1.1
A majority of five is three. Two nodes may be unavailable while three remain.

=== Exercise 2.1
`{A1, A2}` and `{A3, A4}` do not intersect. They could choose conflicting
values independently if both were legal quorums.

=== Exercise 4.1
Choose `apple` from ballot 9. Do not count values. Knowledge that ballot 3 was
chosen does not alter the mechanical rule; safety implies the ballot-9 vote is
also `apple` if the history is legal.

=== Exercise 4.2
The shared acceptor may have any name; both value blanks are `x`.

=== Exercise 8.1
`tea` is already chosen when the quorum accepts, before the commit record or
broadcast. Durable accepted records in every future intersecting recovery
quorum force later leaders to preserve `tea`; `coffee` cannot be chosen.

=== Exercise 11.1
Do not start a new epoch at prefix 80. Stop new appends, recover and decide the
accepted slots (or have a higher ballot lawfully select their values), apply
the complete prefix, snapshot it, decide the stop sign, and only then hand over.

=== Exercise 14.1
With `N=7` and `Q2=3`, phase one must satisfy `Q1+3>7`, so `Q1=5` is the
minimum. Leader replacement can tolerate two unavailable members.

== Glossary

#table(
  columns: (auto, 1fr),
  table.header([*Term*], [*Meaning*]),
  [Accepted], [One acceptor durably voted for a ballot, slot, and value.],
  [Chosen], [A phase-two quorum accepted one value in one slot.],
  [Committed], [A learner durably recorded a value known to be chosen.],
  [Applied], [The host state machine executed a committed entry.],
  [Ballot], [A unique ordered proposal attempt `(round, priority, node)`.],
  [Epoch], [One bounded configuration with fixed membership and fresh slots.],
  [Leader], [A candidate that completed phase one for its ballot.],
  [No-op], [A host-defined value that consumes a slot without application work.],
  [Promise], [A durable refusal to accept lower ballots.],
  [Quorum], [A voter subset participating in a phase.],
  [Slot], [A one-based position in the bounded log.],
  [Stop sign], [A decided entry that names the next configuration and seals the old one.],
)

== Research and design sources

=== Paxos, state machines, and proof structure

+ #link("https://lamport.azurewebsites.net/pubs/lamport-paxos.pdf")[Leslie
  Lamport, "The Part-Time Parliament"] develops the replicated state-machine
  setting and the ballot invariants.
+ #link("https://lamport.azurewebsites.net/pubs/paxos-simple.pdf")["Paxos Made
  Simple"] derives the proposal rules from consensus safety requirements.
+ #link("https://lamport.azurewebsites.net/tla/paxos-algorithm.html")["The
  Paxos Algorithm"] teaches three levels: goal, high-level state algorithm,
  and message algorithm.
+ #link("https://lamport.azurewebsites.net/pubs/teaching-concurrency.pdf")["Teaching
  Concurrency"] argues that state, next-state relations, and invariants are the
  foundation for understanding concurrent systems.
+ #link("https://lamport.azurewebsites.net/proofs/proofs.html")["How to Write a
  Proof"] motivates hierarchical structure for long reasoning.
+ #link("https://lamport.azurewebsites.net/pubs/reconfiguration-tutorial.pdf")["Reconfiguring
  a State Machine"] describes stop signs, padding, and configuration handover.
+ #link("https://lamport.azurewebsites.net/pubs/stoppable.pdf")["Stoppable
  Paxos"] supplies a more formal stop construction.
+ #link("https://arxiv.org/abs/1608.06696")[Howard, Malkhi, and Spiegelman,
  "Flexible Paxos"] states the cross-phase quorum intersection trade-off.

=== Learning design

+ #link("https://doi.org/10.1023/A:1022193728205")[Sweller, van Merrienboer,
  and Paas, "Cognitive Architecture and Instructional Design"] reviews limited
  working memory, schemas, worked examples, split attention, and redundancy.
+ #link("https://doi.org/10.1207/S1532690XCI0701_1")[Ward and Sweller,
  "Structuring Effective Worked Examples"] studies attention and cognitive
  load in worked-example design.
+ #link("https://doi.org/10.1023/B:TRUC.0000021815.74806.F6")[Renkl, Atkinson,
  and Große, "How Fading Worked Solution Steps Works"] motivates transition
  from examples to completion and independent problems.
+ #link("https://doi.org/10.1207/s15516709cog1302_1")[Chi et al.,
  "Self-Explanations"] supplies the empirical basis for explaining why each
  worked step follows.
+ #link("https://doi.org/10.1111/j.1467-9280.2006.01693.x")[Roediger and
  Karpicke, "Test-Enhanced Learning"] motivates retrieval after a delay rather
  than relying on rereading familiarity.

=== Feynman and Knuth as design influences

+ #link("https://feynman.com/science/what-is-science/")[Richard Feynman, "What
  Is Science?"] models concrete explanation, observation, doubt, and admitting
  when an explanation fails. It is a lecture, not an instructional trial.
+ #link("https://ctlo.caltech.edu/aboutctlo/whoweserve/undergraduates/learning-resources/learning/power-of-teaching")[Caltech,
  "The Power of Teaching"] presents a modern Feynman-inspired teach-to-learn
  routine and explicitly links vagueness to a study gap.
+ #link("https://cs.stanford.edu/~knuth/lp.html")[Donald Knuth, "Literate
  Programming"] treats programs as literature addressed to people. This book
  adopts its human-first exposition without claiming an empirical learning
  effect or generating Zig from prose.

== Closing note

Paxos is not a bag of messages. It is one preservation rule carried through
time. Quorum intersection finds a witness. Stable storage lets the witness
remember. Phase one asks. Phase two records. Slots order decisions. The host
makes those abstract facts physical with sync, codecs, identity, deterministic
application, snapshots, and recovery.

#teach_back([
  Close the book and explain the entire protocol in six sentences. Reopen this
  invariant list, mark the first omitted fact, and revise only that sentence.
  The gap—not the first draft—is the learning result.
])
