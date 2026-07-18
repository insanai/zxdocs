#import "theme.typ": *

= How This Book Teaches

Paxos is difficult for a predictable reason: a learner must hold failures,
quorums, ballots, durable state, message order, and application behavior in
mind at once. Adding more explanation can make that problem worse. This book
therefore reveals one layer at a time and repeatedly returns to one question:

#callout([The organizing question], [
  What fact prevents two different values from becoming chosen in one slot?
], kind: "idea")

The learning design follows four bodies of work, but does not pretend that
they offer the same kind of evidence.

+ *Cognitive load research* motivates small conceptual units, integrated
  diagrams and prose, worked traces before independent problems, and gradual
  removal of guidance. Working memory is limited; long-term schemas let an
  expert treat several interacting facts as one unit.
+ *Self-explanation research* motivates the prompts that ask you to explain
  why a step is legal, not merely repeat what happened.
+ *Feynman-inspired practice* motivates plain-language teach-backs, concrete
  analogies, and intellectual honesty at the point where an explanation
  becomes vague. The popular four-step "Feynman technique" is a later
  teaching convention, not a controlled method published by Feynman himself.
+ *Knuth's literate-programming principle* motivates presenting code in the
  order a human needs for understanding. The repository remains ordinary Zig;
  "literate" here describes the exposition, not a generated WEB program.
+ *Lamport's method* supplies the technical spine: state the goal, derive an
  invariant, describe state and next-state actions, and only then inspect the
  message protocol and code.

These principles are design constraints, not guarantees. Learning still
requires tracing executions, retrieving ideas without the page, and building
something that fails under controlled conditions.

== The three representations

Every important idea appears at three levels. Do not advance merely because
the vocabulary looks familiar.

#table(
  columns: (auto, 1.2fr, 1.4fr),
  table.header([*Level*], [*Question*], [*Evidence of understanding*]),
  [1. Safety goal], [What must never happen?], [You can state the property
    without protocol words.],
  [2. State transition], [Which state changes preserve it?], [You can trace a
    transition and name the invariant it keeps true.],
  [3. Zig effect], [Which field, write, and message implements it?], [You can
    use the public API while preserving write-before-send.],
)

This order follows Lamport's recommended separation between what an algorithm
must accomplish, a high-level algorithm, and the message-passing algorithm.
It also limits split attention: a code fragment is introduced next to the fact
that makes the fragment necessary.

== The learning loop

Each chapter uses the same six moves.

1. *Orient.* Read the learning contract and recall its prerequisites.
2. *Predict.* Commit to an answer before the trace reveals it.
3. *Study a worked case.* Follow every state change and its reason.
4. *Complete a faded case.* Supply one or more omitted decisions.
5. *Teach it back.* Close the book and explain the idea in plain language.
6. *Transfer.* Change the failure schedule, quorum, or application and decide
   whether the reasoning still holds.

The exercises deliberately fade. Early questions include a hint and name the
relevant invariant. Later questions ask you to diagnose an execution or design
a host component with less guidance. If you already build consensus systems,
start at a chapter's checkpoint and move backward only when your explanation
has a gap; excessive guidance can itself become distracting for experts.

== Two routes through the book

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Route*], [*Read in order*], [*Do, do not merely read*]),
  [Protocol learner], [Parts I--III, then the counter in Part V, then Part IV.],
    [Draw the quorum traces and answer every teach-back from memory.],
  [Systems builder], [This chapter, Parts IV--VI, then return to Parts I--III
    whenever an invariant is named.], [Run the example, implement an effect
    consumer, and rehearse recovery before adding a transport.],
)

== What this repository actually supplies

The boundary matters. The repository contains:

+ `paxos.Protocol`, a bounded Paxos/Multi-Paxos effect machine;
+ `paxos.ReplicatedLog`, a stop-sign layer for sealed configurations and
  snapshot epochs;
+ one complete in-memory three-node counter in `examples/counter.zig`;
+ deterministic unit tests for ballots, recovery, duplicates, catch-up,
  batching, timeouts, reconfiguration, and bounded capacity;
+ local CPU benchmarks whose numbers are regression signals, not production
  latency claims.

It does *not* contain a production journal, network transport, codec,
authentication layer, client session service, snapshot store, linearizable
read service, or a general deterministic fault simulator. Parts V and VI show
how to design those host components and clearly label non-runnable sketches.

#warning([Scope is part of correctness], [
  A protocol library can preserve its invariant and the resulting service can
  still be wrong because the host sent before syncing, reused an identity,
  applied a command twice, trusted an unauthenticated envelope, or served a
  read with stronger semantics than it actually implemented.
])

== Start with retrieval, not recognition

Before Part I, close this page and answer on blank paper:

+ What is the one outcome consensus must forbid?
+ Why might a majority be useful after a crash?
+ Which actions belong to the library, and which belong to the host?

Keep the paper. At the end of Part III, answer again without looking and
compare the two explanations. The difference is more useful than a feeling of
familiarity.

#teach_back([
  Explain the book's three levels to a colleague. If your explanation uses the
  words "Paxos", "ballot", or "quorum" at level 1, try again without them.
])
