#import "theme.typ": *

// ----------------------------------------------------------------------
// Cover
// ----------------------------------------------------------------------

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

// ----------------------------------------------------------------------
// Colophon and orientation
// ----------------------------------------------------------------------

#heading(numbering: none, outlined: false)[About this book]

This book documents Zaxonlite: an embeddable SQLite service replicated by
the paxos-zig Multi-Paxos library, and the `zaxon` command line that hosts
and drives it. It is written for three readers at once:

+ *the application developer*, who wants a durable SQL store with
  exactly-once write retry and knows exactly what is guaranteed;
+ *the operator*, who deploys `zaxon serve` alone or with voters and learners and
  needs the file formats, the recovery story, and the failure playbook;
+ *the engineer*, who wants to see how WAL-frame replication, a
  journal-authoritative storage design, and an explicit-effects Paxos
  core compose into a small, testable system.

The implemented vertical slice is exercised by unit tests, single-process
durability tests, a three-process loopback cluster scenario with a SIGKILL
failpoint, a CLI contract test, a C ABI smoke test, seeded property fuzzing, a
soak run, role/gateway/adverse-network integration tests, and benchmarks.
Protocol v4 adds mutually authenticated, sequenced HMAC framing and
voter-certified learner commits. The 10,000-crash, 100-run, and 1-GiB stress
targets are explicitly deferred; where this book states a current guarantee,
the final chapter names its evidence.

#callout(title: "Reading order", tone: "note")[
  Chapters 1–3 explain what Zaxonlite is and the one idea it is built on
  (replicating committed WAL frames). Chapters 4–6 are the storage,
  cluster, and consistency deep dives. Chapters 7–9 are reference:
  operations, APIs, and on-disk/wire formats. Chapter 10 is the evidence.
]

#v(6mm)
#outline(depth: 2, indent: auto)
