# DeckMonkey

A Swift library that reads and writes native Keynote `.key` files — no Keynote, AppleScript, or
PPTX bridge in the loop.

A `.key` is a zip (or package directory) of Snappy-chunked Protocol Buffer object graphs. DeckMonkey
reads them with a schema recovered from the Keynote binary, writes them by graph surgery on a
Keynote-authored template, and treats Keynote itself as the acceptance oracle: output is correct
only when Keynote opens it with no repair sheet and exports the expected PDF.

## Status

Pinned to Keynote 15.4 (7051.0.79). Every gate below is checked against Keynote itself.

| Phase | What works | Gate |
| --- | --- | --- |
| 0 Foundation | lossless open → inspect → validate → save; schema and type registry extracted from Keynote | Gate 0 passed: 146/146 decks round-trip CLEAN, oracle 0 mismatched pixels |
| 1 Text | find and replace text, offset tables remapped, overlapping hyperlinks removed and reported | Gate 1 passed: 25/25 |
| 2 Media | replace images (PNG, JPEG, GIF, TIFF), movies and audio; no orphaned data | macOS 12/12 (the iPad oracle, AT-27, is not built) |
| 3a Slides | move, delete and duplicate slides within a deck | 25/26; see `CLAUDE.md` |
| 3b, 4, 5 | cross-deck clone, new drawables and Deck IR, builds and transitions | not started |

## Command line

```sh
swift run deckmonkey inspect   deck.key                      # components, versions, types, pages
swift run deckmonkey text      deck.key [--tables]           # every text storage
swift run deckmonkey replace   deck.key --find Q3 --replace Q4 -o out.key
swift run deckmonkey image     deck.key --list
swift run deckmonkey image     deck.key --object 2652582 --with photo.jpg -o out.key
swift run deckmonkey media     deck.key --object 2652596 --with clip.mov --poster frame.png -o out.key
swift run deckmonkey slide     list deck.key
swift run deckmonkey slide     clone deck.key --index 2 -o out.key
swift run deckmonkey slide     move  deck.key --index 0 --to 5 -o out.key
swift run deckmonkey slide     delete deck.key --index 3 -o out.key
swift run deckmonkey roundtrip deck.key                      # open, save, compare
swift run deckmonkey verify    deck.key                      # the validator
```

Exit codes: 0 pass, 1 fail, 2 usage, 3 refused by design (a Keynote '09 file). Edits refuse what
they cannot do faithfully (a paragraph break inside a replacement, a Keynote-edited image, a slide
with a table to clone) instead of guessing; every save runs the validator first and writes nothing
if it fails.

## As a library

```swift
import DeckMonkey

var deck = try KeynoteDocument.open(URL(fileURLWithPath: "deck.key"))
try deck.replaceAll("Q3", with: "Q4")
try deck.replaceImage(deck.images[0], with: Data(contentsOf: photo), preferredFileName: "photo.jpg")
try deck.cloneSlide(at: 2)
try deck.save(to: URL(fileURLWithPath: "out.key"))
```

## Testing

```sh
swift test                          # unit tests; corpus tests run when a corpus is configured
make gate                           # swift test + round-trip every corpus deck + the Snappy cross-check
make corpus                         # macOS + Keynote: generate the template and feature decks locally
make gates                          # macOS + Keynote: Gates 1, 2 and 3 through the oracle (leave the machine alone)
```

Private decks stay outside the repository: `export DECKMONKEY_CORPUS=/path/to/decks`, or write
that path into a git-ignored `.deckmonkey-corpus` file. No deck is committed; the generated corpus
is rebuilt with `make corpus`.

## Layout

| Module | Owns |
| --- | --- |
| `IWASnappy` | pure-Swift Snappy codec and Apple's `.iwa` chunk framing |
| `IWAContainer` | zip / package I/O, `Metadata/`, `Data/` (zip layer from [Rostrum](https://github.com/welshofer/rostrum)) |
| `IWAArchive` | `TSP.ArchiveInfo` / `MessageInfo` via a schema-free wire reader, archive split/join, object store |
| `IWASchema` | generated SwiftProtobuf sources, type registry, reference-strength table, descriptors (Keynote 15.4) |
| `KeynoteGraph` | `KeynoteDocument`, validator, reference derivation, text/image/media/slide surgery |
| `DeckMonkey` | public API; Deck IR bridge to Rostrum's `DeckOutline` in Phase 4 |
| `DeckMonkeyCLI` | the `deckmonkey` executable — the acceptance surface |

`docs/spec.md` is the full design; `CLAUDE.md` the working conventions and current state. License: MIT.
