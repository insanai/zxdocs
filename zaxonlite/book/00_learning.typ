#import "theme.typ": *

= How to Read This Book

#objectives([
  By the end of this chapter you should be able to pick the reading route
  that matches how you will use Zaxonlite, name the entry-point symbol or
  command your route is built around, and state what the repository
  supplies versus what your deployment must still add.
])

Zaxonlite is one implementation serving six kinds of user. The six do not
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

== The six readers

#table(
  columns: (auto, auto, 1fr),
  table.header([*Reader*], [*Entry point*], [*Route after chapters 1--3*]),
  [Embedded Zig,\ one node],
  [`Node.open`],
  [Chapter 5 for WAL replication and chapter 6 for storage and recovery.
    Then chapter 9, the embedded-node guide. Then chapter 8 for sessions
    and read levels, and chapter 14 for backup and integrity checking.],
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
  [Python application\ developer],
  [`zxlite.connect`],
  [Chapter 8 for the session and read-level contract, then chapter 12,
    the Python guide. The SDK is DB-API 2.0 over the C ABI; chapter 11
    is optional background on the library it rides.],
  [Operator of\ `zaxon serve`],
  [`zaxon serve`],
  [Chapter 7 on clusters, then chapter 14 on operations, then chapter 16
    so you recognize every file in a data directory. Chapter 18 says what
    the failure playbook has actually been tested against.],
  [RPC client or\ gateway developer],
  [`Connection.open`],
  [Chapter 8 on consistency, then chapter 13, then the wire-frame section
    of chapter 16. The gateway is byte-transparent. Authentication and
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
  Decide now: which of the six readers are you, and which guarantee do
  you most depend on? Durability, exactly-once retry, or read freshness?
  Write the answer down. Chapter 8 will test it.
])

== What the repository supplies, and what you must build

The honest boundary matters as much as the feature list. The repository
supplies the replicated database itself. That means the node and facade
libraries, the C ABI, and the `zaxon` command line with its serve and
client modes. It also means shared-secret, integrity-protected TCP framing,
a mutual TLS 1.3 transport with per-node certificates,
snapshots, logical backup streaming, `zaxon integrity-check`,
`zaxon recover`, and `zaxon status --json` for automation. The shared
secret alone is not a production identity boundary; the TLS mode is,
once you provision its certificates.

Your deployment must still provide four things. The release limits state them
directly.

+ *Application authentication.* Zaxonlite has one database principal. Your
  application authenticates its users and decides which operations and SQL
  they may issue.
+ *A production transport.* Use the embedded API in process, the
  owner-only Unix-domain socket (`--listen unix:<path>`) for local
  service, or mutual TLS with per-node certificates for TCP clusters.
  Bootstrap the CA and one issuer identity out of band; an authenticated
  operator can then issue a short-lived one-time bundle so a configured node
  generates its key and CSR locally. The PSK mode proves only shared secret
  possession and does not encrypt; `--dev-psk` confines that tradeoff to a
  numeric-loopback local development cluster.
+ *Monitoring and alerting.* The node reports status; nothing in the
  repository watches it. After a fatal storage error the host must stop
  voting and serving. Something of yours must notice and page a human.
+ *Orchestration.* Process supervision, restart policy, and voter
  replacement are operator work. Automatic voter replacement is roadmap,
  not product. A failed voter stays failed until you act, but the act
  itself is now a first-class operation: on a network-hosted cluster,
  `zaxon replace-voter` replaces one failed data voter with one fresh
  voter through a decided configuration change (chapter 7).

#callout(title: "Scope is part of correctness", tone: "warning")[
  The guarantees in this book are conditional on that boundary.
  "Acknowledged means durable and decided" holds on POSIX filesystems with
  working fsync, and on NTFS from Windows 10 1809 onward, which a node
  verifies before it opens. Wire confidentiality holds only inside TLS, and offline-media
  confidentiality depends on OS disk or filesystem encryption.
  Availability after a voter loss holds only if you replace the voter.
  On a served cluster the decided `zaxon replace-voter` operation is
  the supported way to do that; noticing the loss and deciding to run
  it is still your orchestration's job.
]

== How the chapters build on each other

The book has five parts. Part I (chapters 1--3) gets you running: the
quickstart, the `zaxon` CLI, and the product guarantees. Part II (chapters
4--8) explains how it works: architecture, WAL replication, storage,
clusters, and consistency. Part III (chapters 9--13) embeds it: one node
in Zig, a cluster in Zig, the C ABI, the Python SDK, and clients and
gateways. Part IV (chapters 14--15) operates it, with a playbook and
worked examples. Part V (chapters 16--19) holds the formats, the desk
reference, verification and benchmarks, and conformance.

The dependency structure is deliberate. Part I gives you the experience
and the vocabulary: descriptor, payload, journal, chosen slot. Within Part
II, storage and clusters are independent of each other, but both feed
chapter 8. Consistency is the last chapter that states guarantees.
Everything after it shows how to use them or how to check them. The guides
assume their Part II chapters. Chapter 10 leans on chapter 7, and chapter
13 leans on chapter 8. The format chapter is normative. When prose and
format disagree, chapter 16 and the frozen format document win. Chapter 18
closes the loop by mapping every stated guarantee to the test that
exercises it. Chapter 19 states what a compatible implementation must do.

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
