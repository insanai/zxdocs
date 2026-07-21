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
