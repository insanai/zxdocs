# Summary

<!-- What does this change document or decide, and why? -->

## Checklist

- [ ] Both books still compile
      (`typst compile --root . docs/book.typ ...` and
      `typst compile --root . docs/zaxonlite/book.typ ...`).
- [ ] The two books stay structurally parallel: a chapter added or
      reshaped in one has its counterpart in the other, or the summary
      explains why not.
- [ ] ZDS changes follow record 0001: numbers are never reused, lifecycle
      state changes update the record's `zds-*` metadata and its
      `registry.typ` entry together, and a superseding design arrives as a
      new record while the old one moves to `abandoned`.
- [ ] Every number in a book table comes from a recorded benchmark result
      file, not from a keyboard.
- [ ] Prose changes that describe code behavior match the code as it is
      today, with the relevant repository and commit noted below.

## Verification

<!-- Paste the compile commands you ran and their results. -->
