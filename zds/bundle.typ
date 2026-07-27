#import "../shared/zds.typ": zds-site-index
#import "registry.typ": zds-documents

#document(
  "index.html",
  title: [Zaxon Discussions],
  author: ("Zaxon Contributors",),
  description: [Index of Zaxon Discussion records.],
)[
  #zds-site-index(zds-documents)
]

#document(
  "zds/0001-zds-process.html",
  title: [ZDS 0001: The Zaxon Discussion Process],
  author: ("Zaxon Contributors",),
  description: [ZDS process and Typst project workflow.],
)[
  #include "records/0001-zds-process.typ"
]

#document(
  "zds/0002-zaxonlite-product-plan.html",
  title: [ZDS 0002: Zaxonlite: Product and Delivery Plan],
  author: ("Zaxon Contributors",),
  description: [In-process SQLite replicated by the Zig Multi-Paxos library: architecture, durability model, cluster roles, safety argument, and delivery plan.],
)[
  #include "records/0002-zaxonlite-product-plan.typ"
]

#document(
  "zds/0003-zaxonlite-security-remediation-plan.html",
  title: [ZDS 0003: Zaxonlite Security and Trust Plan],
  author: ("Zaxon Contributors",),
  description: [Trust model, deployment boundaries, risk register, findings and remediations, enrollment, assurance strategy, and release acceptance criteria.],
)[
  #include "records/0003-zaxonlite-security-remediation-plan.typ"
]

#document(
  "zds/0004-zaxonlite-format.html",
  title: [ZDS 0004: Zaxonlite Format and Compatibility Contract],
  author: ("Zaxon Contributors",),
  description: [Frozen first-release formats: protocol v6, enrollment records, descriptor and payload, journal, identity and snapshots, release limits, and upgrade procedure.],
)[
  #include "records/0004-zaxonlite-format.typ"
]

#document("pdf/zds-0001-zds-process.pdf")[
  #include "records/0001-zds-process.typ"
]

#document("pdf/zds-0002-zaxonlite-product-plan.pdf")[
  #include "records/0002-zaxonlite-product-plan.typ"
]

#document("pdf/zds-0003-zaxonlite-security-remediation-plan.pdf")[
  #include "records/0003-zaxonlite-security-remediation-plan.typ"
]

#document("pdf/zds-0004-zaxonlite-format.pdf")[
  #include "records/0004-zaxonlite-format.typ"
]

#document(
  "zds/0005-zaxon-interactive-shell.html",
  title: [ZDS 0005: A Rich Interactive Shell for the zaxon CLI],
  author: ("Zaxon Contributors",),
  description: [Plans the rich zaxon interactive shell on the libvaxis terminal library: grapheme-aware cursor line editing, ctrl+r incremental history search, comptime-driven dot-command dispatch and SQL keyword highlighting, width-aware colored tables with expanded and paged views, first-class Windows support, and the extraction of all CLI presentation code out of main.zig.],
)[
  #include "records/0005-zaxon-interactive-shell.typ"
]

#document("pdf/zds-0005-zaxon-interactive-shell.pdf")[
  #include "records/0005-zaxon-interactive-shell.typ"
]

#document(
  "zds/0006-windows-durability.html",
  title: [ZDS 0006: Windows Durability and the Supported Platform Floor],
  author: ("Zaxon Contributors",),
  description: [States how an authoritative pathname transition is made durable on Windows, where no directory sync exists: NTFS records the change in a volume-wide write-ahead log that a file flush commits, so the barrier follows the rename instead of preceding it. Sets the supported floor at Windows 10 1809 on NTFS, enforced by a startup probe rather than a version check.],
)[
  #include "records/0006-windows-durability.typ"
]

#document("pdf/zds-0006-windows-durability.pdf")[
  #include "records/0006-windows-durability.typ"
]

#document(
  "zds/0007-paxos-zig-0-1-hardening.html",
  title: [ZDS 0007: paxos-zig 0.1.x Safety Hardening],
  author: ("Zaxon Contributors",),
  description: [A focused patch release that enforces the durability boundary in every build mode],
)[
  #include "records/0007-paxos-zig-0-1-hardening.typ"
]

#document("pdf/zds-0007-paxos-zig-0-1-hardening.pdf")[
  #include "records/0007-paxos-zig-0-1-hardening.typ"
]
