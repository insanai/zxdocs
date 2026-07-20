#import "theme.typ": *

= How to Read This Book

#objectives([
  By the end of this chapter you should be able to pick the reading route
  that matches how you will use Zaxonlite, name the entry-point symbol or
  command your route is built around, and state what the repository
  supplies versus what your deployment must still add.
])

Zaxonlite is one implementation serving five kinds of user. The five do not
need the same chapters. They do share one starting point. Everyone begins
with chapter 1, the quickstart, at a shell. Ten minutes there gives you a
durable database, a three-voter cluster, and a leader kill that lost
nothing. That experience is the mental model every later chapter refines.
Reading about failover is abstract. Having caused one is not.

Chapters 2 and 3 finish the shared ground. Chapter 2 is the full `zaxon`
command reference. Chapter 3 turns what you saw at the shell into stated
guarantees. After chapter 3 the routes diverge. Each route is organized
around a symbol or command that exists in the repository today. When a
chapter names an API, the API is real.

== The five readers

#table(
  columns: (auto, auto, 1fr),
  table.header([*Reader*], [*Entry point*], [*Route after chapters 1--3*]),
  [Embedded Zig,\ one node],
  [`Node.open`],
  [Chapter 5 for WAL replication and chapter 6 for storage and recovery.
    Then chapter 9, the embedded-node guide. Then chapter 8 for sessions
    and read levels, and chapter 13 for backup and integrity checking.],
  [Embedded Zig,\ cluster],
  [`Embedded.open`],
  [The one-node route, plus chapter 7 on role-aware clusters before the
    chapter 10 guide. The facade owns the listener, peer senders, and tick
    loop. Chapter 7 explains what those threads are doing.],
  [C ABI embedder],
  [`zaxonlite_open`],
  [Chapter 8 first, because the session contract survives the ABI
    unchanged. Then chapter 11, the C ABI guide. The Zig guides are
    optional background. The C surface is a strict subset with JSON
    results and `zaxonlite_last_error`.],
  [Operator of\ `zaxon serve`],
  [`zaxon serve`],
  [Chapter 7 on clusters, then chapter 13 on operations, then chapter 15
    so you recognize every file in a data directory. Chapter 17 says what
    the failure playbook has actually been tested against.],
  [RPC client or\ gateway developer],
  [`Connection.open`],
  [Chapter 8 on consistency, then chapter 12, then the wire-frame section
    of chapter 15. The gateway is byte-transparent. Authentication and
    frame integrity stay end-to-end between client and storage node.],
)

#api_anchor(`Node.open`,
  [Opens one durable node in-process: a data directory, a journal, and a
    SQLite image, with no network. Empty `members` means a single-member
    configuration of just `node_id`.],
  source: `zaxonlite/src/node.zig`)

#api_anchor(`Embedded.open`,
  [Opens the transport-owning facade: one node plus its TCP listener, peer
    connections, and tick thread, configured from a member list with roles.
    The same API serves one through nine voters plus non-voting replicas.],
  source: `zaxonlite/src/embedded.zig`)

The C entry points are `zaxonlite_open` and `zaxonlite_cluster_open` in
`zaxonlite/src/capi.zig`. They are declared in
`zaxonlite/include/zaxonlite.h`. The client library entry point is
`Connection.open` in `zaxonlite/src/client.zig`, and the gateway is
`gateway.serve` in `zaxonlite/src/gateway.zig`.

#predict([
  Decide now: which of the five readers are you, and which guarantee do
  you most depend on? Durability, exactly-once retry, or read freshness?
  Write the answer down. Chapter 8 will test it.
])

== What the repository supplies, and what you must build

The honest boundary matters as much as the feature list. The repository
supplies the replicated database itself. That means the node and facade
libraries, the C ABI, and the `zaxon` command line with its serve and
client modes. It also means mutually authenticated, integrity-protected
TCP framing, snapshots, logical backup streaming, `zaxon integrity-check`,
`zaxon recover`, and `zaxon status --json` for automation.

Your deployment must still add three things. The release limits state them
directly.

+ *An encrypted tunnel.* The pre-shared-key transport authenticates peers
  and integrity-protects every frame. It does not encrypt. Where SQL
  confidentiality matters, run the TCP links inside a tunnel you provide.
+ *Monitoring and alerting.* The node reports status; nothing in the
  repository watches it. After a fatal storage error the host must stop
  voting and serving. Something of yours must notice and page a human.
+ *Orchestration.* Process supervision, restart policy, and voter
  replacement are operator work. Automatic voter replacement is roadmap,
  not product. A failed voter stays failed until you act.

#callout(title: "Scope is part of correctness", tone: "warning")[
  The guarantees in this book are conditional on that boundary.
  "Acknowledged means durable and decided" holds on POSIX filesystems with
  working fsync. Confidentiality holds only inside your tunnel.
  Availability after a voter loss holds only if your orchestration
  replaces the voter.
]

== How the chapters build on each other

The book has five parts. Part I (chapters 1--3) gets you running: the
quickstart, the `zaxon` CLI, and the product guarantees. Part II (chapters
4--8) explains how it works: architecture, WAL replication, storage,
clusters, and consistency. Part III (chapters 9--12) embeds it: one node
in Zig, a cluster in Zig, the C ABI, and clients and gateways. Part IV
(chapters 13--14) operates it, with a playbook and worked examples. Part V
(chapters 15--18) holds the formats, the desk reference, verification and
benchmarks, and conformance.

The dependency structure is deliberate. Part I gives you the experience
and the vocabulary: descriptor, payload, journal, chosen slot. Within Part
II, storage and clusters are independent of each other, but both feed
chapter 8. Consistency is the last chapter that states guarantees.
Everything after it shows how to use them or how to check them. The guides
assume their Part II chapters. Chapter 10 leans on chapter 7, and chapter
12 leans on chapter 8. The format chapter is normative. When prose and
format disagree, chapter 15 and the frozen format document win. Chapter 17
closes the loop by mapping every stated guarantee to the test that
exercises it. Chapter 18 states what a compatible implementation must do.

Read the callouts the way the theme presents them. A `decision` callout
records a design commitment and its consequence. A `warning` callout marks
a boundary you can silently cross. Checkpoints and exercises exist for one
reason. Recognizing a guarantee on the page is not the same as rebuilding
it from memory during an incident at 3 a.m.

== This book and the zig-paxos book

Zaxonlite is a host of the paxos-zig library, and this book deliberately
does not re-prove consensus. Why a quorum intersects, why a promised
ballot never moves backward, and why a later leader must adopt the highest
accepted value are all proved in the zig-paxos book in `docs/book/`. So
are the effect-machine design of `paxos.Protocol` and the sealed epochs of
`paxos.ReplicatedLog`. This book treats the library as a component with a
contract. Effects come out in order. Every dependent message is sent only
after its write is durably synced. When a Zaxonlite chapter says "the log
chose slot $n$", the zig-paxos book is where "chose" is defined and
defended. Read it when you want the invariant, not just the interface. The
two books share their pedagogy and their style, so moving between them
costs little.

#teach_back([
  A colleague asks: "We already run SQLite; which parts of Zaxonlite do we
  get for free, and which parts are still our job?" Answer in plain
  language. Name your route's entry-point symbol and the three items the
  repository leaves to you. If you cannot name all three, reread the
  boundary section before continuing.
])
