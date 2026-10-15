# DeckMonkey

A Swift library that reads and writes native Keynote `.key` files — no Keynote, AppleScript, or
PPTX bridge in the loop.

A `.key` is a zip (or package directory) of Snappy-chunked Protocol Buffer object graphs. DeckMonkey
reads them with a schema recovered from the Keynote binary, writes them by graph surgery on a
Keynote-authored template, and treats Keynote itself as the acceptance oracle: output is correct
only when Keynote opens it with no repair sheet and exports the expected PDF.

Status: **Phase 0 (foundation)**. Lossless open → inspect → validate → save round-trip through a
schema-free raw store. See `docs/spec.md` for the full plan and `CLAUDE.md` for conventions.

## Quick start

```sh
swift build
swift test
swift run deckmonkey inspect  ~/Decks/example.key
swift run deckmonkey dump     ~/Decks/example.key Index/Document.iwa
swift run deckmonkey roundtrip ~/Decks/example.key
```

Point the corpus suite at decks that stay outside the repo:

```sh
export DECKMONKEY_CORPUS=/path/to/private/decks
make snappy-reference  # once per corpus change: the reference Snappy decoder (cramjam) hashes every chunk
make gate              # swift test + roundtrip CLEAN on every deck + AT-01 against those hashes
make oracle-corpus     # macOS + Keynote: opens every round-trip output and diffs the PDF export
```

## Layout

| Module | Owns |
| --- | --- |
| `IWASnappy` | pure-Swift Snappy codec and Apple's `.iwa` chunk framing |
| `IWAContainer` | zip / package I/O, `Metadata/`, `Data/` (zip layer from [Rostrum](https://github.com/welshofer/rostrum)) |
| `IWAArchive` | `TSP.ArchiveInfo` / `MessageInfo` via a schema-free wire reader, archive split/join, object store |
| `IWASchema` | generated SwiftProtobuf sources and type registry per pinned Keynote version |
| `KeynoteGraph` | `KeynoteDocument`, identifier allocator, validator; the typed graph and surgery ops come next |
| `DeckMonkey` | public API; Deck IR bridge to Rostrum's `DeckOutline` in Phase 4 |
| `DeckMonkeyCLI` | the `deckmonkey` executable — the acceptance surface |

Pinned Keynote build: 15.4 (7051.0.79). License: MIT.
