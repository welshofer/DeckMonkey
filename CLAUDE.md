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
  `Corpus/` holds only synthetic decks (templates, features, hostile), built locally by
  `make corpus` and git-ignored: **no deck goes to GitHub** (Jay, 2026-10-14).

## Invariants (docs/spec.md §5) — a change that breaks one is a design change, not a bug fix

1. Bytes are truth: the decompressed archive payload is the model; typed decode is a cached view.
2. Preserve what you don't understand: untouched records re-emit from original bytes; mutated
   messages round-trip unknown fields.
3. Identifiers are global and monotonic: one `IDAllocator` per document, seeded above
   `last_object_identifier` and the store's high-water mark, written back on save.
4. Reference lists are derived, never typed: `object_references`, `data_references`,
   `PackageMetadata.components` and `.datas` are recomputed from serialized payloads before save.
   `object_references` = strong references only, per `reference-strength-<version>.json`
   (`make reference-strength`); mixed fields keep stored membership; unknown fields are refused.
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

References (2026-10-14): `ReferenceDerivation` decodes every payload and collects `TSP.Reference` /
`TSP.DataReference` with their fields. Keynote lists strong references only, and strength depends
on which Keynote archived the record, so `make reference-strength` learns 15.4's rule from
`Corpus/templates` alone (126 fields: 117 strong, 9 weak, 0 mixed). Invariant 4: strong fields are
listed; an edit never drops a listed reference still present; an unknown field holding a new
reference is refused. AT-07 reproduces all 127,028 lists in the 106 templates exactly; in the 28
older decks 24 lists differ and are preserved. AT-08 (minus null id 0) and AT-06 pass.

Also done 2026-10-14: AT-11, AT-12 (on every deck), AT-25 (file format > 26.4.0 is read-only;
`write_version` is not a writer stamp), AT-13 (Linux `swift:6.1-noble`, 55 tests), the text
offset rule (strictly increasing, ≤ UTF-16 length; 0 violations in 30,044 storages), AT-26 over
`Corpus/hostile` (`deckmonkey corpus hostile`), `Scripts/corpus-gen` (106 template decks from the
53 built-in themes; user themes, id `CloudKit/…`, are never used) and `deckmonkey corpus add`.

**Gate 0 passed (2026-10-14)** over 134 decks (106 local templates + 28 private; 7 APXL refused):
AT-01 (5,803 chunks match the reference decoder, both directions), AT-02–AT-04, AT-05, AT-06–AT-08,
AT-09 roundtrip 134/134 CLEAN, AT-10 oracle 134/134 (the 106 templates at 0 mismatched pixels
against their goldens; private decks have no goldens and are open-checked), AT-11, AT-12, AT-13
(Linux), AT-25, AT-26. Don't use Keynote while the oracle runs: it refuses an edited copy.

Feature corpus (2026-10-14): `Scripts/corpus-gen/features.sh` has Keynote author 12 feature decks
(multi-run, Unicode/astral/combining, bidi and list text; tables with formulas, formats, merges;
all 17 chart types; shapes, lines, images, movie, audio; notes and skipped slides; 43 transitions;
80 slides). AppleScript cannot make hyperlinks, smart fields, equations, groups or builds: those
still need hand-authored decks (Jay), and Phase 1's AT-17 needs smart fields and hyperlinks.
Objects are created with `tell s to make new …`. The strength table now covers 210 fields (169 of
the 201 in the older decks, 99% of their reference occurrences).

Phase 1 (2026-10-15): text replace (`deckmonkey replace`, KeynoteDocument.replaceAll) with the
offset-table remap of spec §9; **Gate 1 passed 25/25** (`make gate1`: 22 cases on the generated
corpus, 3 AT-17 hyperlink cases from private decks in the git-ignored cases.local.tsv).

Phase 2 (2026-10-15): image replace (`deckmonkey image`) and movie/audio replace (`deckmonkey
media`, a caller-supplied poster for video), SHA-1 DataInfo, orphan removal, the per-component data
index rebuilt at save. **Gate 2 on macOS: 12/12** (`Scripts/gate1/gate2.py`: four image formats,
a rotated reflected image, theme photos, a movie, an audio clip). AT-27 (iPad oracle) needs an iOS
runner that does not exist yet. Open: Keynote-edited images (kept originals, adjustments) are
refused.

External references (2026-10-15): `PackageMetadata.components[].external_references` is re-derived
at save for every changed component (`ExternalReferences.swift`): one entry per referenced object in
another component, a component's root object stored with no object identifier (never an explicit 0), `is_weak` only when every reference is
weak. A full refresh reproduces Keynote's metadata byte for byte in all 118 decks 15.4 alone saved
(8 stale Keynote entries preserved, as invariant 2 asks).

Phase 3a (2026-10-15): `deckmonkey slide list | move | delete | clone`. Delete removes the slide's
component and collects what only it kept alive (table and chart internals, their calculation-engine
dependency records); clone copies the component with fresh identifiers and UUIDs through the
schema-driven ReferenceRewriter (complete on 686,910 corpus references) and refuses slides with
builds. Charts copy like any drawable (Keynote's duplicate registers nothing for them either). Table clone (2026-10-15) copies what only the slide keeps alive, gives each table
a fresh `table_id`, moves its owner family in every UUID and CFUUID, and registers it as Keynote's
own duplicate does (owner-map twins, dependency records and tiles with remapped internal owner
ids): same internal ids and records as Keynote's duplicate, and the copy recalculates on its own
(checked through AppleScript cell edits). **Gate 3a passed 30/30** (`Scripts/gate1/gate3.py`, 2026-10-15, table and chart clones included; 6 of 7 later cases on the new feature decks passed, and `layouts.key delete 3` awaits a Keynote restart, see below) with every
page pixel-identical and Keynote's re-save idempotent (AT-23, `Scripts/resave.sh`). A deleted
table's calculation-engine owners go as a family: its `table_id` UUID is the base owner, the
others sit at a small offset in the low word, and sub-owners name it as `base_owner_uid`; their
dependency records, owner-ID map entries and UUID-map entries are removed. Phase 3b (2026-10-15): `deckmonkey slide import <deck> --from <source> --index N` appends another
deck's slide, re-pointing every outside reference at this deck's styles, masters and stylesheet
(docs/spec.md §9); no match refuses, naming the styles. Unnamed placeholder and text-box variations
(and named styles the target lacks) map by role through same-named masters; tables and charts take
the target theme's preset in the same slot; imported tables are registered with the target's
calculation engine and recalculate there (AppleScript cell edit); a table whose formulas read
another table is refused. A new object container must be object 61. Over the templates into Basic
Black: 1,299 of 1,642 slides import and validate (309 refused for a master name the target lacks, 34
for unmatched styles). Gate 3 import cases: 14/14 (templates of six themes, tables, charts, a mixed
slide, a referenced table). Open: builds, a master-name fallback for the 309.

Corpus at 150 (2026-10-15): four more feature decks (`cross-table`: a formula on one slide
reading a table on another, which needs the slide-qualified `Slide 1::Inputs::B2`; `layouts`: every
master layout; `mixed`: table, chart, image and shape on one slide; `text-styles`). Clone and delete
keep cross-table formulas working (AppleScript cell edits: a cloned dependent recalculates from its
source; a cloned source is independent; deleting a referenced table gives `#REF!`, exactly as
Keynote's own delete). The strength table now has 215 fields from 122 decks.

Phase 4 (2026-10-15, branch `phase4`): `deckmonkey from-ir <deck.json> --template t.key
[--parts deck.key]... [--plan-out plan.json]` (DeckIRWriter) builds a `.key` from a
`lectern.deck/1` Deck IR. The IR types come from LecternIR, extracted from LecternCore in rostrum
PR #74 (branch `deckmonkey/lectern-ir`, CI green); `phase4` builds against that checkout (`swift
package edit rostrum --path ../rostrum-lecternir`) and merges once a Rostrum release carries
LecternIR. The IR becomes a Codable `DeckPlan` (masters, text, new drawables with whole-point
frames), then is applied: each slide clones the template's own sample slide for its master and
`setParagraphs` fills it (Keynote's encoding: `\n`, null later para styles, level entries where the
level changes; only tables the storage has are touched). New drawables are copies of Keynote-made
parts, restyled to the theme's defaults: plain text item / shape (`Corpus/features/drawables.key`),
charts by type (`charts.key`, style lists from the target preset), tables by size
(`tables-parts.key`: every cell a unique "r<row>c<col>" text, so filling a table only rewrites its
string list; `importDrawables` brings the table onto the theme's own Title Only slide,
`setTableFrame` sizes it as Keynote does, `registerHeaderNames` registers its header words as
Keynote does). Layouts: 18 of 20 (all but image-backed ones, which fall back to bullets).
**Gate 4 (AT-24): 37/44 at 0 mismatched pixels** against Keynote building the same plan through
AppleScript (`Scripts/gate4`); 7 cases need hand-built references (sub-bullets, exactly placed text
boxes: `docs/hand-built-decks.md`). Decided (Jay, 2026-10-16): older themes without the Section,
Agenda, Statement or Big Fact masters stay refused with a typed error; no nearest-master fallback.
Open: those decks (Jay), images, builds. Table cells are text, as the IR's strings are.

Keynote on the M4 began refusing every oracle copy ("can't be opened right now | Operation not
permitted") after several hundred opens in one session; only a Keynote restart clears it, and the
user's own documents are open in Keynote, so that restart is the user's call.

Track R (2026-10-16, OQ-9, Jay): `KeynoteRender` draws a slide as SVG so Duo can show Keynote decks
(`deckmonkey render`; `Scripts/render/compare.swift` draws it through WebKit as Duo does and diffs the
golden page; `Scripts/render/gate.py` is AT-29). Read-only, portable, bounded against hostile input
(drawable, text, table and chart budgets). Facts learned: a bezier outline maps its own bounds onto the
frame (masks store 100×100); an image's stroke follows its mask; spacing below 1 comes off above the
baseline, but fit is judged with the last line at full height; a list's text indent is in ems of the
text size; table cells are version-5 packed buffers and merges live in the merge owner's colon-tract
formulas; a number shows in its number format; a chart's frame is its plot area and its axis rounds up
at the leading digit in four steps. A built-in theme's photos and textures are never in the file
(Keynote downloads them): the small copy or the fill's reference colour stands in and the page is not
judged. AT-29 over the corpus: 796 judged pages at a 0.76% median (all 1,876 at 1.84%); AT-28 also over
the private corpus (28 decks, 335 slides: reading uses `slideOrder()`, which walks Keynote 6.5's root
node and nested slides; `slideList()` stays the flat edit view). A text box without the width-valid
geometry flag sizes itself to its text (its stored size, often 0 × 0, is only a cache): its position
is the left edge, centre or right edge by its alignment, at its vertical centre. Duo uses it on PR #28 (DuoCore `KeynoteDeck`, pinned by revision). Any change to rendered output bumps
`KeynoteRenderer.revision` (Duo keys cached thumbnails on it); AT-28 fails when the corpus's SVG digest
changes under the same revision (the digest is kept in the git-ignored `Corpus/.render-revision.json`).

Geometry (2026-10-17): `setDrawableFrame`/`moveDrawable` (`deckmonkey object`) move and resize an
unrotated shape, text box, placeholder, image or movie; a cropped image is placed by its mask's frame,
as Keynote's AppleScript gives it. `Scripts/gate1/geometry.py` has Keynote make the same edit: 10/10
pixel-identical, re-save unchanged. Run edits for hosts: `KeynoteRenderer.drawables(onSlide:)` gives
each run's UTF-16 range for `replaceText`. `deleteDrawable` (`object --delete`) removes a shape, text
box, image, movie, group or line with what only it used; placeholders, tables and charts are refused;
the geometry gate's 4 delete cases match Keynote's own delete.

New slides (2026-10-17): `addSlide(fromMaster:at:)` (`slide masters`, `slide new`) copies a master's
title, body and slide-number placeholders and tagged objects with fresh identifiers and UUIDs (the
slide and its node need UUIDs, or Keynote asserts); placeholders and notes start empty, tagged objects
keep their words; node and notes come from a donor slide. `Scripts/gate1/newslide.py`: Basic White,
Kyoto, Showcase, Academy 4:3, one slide per master, every page identical to Keynote's New Slide.

Leave the machine alone while the oracle runs: input during a run fails the verdict ("rerun").
