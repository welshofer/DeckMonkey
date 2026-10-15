# Corpus (docs/spec.md §11)

| Directory | Contents | Source |
| --- | --- | --- |
| `templates/` | one deck per built-in theme, standard and wide, every master instantiated once | `Scripts/corpus-gen` (AppleScript), later |
| `features/` | hand-authored, one feature each | authored in Keynote 15.4 |
| `versions/` | the same feature deck saved by each Keynote version on hand | authored |
| `hostile/` | deliberately broken copies, one per validator rule, with `manifest.json` naming the error and stage each must raise (AT-26) | `Scripts/make-hostile-corpus.py` |
| `wild/` | **git-ignored.** Real decks never enter the repo. | `DECKMONKEY_CORPUS` points at them |

Every committed deck ships with `<name>.golden.pdf`, the PDF Keynote exported at ingest. Decks and
PDFs are stored through git LFS (see `.gitattributes`) — except `hostile/`, whose files are a few
kilobytes of synthetic bytes, have no golden PDF by definition, and are committed as plain blobs.

`hostile/` is generated (`make hostile-regen`) from the synthetic deck in
`Tests/DeckMonkeyTests/Fixtures`, so no Keynote bytes are involved; once `templates/` exists the
same generator can be pointed at a Keynote-authored deck. Each file is refused at the stage the
manifest names (`open`, `validate` or `save`) and nothing is written; `swift test`
(`HostileCorpusTests`) checks the typed error per file and `make hostile` checks the CLI. Cases the
raw store cannot judge yet (unknown type ID with a populated registry, text offsets past the
storage length, `Data/` files without a `DataInfo`) are added as the typed layer lands.

Private decks: `export DECKMONKEY_CORPUS=/path/to/decks`, or write that path into the git-ignored
`.deckmonkey-corpus` file at the repo root — `swift test` (CorpusTests) and `make roundtrip-corpus` /
`make oracle-corpus` pick them up recursively.
