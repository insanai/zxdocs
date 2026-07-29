#import "theme.typ": *

// Cover

#{
  let cover_ink = rgb("28372f")
  let cover_muted = rgb("74857b")
  let cover_paper = rgb("fbfaf7")
  let cover_green = rgb("e4f0e8")
  let cover_green_line = rgb("6d9a80")
  let cover_peach = rgb("f7e6d9")
  let cover_peach_line = rgb("d39a72")

  set page(
    margin: (x: 23mm, top: 18mm, bottom: 19mm),
    header: none,
    numbering: none,
    background: rect(width: 100%, height: 100%, fill: cover_paper),
  )
  grid(
    columns: (1fr, auto),
    text(size: 7.5pt, weight: "bold", tracking: 1.25pt,
      fill: cover_green_line)[AN EMBEDDED REPLICATED DATABASE],
    text(size: 7.5pt, tracking: 0.8pt, fill: cover_muted)[ZIG · UNRELEASED],
  )

  v(15mm)
  text(size: 40pt, weight: "bold", fill: cover_ink)[Zaxonlite]
  v(5mm)
  text(size: 12pt, fill: cover_muted)[
    Replicated SQLite on Multi-Paxos: WAL frames as the unit of
    consensus, a journal you can trust, and one implementation from an
    embedded durable node to role-aware clustered deployments
  ]
  v(7mm)
  line(length: 28mm, stroke: 1.4pt + cover_peach_line)

  v(16mm)
  align(center)[
    #box(inset: 8pt, radius: 4pt, fill: cover_green,
      stroke: 1pt + cover_green_line)[
      #set text(size: 9pt, fill: cover_ink)
      #raw("execute -> capture frames -> persist payload -> append\n" +
        "journal + fsync -> confirm -> committed -> acknowledge")
    ]
  ]

  v(1fr)
  grid(
    columns: (1fr, auto),
    [
      #text(size: 10pt, fill: cover_ink, weight: "bold")[
        Vikrant Rathore · Ronak Rathore]
      #linebreak()
      #text(size: 8.5pt, fill: cover_muted)[
        with the paxos-zig library and the `zaxon` command line]
    ],
    text(size: 8.5pt, fill: cover_muted)[July 2026],
  )
  pagebreak()
}

// Colophon and orientation

#heading(numbering: none, outlined: false)[About this book]

This book documents Zaxonlite. Zaxonlite is an embeddable SQLite service
replicated by the paxos-zig Multi-Paxos library. Its front door is the
`zaxon` command line, one binary that is both server and client.

The book runs the system before it explains it. Chapter 1 takes you from a
fresh build to a three-voter cluster that survives a killed leader. Chapter
2 covers every `zaxon` command. Chapter 3 states what those commands
promise. Part II then explains how the machine works. Part III moves the
same machine into your own process, in Zig or through the C ABI. Part IV
covers operating it. Part V is reference and evidence.

Six readers use this book, and each gets a guide of their own. All six
start with the quickstart in chapter 1. Running the system first is the
fastest way to build a correct mental model of it.

+ *The Zig developer embedding one durable node* wants a crash-consistent
  SQL store in-process, with no network. Chapter 9 is the guide, built
  around `Node.open`.
+ *The Zig developer embedding a cluster member* owns the listener, peers,
  and role inside one process. Chapter 10 is the guide, built around
  `Embedded.open`.
+ *The C ABI embedder* links `zaxonlite.h` from another language. Chapter
  11 carries the same guarantees across the opaque-handle boundary.
+ *The Python application developer* wants the database behind a DB-API
  2.0 connection. Chapter 12 is the guide, built around `zxlite.connect`.
+ *The operator* deploys `zaxon serve` with voters and learners. Chapters
  14 and 16 supply the failure playbook and the file formats.
+ *The client or gateway developer* speaks the TCP RPC protocol. Chapter
  13 covers leader redirects and the current shared-secret streams.

The implemented vertical slice is tested, not merely described. Its
evidence includes unit tests, single-process durability tests, and a
three-process loopback cluster scenario with a SIGKILL failpoint. It also
includes a CLI contract test, a C ABI smoke test, seeded property fuzzing,
a soak run, role, gateway, and adverse-network integration tests, and
benchmarks. Protocol v8 uses mutual TLS for production, binds peer node IDs,
encrypts traffic, confines the disclosed PSK-only development mode to numeric
loopback, quorum-confirms transferred checkpoint proofs, and pipelines durable
phase-two storage. It also carries the bounded one-time token/CSR enrollment
exchange for nodes already named in the decided registry. Network-hosted
clusters persist that registry durably, and it backs the decided one-for-one
voter replacement operation. The 10,000-crash, 100-run,
and 1-GiB stress targets are explicitly deferred. Where this book states a
current guarantee, chapter 18 names its evidence.

#callout(title: "Reading order", tone: "note")[
  Run first, understand second, embed third. Part I gets a cluster running
  on your machine and states its guarantees. Part II explains the machine:
  architecture, WAL replication, storage, clusters, and consistency. Part
  III embeds it in your own process. Part IV operates it. Part V holds the
  formats, the desk reference, verification, and conformance.
]

#v(6mm)
#outline(depth: 2, indent: auto)
