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
- **Private corpus:** Jay's test decks never enter the repo. They live in
  `~/Developer/DeckMonkey-corpus` (a sibling of the repo). Point `DECKMONKEY_CORPUS` at it, or
  write the path into the git-ignored `.deckmonkey-corpus` file at the repo root; the test suite
  and `make roundtrip-corpus` scan it recursively.
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
| `DeckMonkeyCLI` | the `deckmonkey` executable (`Sources/DeckMonkeyCLI`): the acceptance surface; every gate is a subcommand with an exit code |

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
- **Merge gate:** `make gate` — `swift test` green, `deckmonkey roundtrip` CLEAN on every
  corpus deck, and AT-01 (`make snappy-check`: our decoder against cached reference hashes, the
  reference decoder against our compressor). Gate 0 additionally needs `make oracle-corpus` at
  40/40 with 0 mismatched pixels.
- **Reference Snappy:** cramjam (Rust `snap`, format-identical to Google's) in a local `.venv`,
  driven only by `Scripts/snappy-crosscheck.py`. It runs once per corpus change
  (`make snappy-reference` → `$CORPUS/.snappy-reference.json`, hashes only, never in the repo);
  the Swift side (`SnappyReference`, `deckmonkey snappy-check`, `DeckMonkeyTests`) works from
  the cached hashes and from the checked-in reference-compressed vectors.
- Oracle (`Scripts/oracle.sh`, `Scripts/pdfdiff.swift`): macOS only, works on a copy, only opens /
  exports / closes. First cut was written without a Keynote in reach; expect to adjust AppleScript
  element names on first run, but keep the JSON verdict shape.
- Determinism: same input → same output bytes (Rostrum's zip writer fixes timestamps; entries
  are written sorted).
- Commit messages: imperative subject, what and why, one logical change each.

## Phase 0 task list (Gate 0 = AT-01…AT-13, AT-25, AT-26; docs/spec.md §12, §14)

Done and verified on the M4 (2026-10-14): Snappy codec + framing with AT-02 fuzz; wire reader;
`ArchiveInfo` / `MessageInfo` with unknown-field preservation; archive split/join; `ObjectStore`
two-pass load; container (zip, package directory, nested `Index.zip`); `KeynoteDocument` open /
validate / save; `deckmonkey inspect | dump | roundtrip | verify`; CI.
First contact: **28/28 modern private decks round-trip CLEAN with zero validation issues** —
saved by Keynote 6.5 through 15.4, by Keynote for iOS and Keynote for iCloud, in both container
forms. The 7 Keynote '09 APXL decks are refused as designed. Facts learned from the bytes:
`MessageInfo` fields 1/2/3/5/6 are as assumed and the reference lists are packed; package
directories carry `Index.zip`, not `Index/`; `should_merge` records with no base are simply
objects (stylesheet components are full of them) and in these decks every merge record is one;
every merge archive carries two `MessageInfo`s, a payload and a diff descriptor with the sentinel
version `65535.65535.4294967295` (spec §4, row 3a);
`BuildVersionHistory` entries look like `M15.4-7051.0.79-2`, `T2.5.1 (1715)` (iOS), `G-r11-2A396`
(iCloud).

AT-01 (2026-10-14): `Tests/DeckMonkeyTests` decodes 33 cramjam-compressed vectors (literal-length
escapes, 1/2-byte copy offsets at 2047/2048/65535, 64 KiB block edges, multi-block) and the
synthetic deck's reference manifest; CI feeds our compression of the vectors back to the reference
decoder (`make snappy-vectors`). The corpus half ran on the M4 the same day: 1302/1302 chunks MATCH, and
the reference decodes all 1002 of our re-compressed components identically. `make gate` is green.
The CLI exits 3 on a refused APXL file; the gates count that as skipped.

Oracle (2026-10-14): `Scripts/oracle.sh` verified against Keynote 15.4 and safe beside the
user's open documents (it touches only its `oracle-<token>-` copy). Keynote lives at
"Keynote Creator Studio.app" on the M4: never hard-code the path, use `Scripts/keynote-app.sh`.
Over the 28 modern private decks: 28/28 originals and 28/28 `deckmonkey roundtrip` outputs open
with no sheet and no persistence log errors, every round-trip PDF at 0 mismatched pixels against
its original's export; a cut `Document.iwa` fails with "… is damaged and can't be opened."
(Goldens were made in a scratch dir; `make oracle-corpus` expects `<deck>.golden.pdf` beside each
deck, which `deckmonkey corpus add` is meant to produce.)

Schema (2026-10-14): `make schema` (deterministic) and `make schema-diff`. 34 descriptors →
`Sources/IWASchema/Generated/15.4` (no protoc: descriptors go straight to protoc-gen-swift);
registry recovered statically from the registration calls (Frida/lldb cannot attach), 625 types
+ 101 declared deprecated, every mapping cross-checked against surviving symbols. AT-05 passes
(85 types with a message, 6219 declared deprecated, 0 unresolved). Unknown types are validator
errors (invariant 8); merge diff descriptors (type 0) and deprecated types are skipped.

References (2026-10-14): `ReferenceDerivation` decodes every payload (54,348, all clean, no unknown
fields) and collects `TSP.Reference` / `TSP.DataReference`. AT-08 holds exactly (minus the null
id 0). Object lists do **not** equal the derived set: Keynote lists strong references only
(stored ⊆ derived always; 179 fields always listed, 17 never, 5 mixed), every listed reference
resolves, and all 807 dangling references in Keynote's own files are unlisted weak ones.
**Open design decision (needs Jay):** AT-07 as written cannot pass and AT-06 holds for strong
references only; decide how mutated records get their `object_references` (invariant 4) before
Phase 1 relies on derived lists.

Remaining, in order:

1. Decide AT-06/AT-07 (above) and amend docs/spec.md §5/§14 accordingly.
2. `Scripts/corpus-gen` (AppleScript): one deck per built-in theme × two sizes → `Corpus/templates`;
   hand-author `Corpus/features`; `deckmonkey corpus add` records version + golden PDF.
3. `Corpus/hostile` files and AT-26; AT-11, AT-12, AT-25.
4. `make oracle-corpus` 40/40 on the synthetic corpus (AT-10).

Do not start Phase 1 (text replace) on a partial Gate 0.
