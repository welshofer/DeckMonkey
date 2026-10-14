# DeckMonkey — project conventions

DeckMonkey is a Swift library that reads and writes native Keynote `.key` files. No PPTX bridge,
no AppleScript as a write path, no synthesis from empty: reading is a schema recovered from the
Keynote binary; writing is graph surgery on a Keynote-authored template; Keynote itself is the
acceptance oracle. The full spec is `docs/spec.md`; sections 5 (invariants), 9 (writer), 12
(phases and gates) and 14 (acceptance tests) are the contract. This file is the session brief.

## Pinned facts

- **Keynote 15.4 (7051.0.79)** is the pinned build (OQ-2). Schema and registry directories are
  named `15.4`. `BuildVersionHistory.plist` entries look like `M15.4-7051-1`.
- **Rostrum** (`github.com/welshofer/rostrum`, MIT, v1.0.0+) supplies the zip layer and, from
  Phase 4, the Deck IR (`DeckOutline`). SwiftProtobuf is the only other dependency.
- **License:** MIT. WorkKit (AGPL-3.0) and keynote-parser are design references only — read them,
  never copy code or protos from them. Our protos come from our own extraction (Scripts/schema).
- **Private corpus:** Jay's test decks never enter the repo. Point `DECKMONKEY_CORPUS` at a
  directory outside the tree; the test suite and `make roundtrip-corpus` scan it recursively.
  `Corpus/` in-repo holds only synthetic decks (templates, features, hostile) generated later.

## Invariants (docs/spec.md §5) — a change that breaks one is a design change, not a bug fix

1. Bytes are truth: the decompressed archive payload is the model; typed decode is a cached view.
2. Preserve what you don't understand: untouched records re-emit from original bytes; mutated
   messages round-trip unknown fields.
3. Identifiers are global and monotonic: one `IDAllocator` per document, seeded above
   `last_object_identifier` and the store's high-water mark, written back on save.
4. Reference lists are derived, never typed: `object_references`, `data_references`,
   `PackageMetadata.components` and `.datas` are recomputed from serialized payloads before save.
5. Versions are inherited from the template; the library never bumps one.
6. Styles by reference; no style-creating API through Phase 4.
7. Keynote is the oracle: correct means no sheet on open and the expected PDF.
8. Fail loud: the validator raises a typed error before any byte is written.

## Layout and layer boundaries (dependencies point strictly downward)

| Module | Owns |
| --- | --- |
| `IWASnappy` | pure-Swift Snappy + Apple's `0x00` + 3-byte-LE chunk framing, varints |
| `IWAContainer` | zip / package directory I/O, `Metadata/` plists (read-only), `Data/` |
| `IWAArchive` | `TSP.ArchiveInfo` / `MessageInfo` via a schema-free wire reader, archive split/join, `ObjectStore` |
| `IWASchema` | generated SwiftProtobuf sources + type registry per pinned Keynote version — never hand-edited |
| `KeynoteGraph` | `KeynoteDocument`, `IDAllocator`, `Validator`; later the typed graph and surgery ops |
| `DeckMonkey` | public API, `roundTrip`, Deck IR bridge (Phase 4) |
| `deckmonkey` | CLI: the acceptance surface; every gate is a subcommand with an exit code |

Design decision to keep: `IWAArchive` decodes `ArchiveInfo` with its own wire-format reader, not
generated code, so a file from any Keynote version round-trips through the raw store with no
schema at all. Generated protos arrive in `IWASchema` and are used only for payloads.

## Toolchain and house rules

- Swift 6.2, SwiftPM only, strict concurrency complete, zero warnings. Value types, `Sendable`
  everywhere, typed errors — never `fatalError` on bad input.
- Portable core: `IWASnappy`, `IWAArchive`, `IWAContainer`, `IWASchema`, `KeynoteGraph`,
  `DeckMonkey` build and test on Linux (CI runs them in a `swift:6.1` container). Anything that
  needs CoreGraphics or Keynote lives in `Scripts/`.
- Tests are swift-testing (`import Testing`, `@Test`, `#expect`), one suite per module, plus
  `CorpusTests` which is skipped when no corpus is configured.
- **Merge gate:** `make gate` — `swift test` green AND `deckmonkey roundtrip` CLEAN on every
  corpus deck. Gate 0 additionally needs `make oracle-corpus` at 40/40 with 0 mismatched pixels.
- Oracle (`Scripts/oracle.sh`, `Scripts/pdfdiff.swift`): macOS only, works on a copy, only opens /
  exports / closes. First cut was written without a Keynote in reach; expect to adjust AppleScript
  element names on first run, but keep the JSON verdict shape.
- Determinism: same input → same output bytes (Rostrum's zip writer fixes timestamps; entries
  are written sorted).
- Commit messages: imperative subject, what and why, one logical change each.

## Phase 0 task list (Gate 0 = AT-01…AT-13, AT-25, AT-26; docs/spec.md §12, §14)

Done in the scaffold: Snappy codec + framing with AT-02 fuzz; wire reader; `ArchiveInfo` /
`MessageInfo` with unknown-field preservation; archive split/join; `ObjectStore` two-pass
load; container (zip, directory, nested `Index.zip`); `KeynoteDocument` open / validate / save;
`deckmonkey inspect | dump | roundtrip | verify`; oracle scripts (unverified); CI.

Remaining, in order:

1. `swift build && swift test` on the M4, then `deckmonkey inspect` and `roundtrip` on the first
   real deck (`DECKMONKEY_CORPUS`). Expect surprises in field numbers (§4 table) and chunk
   framing; fix with the real bytes in hand and add a regression test for each.
2. AT-01: a reference Snappy decoder comparison (python-snappy in a venv is fine as the oracle).
3. Schema pipeline per `Scripts/schema/README.md`: protodump, render, `protoc`, registry dump,
   dispatch generator. Commit `Generated/15.4` and `registry-15.4.json`. AT-05.
4. AT-06, AT-07, AT-08 on the corpus (derive references with a SwiftProtobuf `Visitor` over the
   decoded payloads and compare with the stored lists). Promote dangling references to `.error`
   in `Validator` once AT-06 is green.
5. `Scripts/corpus-gen` (AppleScript): one deck per built-in theme × two sizes → `Corpus/templates`;
   hand-author `Corpus/features`; `deckmonkey corpus add` records version + golden PDF.
6. `Corpus/hostile` files and AT-26; AT-11, AT-12, AT-25.
7. Oracle harness verified end to end on the M4: `make oracle-corpus` 40/40.

Do not start Phase 1 (text replace) on a partial Gate 0.
