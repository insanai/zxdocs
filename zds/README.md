# Zaxon Discussions

Zaxon Discussions (ZDS) are the RFC/RFD-style design records for the paxos-zig
monorepo: the Multi-Paxos library and the Zaxonlite embedded replicated SQLite
package. Each ZDS is a standalone Typst file under `docs/zds/records`, while
`docs/zds/registry.typ` drives the index and bundle output.

## Layout

- `records/`: one Typst source file per ZDS.
- `template/rfc-template.typ`: starting point for new ZDS drafts.
- `registry.typ`: metadata used by the index and bundle.
- `index.typ`: registry-driven discussion index.
- `bundle.typ`: experimental Typst bundle entry point that emits `index.html`,
  per-ZDS HTML pages, and per-ZDS PDFs.
- `../shared/zds.typ` and `../shared/theme.typ`: shared document frame,
  styling, and index components.

The monorepo uses matching package boundaries:

- `src/`: the reusable `paxos` Zig library (`paxos.ReplicatedLog`).
- `zaxonlite/`: the embedded replicated SQLite package and the `zaxon` CLI
  (its own Zig package pinning the SQLite amalgamation).
- `sim/`, `specs/`: the deterministic simulation harness and TLA+ specs.
- `docs/book.typ` and `docs/zaxonlite/book.typ`: the two descriptive manuals.

The books describe the current system; a ZDS records the decision that made it
that way. `build.zig` discovers records by scanning `records/`, so only
`registry.typ` and `bundle.typ` carry per-record metadata; the
`zig build zds-promote` step maintains both.

## Build

The root `build.zig` owns the ZDS build steps:

```sh
zig build zds                  # per-record PDFs into docs/build/
zig build zds -Dzds=0002       # a single record, by number ...
zig build zds -Dzds=2          # ... unpadded also works
zig build zds -Dzds=zaxonlite-format  # ... or by slug
zig build zds-index            # registry-driven index PDF
zig build zds-site             # experimental HTML bundle into docs/build/zds-site/
```

`-Dzds=` also selects placeholder drafts by slug, so a draft can be proofread
as a PDF before promotion.

## Manage

`tools/zds.zig` drives the numbering workflow from ZDS 0001:

```sh
zig build zds-list                 # registry entries, drafts, consistency warnings
zig build zds-new -- <slug>        # create records/XXXXX-<slug>.typ from the template
zig build zds-promote -- <slug>    # assign the next number, rewrite metadata,
                                   # and append registry.typ and bundle.typ entries
```

Promotion renames `XXXXX-<slug>.typ` to the next `NNNN-<slug>.typ`, sets the
state to `discussion`, and stamps today's date. Review the generated registry
summary and area fields before committing.

Direct Typst commands are useful while editing:

```sh
typst compile --root docs docs/zds/records/0001-zds-process.typ docs/build/zds-0001-zds-process.pdf
typst compile --root docs docs/zds/records/0002-zaxonlite-product-plan.typ docs/build/zds-0002-zaxonlite-product-plan.pdf
typst compile --root docs docs/zds/records/0003-zaxonlite-security-remediation-plan.typ docs/build/zds-0003-zaxonlite-security-remediation-plan.pdf
typst compile --root docs docs/zds/records/0004-zaxonlite-format.typ docs/build/zds-0004-zaxonlite-format.pdf
typst compile --root docs docs/zds/index.typ docs/build/zds-index.pdf
typst compile --features html,bundle --root docs --format bundle docs/zds/bundle.typ docs/build/zds-site
```

Typst 0.15 marks HTML and bundle export as experimental. PDF output is the
stable archival target; the bundle website is the current path for browseable
ZDS pages and the generated index.

## Adding a ZDS

1. Run `zig build zds-new -- <slug>` (or copy `template/rfc-template.typ` to
   `records/XXXXX-<slug>.typ` by hand).
2. Fill in the `#let zds-*` metadata.
3. Write the discussion using the standard sections; preview with
   `zig build zds -Dzds=<slug>`.
4. When ready for discussion, run `zig build zds-promote -- <slug>` to assign
   the next four-digit number and append the `registry.typ` and `bundle.typ`
   entries.
5. Review the generated registry summary and area fields, then run
   `zig build zds` to build everything.
