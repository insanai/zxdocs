#import "theme.typ": *

#title_page()
#pagebreak()

#align(center)[
  #text(size: 15pt, weight: "bold")[About this book]
]

This book explains one algorithm. It also explains one implementation of that
algorithm. The two tasks are kept together. A line of code is easier to trust
when we know the fact that requires it. A proof is easier to remember when we
can point to the field that carries its meaning.

The source is written in Typst. The diagrams use Fletcher and CeTZ. The code is
Zig 0.16. The protocol is grounded in Leslie Lamport's "The Part-Time
Parliament" and "Paxos Made Simple"; the reconfiguration layer is closest to
the stop-sign construction described in "Reconfiguring a State Machine".

The text and original code in this repository use the MIT license. The paper by
Lamport has its own copyright. A local copy is present for study.

#book_quote([
  Early in this millennium, the Aegean island of Paxos was a thriving mercantile
  center.
], [Leslie Lamport, "The Part Time Parliament"])

#v(10mm)
#callout([The main promise], [
  A careful reader should be able to derive the core Paxos safety rule, trace
  it into this library's fields and effects, run a three-node example, design
  the missing host services, and review a deployment without confusing a
  protocol guarantee with an application guarantee.
], kind: "idea")

#v(1fr)
#align(center, text(size: 8.5pt, fill: gray)[
  Version 0.1.0. Built with Typst 0.15 or later.
])

#pagebreak()

= Preface

The usual introduction to Paxos starts too late. It starts with prepare and
accept messages. Those messages then look like rules from a game whose purpose
was forgotten.

We shall start earlier. We shall ask a small question.

Three machines must write one word on three pieces of paper. A machine may stop.
A messenger may vanish. No machine may erase ink. How can the machines make
sure that two different words are never declared final?

The answer will grow in small steps. Each step will remove one bad solution.
When prepare and accept finally appear, they will have no mystery left. They are
the shortest names for facts that we already need.

The style of this book is mathematical, but it is not terse. We shall compute
small examples. We shall predict before seeing answers, explain steps in plain
language, and gradually remove hints. We shall make mistakes on purpose. We
shall keep a ledger of the facts that survive every mistake.

The implementation follows the same order. First come values and ballots. Next
come promises and votes. Then come slots, leader recovery, stable storage, and a
replicated state machine. At each point we ask two questions.

+ What can go wrong?
+ Which fact prevents it?

There is one complete runnable example and two progressively larger design
studies.

+ The counter on three nodes is `examples/counter.zig`; it exercises the real
  public API end to end in memory.
+ The key-value service is an explicitly labeled host-design sketch. It adds
  request deduplication, read semantics, recovery, and snapshot ownership.
+ The regional control plane is an architecture exercise. It adds five voters,
  sharding, failure domains, metrics, and capacity calculations without
  pretending that those systems already exist in this repository.

The final parts discuss tests and measurement. The benchmark compares the Zig
library with OmniPaxos 0.2.2 in Rust and a pinned LibPaxos3 core in C. The
comparison uses the same number of nodes and values. It records protocol
differences instead of pretending that the libraries are identical.

#callout([A word about certainty], [
  Testing can reveal a broken invariant. It cannot create an invariant. We
  first state the reason that the code is safe. We then use tests to search for
  errors in our statement and in our code.
])

== How to read the book

The next chapter explains the learning design and offers a protocol route and a
systems-builder route. Parts I through III derive Paxos. Part IV is the library
and host-integration manual. Part V moves from the runnable counter to design
studies. Part VI covers evidence and operations. Part VII is a desk reference.

Short notes marked "Exercise" are part of the argument. A reader who answers
them will remember the proof far longer than a reader who merely agrees with
it. Hints appear when a calculation has a trick.

Code fragments are labeled *repository excerpt*, *runnable fragment*, or
*design sketch*. Repository excerpts and runnable fragments use the current
public API. A sketch may introduce host-owned types such as `Journal` or
`Transport`; those types are not library promises.

== Audience and prerequisites

The book assumes that you can read Zig structs, tagged unions, slices, errors,
and comptime parameters. It does not assume prior study of Paxos or formal
methods. Before building a real service, you should also be comfortable with
write-ahead logging, checksums, process crash recovery, authenticated network
protocols, and deterministic state machines. The book teaches how those pieces
meet this library; it is not a substitute for testing the host implementation.

== Notation

#table(
  columns: (auto, 1fr),
  table.header([*Mark*], [*Meaning*]),
  [`A1`, `A2`, `A3`], [Three acceptors.],
  [`C`], [A candidate or proposer.],
  [`L`], [A learner.],
  [`b = (r, p, n)`], [A ballot with round `r`, priority `p`, and node `n`.],
  [`Q1`, `Q2`], [Phase-one read quorum and phase-two write quorum.],
  [`s`], [A one based log slot.],
  [`v`], [An application value.],
  [`null`], [No prior accepted value.],
)

We use the word "node" for a process that may contain all Paxos roles. We use
"acceptor" when only its voting duty matters. We use "leader" for a proposer
that completed phase one. We use "chosen" for a fact established by a quorum.
We use "committed" for a chosen value that a learner has recorded.

== Commands used in the book

```sh
zig build fmt
zig build test
zig build run
zig build benchmark
zig build book
```

The last command creates `docs/part-time-parliament.pdf`. The aggregate
benchmark builds the pinned Rust package and fetches the pinned C source, so
its first run needs network access. `zig build benchmark-zig` runs only the
local Zig regression workload.

#pagebreak()
#outline(title: [Contents], depth: 3, indent: auto)
