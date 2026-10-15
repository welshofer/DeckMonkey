# Corpus (docs/spec.md §11)

| Directory | Contents | Source |
| --- | --- | --- |
| `templates/` | one deck per built-in theme, standard and wide, every master instantiated once | `Scripts/corpus-gen` (AppleScript), later |
| `features/` | hand-authored, one feature each | authored in Keynote 15.4 |
| `versions/` | the same feature deck saved by each Keynote version on hand | authored |
| `hostile/` | deliberately broken copies, one per validator rule | `deckmonkey` + a hex editor |
| `wild/` | **git-ignored.** Real decks never enter the repo. | `DECKMONKEY_CORPUS` points at them |

Every committed deck ships with `<name>.golden.pdf`, the PDF Keynote exported at ingest. Decks and
PDFs are stored through git LFS (see `.gitattributes`).

Private decks: `export DECKMONKEY_CORPUS=/path/to/decks`, or write that path into the git-ignored
`.deckmonkey-corpus` file at the repo root — `swift test` (CorpusTests) and `make roundtrip-corpus` /
`make oracle-corpus` pick them up recursively.
