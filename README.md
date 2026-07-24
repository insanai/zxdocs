# zxdocs

The books and design records for
[paxos-zig](https://github.com/insanai/paxos-zig) and
[zaxonlite](https://github.com/insanai/zaxonlite).

## Why a separate repository for words

There is a saying attributed to Feynman: if you cannot explain something
simply, you do not understand it. We take that as an engineering rule, not
a slogan. Every serious piece of code in this family ships with a book that
explains it from first principles, and every serious design decision is
written down before it is built. This repository holds all of it.

The code lives elsewhere. The understanding lives here.

## What is in here

**Two books, written in Typst.**

- `book.typ` builds *The Part-Time Parliament, from paper to library*, the
  book for [paxos-zig](https://github.com/insanai/paxos-zig). It walks from
  Lamport's paper to single-decree Paxos to Multi-Paxos to the library's
  API contract, host-integration guide, evidence audit, and production
  checklist. Its reviewable-code chapter (`book/04_style.typ`) defines the
  source conventions that the code repositories enforce mechanically.
- `zaxonlite/book.typ` builds the book for
  [zaxonlite](https://github.com/insanai/zaxonlite): quickstart, CLI,
  architecture, WAL replication, storage, clustering, consistency,
  embedding, the C ABI, operations, formats, verification, and conformance.

The two books are deliberately parallel in structure. When one grows a
chapter, the other grows its counterpart. A reader who has learned one
should feel at home in the other.

**Design records (ZDS).** `zds/` holds the Zaxon Discussions: the design
records for paxos-zig and zaxonlite, one Typst file each under
`zds/records/`. The structure follows IETF RFCs and Oxide's RFD process,
because those formats force explicit scope, status, rationale, and
alternatives instead of relying on implicit context. A record starts as a
placeholder draft (`XXXXX-slug.typ`), gets a permanent four-digit number
when a maintainer promotes it (`zig build zds-promote`), and then moves
through the lifecycle: `prediscussion`, `discussion`, `accepted`,
`published`, `committed`, or `abandoned`. A number is never reused.

The process defines itself: it is record 0001. The zaxonlite product plan
and safety argument is 0002, the wire/disk compatibility policy is 0004,
and the interactive shell design is 0005. Kynetica's KDS records are the
sibling process this layout mirrors. If you want to know why something is
the way it is, the answer is in a record, with the alternatives that lost.
The books describe the current system; a ZDS records the decision that
made it that way.

**Source papers.** Lamport's original *The Part-Time Parliament* is kept at
`lamport-paxos.pdf`, because you should be able to check us against it.

## Read the books

The CI workflow compiles every book and record to PDF on each change and
publishes them:

- [The Part-Time Parliament, from paper to library](https://insanai.github.io/zxdocs/part-time-parliament.pdf)
- [The Zaxonlite book](https://insanai.github.io/zxdocs/zaxonlite.pdf)
- [All design records](https://insanai.github.io/zxdocs/)

## Build them yourself

You need [Typst](https://typst.app/) (0.15 or later). The books compile
their benchmark tables from the recorded result files in the code
repositories, so they build against a checkout that has
[paxos-zig](https://github.com/insanai/paxos-zig) at the root,
[zaxonlite](https://github.com/insanai/zaxonlite) in `zaxonlite/`, and this
repository in `docs/`. In the monorepo that layout already exists, and the
build steps are wired into `zig build`:

```sh
zig build book            # docs/part-time-parliament.pdf
zig build book-zaxonlite  # docs/zaxonlite/zaxonlite.pdf
zig build zds             # every design record, to docs/build/
zig build zds -Dzds=0002  # one record
zig build zds-list        # list records and their status
zig build zds-new         # start a new record from the template
```

Or call Typst directly, from the directory that contains `docs/`:

```sh
typst compile --root . docs/book.typ docs/part-time-parliament.pdf
typst compile --root docs docs/zds/records/0001-zds-process.typ out.pdf
```

Numbers in the books come only from recorded benchmark result files
(`latest.json` and friends), never typed in by hand. If a table in the book
disagrees with a result file, the book is wrong and the build should be
fixed, not the number.

## Rules of this repository

- A ZDS number is never reused. A superseded record moves to the
  `abandoned` state; its replacement is a new record with a new number.
- Lifecycle state changes are ordinary reviewed file edits: the `zds-*`
  metadata in the record and its `registry.typ` entry move together.
- The two books stay structurally parallel and complete. A change that
  ships a feature without its chapter is not done.
- PDF is the archival target. The HTML bundle export is experimental.

## Related projects

- [paxos-zig](https://github.com/insanai/paxos-zig): the consensus library.
- [zaxonlite](https://github.com/insanai/zaxonlite): embedded replicated
  SQLite, and the `zaxon` CLI.
- [zaxon-cli-ui](https://github.com/insanai/zaxon-cli-ui): the shared
  terminal UI module.

## License

MIT. Copyright 2026 Vikrant Rathore and Ronak Rathore.
