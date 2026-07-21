#let zds-number = "0001"
#let zds-title = "The Zaxon Discussion Process"
#let zds-state = "published"
#let zds-created = "2026-07-21"
#let zds-discussion = "Process document"
#let zds-labels = ("documentation", "process",)
#let zds-authors = ("Zaxon Contributors <team@zaxon.local>",)
#let zds-category = "Process Memo"
#let zds-status = "Published"
#let zds-last-updated = "2026-07-21"

#import "../../shared/zds.typ": zds-document
#import "@preview/fletcher:0.5.8" as fletcher: diagram, edge, node

// State palette, matching the chip colors in shared/zds.typ.
#let c-pre = (fill: rgb("fef3c7"), stroke: rgb("b45309"))
#let c-disc = (fill: rgb("dcfce7"), stroke: rgb("15803d"))
#let c-acc = (fill: rgb("fef9c3"), stroke: rgb("a16207"))
#let c-pub = (fill: rgb("dbeafe"), stroke: rgb("1d4ed8"))
#let c-com = (fill: rgb("ede9fe"), stroke: rgb("7c3aed"))
#let c-aband = (fill: rgb("e5e7eb"), stroke: rgb("64748b"))

#let state-node(pos, name, caption, palette, width: auto) = node(
  pos,
  align(center)[
    #text(9.5pt, weight: "bold", fill: palette.stroke.darken(20%))[#name]
    #linebreak()
    #text(7pt, fill: rgb("475569"))[#caption]
  ],
  fill: palette.fill,
  stroke: 0.9pt + palette.stroke,
  shape: fletcher.shapes.rect,
  corner-radius: 5pt,
  inset: 7pt,
  width: width,
)

#let start-node(pos) = node(
  pos,
  [],
  shape: fletcher.shapes.circle,
  fill: rgb("1f2937"),
  stroke: none,
  radius: 1.5mm,
)

#let edge-label(body) = text(7.3pt, fill: rgb("475569"), style: "italic")[#body]

// PDF renders the diagram directly; the experimental HTML export embeds it
// as a typeset frame so the flowchart survives on the bundle website.
#let zds-figure(body) = context {
  if target() == "html" {
    html.frame(align(center, body))
  } else {
    align(center, body)
  }
}

#show: doc => zds-document(
  zds-number,
  zds-title,
  doc,
  authors: zds-authors,
  state: zds-state,
  created: zds-created,
  discussion: zds-discussion,
  labels: zds-labels,
  category: zds-category,
  status: zds-status,
  last-updated: zds-last-updated,
)

= Abstract

The paxos-zig monorepo needs a durable decision-record process for
architectural, product, security, and documentation changes across the
Multi-Paxos library and the Zaxonlite embedded replicated SQLite package. The
project now uses Zaxon Discussions, or ZDS, as RFC/RFD-style Typst documents
that support structured reasoning, long-lived references, high-quality PDF
output, and an HTML discussion website.

This memo defines the lifecycle of a ZDS, the placeholder numbering workflow,
the authoring expectations, and the Typst project layout.

= Introduction

A Zaxon Discussion is a Typst document stored in git under
`docs/zds/records`. Each discussion is part design memo, part review artifact,
and part historical record. The structure is intentionally close to IETF RFCs
and Oxide RFDs because those formats force explicit scope, status, rationale,
alternatives, and operational considerations instead of relying on implicit
context.

ZDS is used for topics such as:

- consensus protocol and replicated-log design changes
- Zaxonlite product, storage, and format decisions
- security assessments, trust boundaries, and remediation plans
- verification strategy (simulation harness, TLA+ specs, conformance)
- contributor and documentation process decisions

Active design reasoning, trade-offs, and decisions belong in ZDS. The two
Typst books (`docs/book.typ` for the Paxos library and
`docs/zaxonlite/book.typ` for Zaxonlite) remain the descriptive manuals of the
current system; a ZDS records why the system became that way.

= Terminology and Scope

- *ZDS*: a Zaxon Discussion document
- *placeholder draft*: a local Typst draft using the placeholder number `XXXXX`
- *assigned ZDS*: an accepted discussion with a permanent four-digit number
- *registry*: the Typst metadata list in `docs/zds/registry.typ` used by the
  index and bundle entry point
- *bundle*: the experimental Typst export target that can emit the HTML index,
  HTML discussion pages, and per-ZDS PDFs from one entry point

This memo defines the repository workflow for ZDS. It does not define future
CI automation in full detail, but it does define the expected behavior of that
automation.

= Discussion Lifecycle

New discussions begin as placeholder drafts.

- Contributors copy `docs/zds/template/rfc-template.typ` to
  `docs/zds/records/XXXXX-<slug>.typ`.
- The document uses the placeholder number `XXXXX` while the author iterates.
- The registry-driven Zaxon Discussions index includes placeholder drafts
  after assigned discussions.
- When the draft is ready, maintainers assign the next permanent ZDS number
  and rename the file to `NNNN-<slug>.typ`.
- The registry is updated with the document's area, status, summary, source
  path, HTML path, and PDF path.

This keeps cloning and local authoring simple. Contributors do not need a
global lock or remote numbering check just to start writing.

== Local Workflow Diagram

#zds-figure(
  diagram(
    spacing: (13mm, 9mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    start-node((0, 0)),
    state-node(
      (1, 0),
      [1. Create draft],
      [copy template #linebreak() `XXXXX-slug.typ`],
      c-pre,
    ),
    state-node(
      (2, 0),
      [2. Iterate locally],
      [state = `prediscussion`],
      c-pre,
    ),
    state-node(
      (3, 0),
      [3. Assign number],
      [maintainer review #linebreak() `NNNN-slug.typ`],
      c-disc,
    ),
    state-node(
      (4, 0),
      [4. Publish / commit],
      [same number #linebreak() later state changes],
      c-pub,
    ),
    edge((0, 0), (1, 0), "-|>"),
    edge((1, 0), (2, 0), "-|>"),
    edge((2, 0), (2, 0), edge-label[revise], "-|>", bend: 130deg),
    edge((2, 0), (3, 0), edge-label[ready], "-|>"),
    edge((3, 0), (4, 0), edge-label[registry], "-|>"),
  ),
)

= States

ZDS documents can move through these states:

- `prediscussion`: local draft or early working document
- `discussion`: open for review and feedback
- `accepted`: accepted as the intended direction, not yet fully implemented
- `published`: accepted into the repository as the current design record
- `committed`: fully implemented and now descriptive of the current system
- `abandoned`: deliberately closed without adoption

== State Transition Diagram

Solid edges are the forward path of a discussion; dashed edges close a
document without adoption. The filled dot is the moment a contributor copies
the template.

#zds-figure(
  diagram(
    spacing: (14mm, 11mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    start-node((0, 1)),
    state-node(
      (1, 1),
      [prediscussion],
      [local draft, `XXXXX`],
      c-pre,
    ),
    state-node(
      (2, 1),
      [discussion],
      [open for review],
      c-disc,
    ),
    state-node(
      (3, 0),
      [accepted],
      [direction agreed #linebreak() not yet implemented],
      c-acc,
    ),
    state-node(
      (3, 1),
      [published],
      [current design record],
      c-pub,
    ),
    state-node(
      (4, 1),
      [committed],
      [implemented, descriptive],
      c-com,
    ),
    state-node(
      (2, 2),
      [abandoned],
      [closed without adoption],
      c-aband,
    ),
    edge((0, 1), (1, 1), "-|>"),
    edge((1, 1), (1, 1), edge-label[iterate], "-|>", bend: 130deg),
    edge((1, 1), (2, 1), edge-label[assign `NNNN`], "-|>"),
    edge((2, 1), (3, 0), edge-label[direction agreed], "-|>", bend: 18deg),
    edge((2, 1), (3, 1), edge-label[adopted], "-|>"),
    edge((3, 0), (3, 1), edge-label[recorded], "-|>"),
    edge((3, 0), (4, 1), edge-label[implemented], "-|>", bend: 18deg),
    edge((3, 1), (4, 1), "-|>"),
    edge((1, 1), (2, 2), edge-label[dropped], "--|>", bend: -14deg),
    edge((2, 1), (2, 2), edge-label[rejected], "--|>"),
    edge((3, 1), (2, 2), edge-label[superseded], "--|>", bend: 14deg),
  ),
)

== Transition Detail

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 6pt,
  table.header([*Transition*], [*Actor*], [*What happens*]),
  [start → `prediscussion`],
  [contributor],
  [Copy `template/rfc-template.typ` to `records/XXXXX-<slug>.typ` and iterate
    locally under the placeholder number.],

  [`prediscussion` → `discussion`],
  [maintainer],
  [Run `zig build zds-promote -- <slug>`: it assigns the next four-digit
    number, renames the file to `NNNN-<slug>.typ`, rewrites the metadata for
    discussion, and appends the `registry.typ` and `bundle.typ` entries.],

  [`discussion` → `accepted`],
  [maintainers],
  [Review converges on the proposed direction; implementation has not landed
    yet. The registry state changes, nothing is renamed.],

  [`discussion` → `published`],
  [maintainers],
  [The document itself is the deliverable (process memos, assessments,
    records) and is adopted as the current design record.],

  [`accepted` → `published`],
  [maintainers],
  [The accepted direction is written up as the repository's current design
    record while implementation continues.],

  [`accepted` / `published` → `committed`],
  [maintainers],
  [The described system is fully implemented; the ZDS is now descriptive of
    the current system rather than a proposal.],

  [any pre-committed state → `abandoned`],
  [maintainers],
  [The discussion is deliberately closed without adoption: dropped while
    drafting, rejected in review, or superseded by a later ZDS. The number is
    never reused.],
)

= Authoring Rules

ZDS documents SHOULD follow the RFC-style template in
`docs/zds/template/rfc-template.typ`. Documents adopted from existing project
records (for example the Zaxonlite product, security, and format documents)
keep their original section structure; new discussions start from the
template.

Each ZDS is expected to include, at minimum:

- an abstract or decision summary
- a clear statement of scope and goals
- the main design or proposal
- considerations for security, operations, or workflow where relevant
- alternatives and unresolved questions

- Keep one ZDS per file under `docs/zds/records`.
- Store document metadata in the `#let zds-*` assignments at the top of the
  file.
- Update `docs/zds/registry.typ` whenever a ZDS is added, renumbered, renamed,
  or changes lifecycle state.
- Build through `zig build` once Zig is installed; Typst remains the document
  compiler.

The ZDS Typst layer is allowed to use external Typst packages for diagrams,
charts, richer tables, or specialized layout when those packages improve the
clarity of the PDF output. The repository should prefer existing Typst
packages over building a custom extension framework here.

= Typst Project Layout

The ZDS tree is a first-class Typst project:

- `docs/zds/records/` contains standalone ZDS source files.
- `docs/zds/template/rfc-template.typ` is the starting point for new ZDS
  drafts.
- `docs/zds/registry.typ` is the metadata registry used by the index and
  bundle.
- `docs/zds/index.typ` renders the PDF/HTML index from the registry.
- `docs/zds/bundle.typ` uses Typst bundle export to emit `index.html`, one
  HTML page per ZDS, and one PDF per ZDS.
- `docs/shared/zds.typ` and `docs/shared/theme.typ` provide the shared
  document frame, styling, and index components.

Typst bundle export and HTML export are experimental in Typst 0.15. They are
useful for the ZDS website, but the repository should still keep standalone
PDF compilation for each ZDS as the stable archival path.

= Build Integration

The root `build.zig` owns the ZDS build steps. Records are discovered by
scanning `docs/zds/records`, so adding a record never requires a build-file
edit:

- `zig build zds` compiles every numbered record to
  `docs/build/zds-NNNN-<slug>.pdf`.
- `zig build zds -Dzds=<number-or-slug>` compiles a single record; the number
  may be unpadded (`-Dzds=2`), and a placeholder draft can be selected by its
  slug for proofreading before promotion.
- `zig build zds-index` compiles the registry-driven index to
  `docs/build/zds-index.pdf`.
- `zig build zds-site` compiles the experimental HTML bundle to
  `docs/build/zds-site/`.

Lifecycle management is owned by `tools/zds.zig`:

- `zig build zds-list` prints registry entries and placeholder drafts, and
  warns when a record file and the registry disagree.
- `zig build zds-new -- <slug>` creates `records/XXXXX-<slug>.typ` from the
  template with today's date.
- `zig build zds-promote -- <slug>` performs the `prediscussion` →
  `discussion` transition described above.

Direct Typst commands are useful while editing:

```sh
typst compile --root docs docs/zds/records/0001-zds-process.typ \
  docs/build/zds-0001-zds-process.pdf
typst compile --features html,bundle --root docs --format bundle \
  docs/zds/bundle.typ docs/build/zds-site
```

= Number Assignment and CI

The repository supports a local numbering workflow for maintainers who manage
discussions directly in git history. The `tools/zds.zig` command, wired into
the build as `zds-list`, `zds-new`, and `zds-promote`, automates it:

- list current ZDS entries and placeholder drafts
- assign the next permanent four-digit ZDS number to a placeholder draft
- rename the file from `XXXXX-<slug>.typ` to `NNNN-<slug>.typ`
- rewrite the `zds-number` metadata and transition the document into
  discussion
- append the metadata entry to `docs/zds/registry.typ` and the export blocks
  to `docs/zds/bundle.typ`

The tool performs ordinary file edits reviewed in the same change as the
discussion — there is no hidden state, and every step can still be done by
hand. The generated registry summary and area come from the draft's
`zds-discussion` and first `zds-labels` entry; review both before
committing.

That local flow is sufficient for small teams and direct-maintainer
repositories. A future CI workflow can still:

- detect placeholder ZDS files that are ready for discussion
- reserve the next permanent ZDS number
- rename the file from `XXXXX-<slug>.typ` to `NNNN-<slug>.typ`
- rewrite the `zds-number` metadata

Both flows preserve a stable numbered sequence in shared history. Teams can
choose local CLI assignment, CI assignment, or a combination where CI
validates numbering but maintainers assign numbers intentionally.

== Numbering State Diagram

#zds-figure(
  diagram(
    spacing: (16mm, 9mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    state-node(
      (0, 0),
      [Placeholder],
      [number = `XXXXX` #linebreak() file = `XXXXX-slug.typ`],
      c-pre,
    ),
    state-node(
      (1, 0),
      [Discussion],
      [number = `NNNN` #linebreak() file = `NNNN-slug.typ`],
      c-disc,
    ),
    state-node(
      (2, 0),
      [Published / Committed],
      [same number #linebreak() later state changes],
      c-pub,
    ),
    edge((0, 0), (1, 0), edge-label[number assigned], "-|>"),
    edge((1, 0), (2, 0), edge-label[state changes only], "-|>"),
  ),
)

= Security Considerations

An ambiguous discussion process creates implementation drift and undocumented
design assumptions. For a consensus system this is not cosmetic: safety
arguments, format freezes, and trust-boundary decisions must stay traceable to
an explicit record. Requiring explicit sections for scope, considerations, and
alternatives reduces the chance that important constraints remain hidden in
pull request discussion alone.

= References

- `IETF RFCs` for explicit memo structure, status, and considerations
- `Oxide RFDs` for engineering discussion records in a source repository
- `Typst bundle export` for the multi-file ZDS website and per-ZDS PDFs
- Kynetica Discussions (KDS), the sibling process this layout mirrors
