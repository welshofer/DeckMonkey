# DeckMonkey

A Swift library that reads, writes, draws and plays native Keynote `.key` files — no Keynote,
AppleScript, or PPTX bridge in the loop.

A `.key` is a zip (or package directory) of Snappy-chunked Protocol Buffer object graphs. DeckMonkey
reads them with a schema recovered from the Keynote binary, writes them by graph surgery on a
Keynote-authored template, and treats Keynote itself as the acceptance oracle: output is correct
only when Keynote opens it with no repair sheet and exports the expected PDF. Its renderer draws
slides as SVG, build stage by build stage, with what a host needs to play builds, transitions and
movies (the [Duo](https://github.com/welshofer/duo) presenter uses it).

## Status

Pinned to Keynote 15.4 (7051.0.79). Every gate below is checked against Keynote itself.

| Phase | What works | Gate |
| --- | --- | --- |
| 0 Foundation | lossless open → inspect → validate → save; schema and type registry extracted from Keynote | Gate 0 passed: 146/146 decks round-trip CLEAN, oracle 0 mismatched pixels |
| 1 Text | find and replace text, offset tables remapped, overlapping hyperlinks removed and reported | Gate 1 passed: 25/25 |
| 2 Media | replace images (PNG, JPEG, GIF, TIFF), movies and audio; no orphaned data | macOS 12/12 (the iPad oracle, AT-27, is not built) |
| 3a Slides | move, delete and duplicate slides within a deck | Gate 3a passed: 30/30 |
| 3b Import | copy a slide from another deck, restyled to this deck's theme (styles, masters and presets by reference; refuses on no match), tables and charts included | 14/14 oracle cases |
| 4 Deck IR | `from-ir`: a lectern.deck/1 deck onto a theme: 18 of 20 layouts, charts and tables included | 37/44 at 0 px vs Keynote's own build; 7 await hand-built references |
| R Rendering | every slide as SVG (text layout, tables, charts, pictures, movies' posters; Display P3 colour; our own stand-ins for theme artwork Keynote does not store) | AT-29 passed: 796 judged template pages at a 0.43% median against Keynote's PDF; 220 private pages at 1.64% |
| 5 Builds | a slide's build order as stages (both chunk encodings, back to Keynote 6.5), each stage drawn, actions applied; each step as a backdrop plus a layer per animated build, with effect, direction, timing and motion path | AT-30 passed: 15 private decks, every stage count equal to Keynote's (153 pages), 120 judged at a 1.02% median |
| 5 Transitions | each slide's transition; Magic Move pairs (same picture, text or shape) and their layers | read from 25 Magic Moves in the private corpus; motion not frame-compared (Keynote exports stills only) |
| Scenes | a deck as plain JSON (outlines, fills, strokes, text, exact colours) exported and built back with style variations; a parametric display test pattern | a 2,888-object 4K deck rebuilt at 0 mismatched pixels; 4K/1080p/720p/4:3 patterns open clean |

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
swift run deckmonkey slide     import deck.key --from other.key --index 1 -o out.key
swift run deckmonkey slide     keep deck.key --index 4 -o out.key     # that slide alone
swift run deckmonkey slide     new  deck.key --master "Title & Bullets" -o out.key
swift run deckmonkey object    deck.key --slide 0              # drawables; also move, resize, delete
swift run deckmonkey from-ir   deck.json --template theme.key -o out.key
swift run deckmonkey render    deck.key -o svg/ [--stages]     # each slide (or build stage) as SVG
swift run deckmonkey scene     export deck.key -o scene.json
swift run deckmonkey scene     build scene.json --template theme.key -o out.key
swift run deckmonkey test-pattern --size 1920x1080 --template theme.key -o pattern.key
swift run deckmonkey roundtrip deck.key                      # open, save, compare
swift run deckmonkey verify    deck.key                      # the validator
```

Exit codes: 0 pass, 1 fail, 2 usage, 3 refused by design (a Keynote '09 file). Edits refuse what
they cannot do faithfully (a paragraph break inside a replacement, a Keynote-edited image, a slide
with builds to clone) instead of guessing; every save runs the validator first and writes nothing
if it fails.

## As a library

```swift
import DeckMonkey

var deck = try KeynoteDocument.open(URL(fileURLWithPath: "deck.key"))
try deck.replaceAll("Q3", with: "Q4")
try deck.replaceImage(deck.images[0], with: Data(contentsOf: photo), preferredFileName: "photo.jpg")
try deck.cloneSlide(at: 2)
try deck.save(to: URL(fileURLWithPath: "out.key"))

// Drawing and playing
let renderer = KeynoteRenderer(document: deck)
let slide = deck.slideOrder()[0].slide
let svg = renderer.render(slide: slide).svg
let builds = renderer.builds(onSlide: slide)            // stages, chunks, effects, timing
let step = renderer.renderStep(slide: slide, to: 1, of: builds)   // backdrop + a layer per build
let transition = renderer.transition(onSlide: slide)    // and magicMovePairs(from:to:)
let movies = renderer.movies(onSlide: slide)            // frames, files, trims, loops, autoplay
```

## Testing

```sh
swift test                          # unit tests; corpus tests run when a corpus is configured
make gate                           # swift test + round-trip every corpus deck + the Snappy cross-check
make corpus                         # macOS + Keynote: generate the template and feature decks locally
make gates                          # macOS + Keynote: Gates 1, 2 and 3 through the oracle (leave the machine alone)
python3 -I Scripts/render/gate.py   # AT-29: our SVG against each deck's <deck>.golden.pdf
python3 -I Scripts/render/stages.py # AT-30: build stages against <deck>.stages.pdf (Scripts/oracle.sh deck.key --stages)
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
| `KeynoteGraph` | `KeynoteDocument`, validator, reference derivation, text/image/media/slide surgery, style variations, scenes |
| `KeynoteRender` | read-only, portable SVG renderer; builds, transitions, Magic Move and movies for hosts |
| `DeckMonkey` | public API; Deck IR bridge to Rostrum's `DeckOutline`; scene builder and test pattern |
| `DeckMonkeyCLI` | the `deckmonkey` executable — the acceptance surface |

`docs/spec.md` is the full design; `CLAUDE.md` the working conventions and current state. License: MIT.
