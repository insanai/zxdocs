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
Zig 0.16. The protocol is Paxos as presented by Leslie Lamport in "The Part Time
Parliament" and "Paxos Made Simple".

The text and original code in this repository use the MIT license. The paper by
Lamport has its own copyright. A local copy is present for study.

#book_quote([
  Early in this millennium, the Aegean island of Paxos was a thriving mercantile
  center.
], [Leslie Lamport, "The Part Time Parliament"])

#v(10mm)
#callout([The main promise], [
  A careful reader should be able to derive Paxos, implement the library
  contract, run a three node example, and review a production design after
  working through this book.
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
small examples. We shall stop for exercises. We shall make mistakes on purpose.
We shall keep a ledger of the facts that survive every mistake.

The implementation follows the same order. First come values and ballots. Next
come promises and votes. Then come slots, leader recovery, stable storage, and a
replicated state machine. At each point we ask two questions.

+ What can go wrong?
+ Which fact prevents it?

There are three complete examples.

+ The small example is a counter on three nodes. Every message fits on one page.
+ The middle example is a key value service. It includes client retry, reads,
  recovery, and snapshots.
+ The large example is a regional control plane. It includes five voters, many
  clients, large values, batching, failure domains, metrics, and capacity work.

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

Parts I through III form a course in Paxos. Read them in order. Part IV is the
library manual. Part V contains examples. Part VI covers engineering. Part VII
is a reference for use beside an editor.

Short notes marked "Exercise" are part of the argument. A reader who answers
them will remember the proof far longer than a reader who merely agrees with
it. Hints appear when a calculation has a trick.

Code fragments use the public API unless they are explicitly labeled as
protocol internals. Complete source files remain in the repository. Small
fragments in the book may omit routine error handling only when the omitted
line has already been shown.

== Notation

#table(
  columns: (auto, 1fr),
  table.header([*Mark*], [*Meaning*]),
  [`A1`, `A2`, `A3`], [Three acceptors.],
  [`C`], [A candidate or proposer.],
  [`L`], [A learner.],
  [`b = (r, n)`], [A ballot with round `r` and node `n`.],
  [`Q`], [A quorum.],
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

The last command creates `docs/part-time-parliament.pdf`. The benchmark command
builds the pinned Rust package and fetches the pinned C source. Its first run
needs network access.

#pagebreak()
#outline(title: [Contents], depth: 3, indent: auto)
