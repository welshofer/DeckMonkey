# DeckMonkey — Phase 0 Spec v1.0

Oct 14, 2026 · Jay Welshofer · source of truth: https://claude.ai/code/artifact/2c664888-c7ca-4f19-bc94-42a0b8b9c24e

## 1. Purpose

A Swift library that reads and writes native Keynote (.key) files with no Keynote, AppleScript, or PPTX bridge in the loop. Name: DeckMonkey. Consumer: PresentationKit's Deck IR, so Lectern and Scaena target .key through the same IR they target .pptx through Rostrum.

Thesis: a .key is a Snappy-chunked Protocol Buffer object graph. Read it with a schema recovered from the Keynote binary; write it by graph surgery on a Keynote-authored template; let Keynote itself be the acceptance oracle. No output is "correct" because it parses; it is correct because Keynote opens it with no repair sheet and exports the expected PDF.

Phase 0 ends when the corpus round-trips archive-for-archive and the first mutation (text replace) passes the oracle with zero repair prompts, mirroring Rostrum Phase 0 (XML is truth, 26/26 green, roundtrip CLEAN 40/40) and its Gate 0 (zero repair prompts).

This document is written for Claude Code. Sections 5, 9, 12 and 14 are the contract; everything else is context.

## 2. Non-goals

Each of these is a scope trap Claude Code must refuse, even when it looks like a shortcut.

- No PPTX import or export bridge, and no AppleScript or Scripting Bridge as a write path. Keynote automation exists in this project only as the oracle (section 10).
- No legacy Keynote '09 APXL/XML format. If a file has `index.apxl`, the library reports `unsupportedLegacyFormat` and stops.
- No rasterizing or formula evaluation. Cached table values are read as data; nothing is computed. Rendering was a non-goal until 2026-10-16 (OQ-9): the read-only preview renderer of track R draws slides as SVG for viewers such as Duo, and nothing it computes is ever written into a file.
- No document synthesis from empty. Every write begins from a Keynote-authored template; the library never fabricates a theme, stylesheet, or master.
- No new styles through Phase 4. New content points at stylesheet entries that already exist in the template.
- No incremental or collaborative save. `should_merge` records are consumed on read and never emitted; every save is a full consolidation.
- No Pages or Numbers in Phases 0 to 4. The TSP/TSWP/TSD modules are shared and make them cheap later, but they are explicitly out until Phase 5.
- No preview regeneration. `preview*.jpg` is carried from the template until Phase 5 decides whether the oracle renders replacements.

## 3. Platform and toolchain

Swift 6.2 with strict concurrency complete and zero warnings, SwiftPM, no Xcode project. macOS 26 is the primary target because the oracle needs Keynote; the core modules must also compile and test on iOS 26 and Linux so CI can run the pure-Swift suites without a Mac.

| Concern | Decision |
| --- | --- |
| Protobuf runtime | apple/swift-protobuf |
| Protobuf codegen | `protoc` + `protoc-gen-swift`; generated sources are committed, so a clean checkout builds without protoc |
| Snappy | Pure Swift, written in-repo (section 4); no C library |
| Zip | Rostrum's zip layer, consumed as a package dependency on Rostrum (OQ-3) |
| Plists | Foundation `PropertyListSerialization` |
| Hashing | CryptoKit on Apple, swift-crypto on Linux, behind one `Digest` shim |
| Pinned Keynote | 15.4 (7051.0.79) on the M4 (OQ-2) |
| Oracle | macOS from Phase 0; Keynote for iPadOS from Gate 2 through an iPad runner (OQ-6); both behind a CI label |
| Repo | New repo, `DeckMonkey`; the Deck IR comes in as a dependency on Rostrum's IR package so there is one definition (OQ-7) |
| License | MIT, matching Rostrum; confirm against Rostrum's `LICENSE` before the first push (OQ-4) |
| Session brief | `CLAUDE.md` at the repo root, same shape as Rostrum's |

House conventions carried over from Rostrum and Lectern: value types for the graph, `Sendable` everywhere, typed errors (never `fatalError` on bad input), no shadow model, and the merge gate is `swift test` green AND `deckmonkey roundtrip` reporting CLEAN.

## 4. Format primer

Four layers, each with its own module and its own tests. Layers 1–3 were verified against the bytes of the private corpus on 2026-10-14 (28 modern decks saved by Keynote 6.5 through 15.4, Keynote for iOS and Keynote for iCloud: 1,002 components, 1,302 chunks, 54,344 archives, 57,611 `MessageInfo`s), by `deckmonkey dump` and by an independent schema-free survey using the reference Snappy decoder. Field numbers come from the bytes; field names are confirmed by the schema extracted from the pinned binary (`TSPArchiveMessages.proto`, section 7).

| Layer | What it is | Facts that matter |
| --- | --- | --- |
| 1 Container | A zip, or a package directory | Always present: `Metadata/Properties.plist`, `Metadata/BuildVersionHistory.plist`, `Metadata/DocumentIdentifier`, `preview.jpg`, `preview-micro.jpg`, `preview-web.jpg`, and `Data/` when there is media. The archives follow the form, not the age: a **zip** holds `Index/*.iwa` directly (9/9, saved by 6.6.1–15.4); a **package directory** holds them inside a nested `Index.zip` (19/19, saved by 6.5–7.0.5, iOS and iCloud), never as a bare `Index/` |
| 2 Chunk framing | Each `.iwa` is a sequence of chunks | Per chunk: one `0x00` byte, a 3-byte little-endian length, then a raw Snappy block. No CRC, no stream identifier, no standard framing. Every chunk decompresses to at most 65,536 bytes (64 KiB); the largest compressed body seen is 61,425 bytes |
| 3 Archive stream | The decompressed `.iwa` | Repeated: varint length, `TSP.ArchiveInfo`, then its payloads back to back (sum of the `MessageInfo` lengths). `ArchiveInfo`: 1 identifier (varint, always present), 2 message\_infos (repeated message), 3 should\_merge (varint, written only when true). `MessageInfo`: 1 type and 3 length (`required`), 2 version (always packed, always 3 elements, e.g. `1.0.5`, `10.1.0`); 4 field\_infos (`TSP.FieldInfo`: per-field-path object and data references plus an unknown-field rule, Keynote's forward-compatibility record; 14,584 ordinary payloads carry it); 5 object\_references and 6 data\_references (packed); 7 base\_message\_index, 8 diff\_merge\_version (packed), 9 diff\_field\_path, 10 fields\_to\_remove, 11 diff\_read\_version (packed) — 7–11 on merge diffs only (below). An ordinary archive has one `MessageInfo` (6 of 51,083 have two) |
| 3a Merge archives | `should_merge` true (3,261 seen) | Always exactly two `MessageInfo`s: `[0]` an ordinary payload with references; `[1]` a diff descriptor whose version is the sentinel `65535.65535.4294967295`, with base\_message\_index = 0 (i.e. `[0]`), diff\_merge\_version, diff\_field\_path, and diff\_read\_version on 12 of 3,261. In this corpus no merge archive shares an identifier with a non-merge archive, so each is an object on its own |
| 4 Schema | Private `.proto` files embedded in the Keynote frameworks (34 files in 15.4) | Packages TSP, TSK, TSCK, TSS, TSD, TSWP, TST, TSCE, TSCH, TSA, KN, plus `…SOS` packages. 625 registered type numbers, 101 more declared deprecated. A `super` field is a `TSP.Reference` to the parent archive (Apple's inheritance). Extensions carry app-specific fields. Type IDs resolve through `TSPRegistry` |

The object graph above layer 4: identifier 1 is the document (`KN.DocumentArchive`, type 1, in `Index/Document.iwa` in every deck), identifier 2 is `TSP.PackageMetadata` (type 11006, in `Index/Metadata.iwa` in every deck) (component list, `DataInfo` for every file in `Data/`, `last_object_identifier`, file-format and read/write versions). The show owns a slide tree of slide nodes; each node points at a `KN.SlideArchive`, which points at its master, its drawables, and its placeholders. Text lives in `TSWP.StorageArchive` as one string plus several attribute tables keyed by character offset (paragraph style, character style, list style, paragraph data, bidi, smart fields, attachments). Media is reached through `TSP.DataReference` → `PackageMetadata.datas` → `Data/<file_name>`.

## 5. Invariants

Eight named invariants. Each has at least one acceptance test in section 14; a change that breaks one is a design change, not a bug fix.

1. **Bytes are truth.** The decompressed archive payload is the model. Typed messages are decoded on demand and cached; there is no shadow object model. (Rostrum: XML is truth.)
2. **Preserve what you don't understand.** An object that was never mutated is re-emitted from its original decompressed bytes. A mutated object round-trips unknown fields through SwiftProtobuf's unknown-field storage. (Rostrum: Part retains original bytes; only dirty parts re-serialize.)
3. **Identifiers are global and monotonic.** One allocator per document, seeded above `last_object_identifier` and the highest identifier present; the counter is written back on save. The allocator is the only source of new identifiers.
4. **Reference lists are derived, never typed.** `MessageInfo.object_references`, `MessageInfo.data_references`, `PackageMetadata.components` and `PackageMetadata.datas` are recomputed from the serialized payloads before every save. Hand-maintained lists are a bug. `object_references` are the *strong* references only: those found in fields the pinned strength table (`reference-strength-<version>.json`, learned from decks the pinned Keynote alone authored) marks strong. An edit never drops a reference that was listed and is still present (records an older Keynote archived may list what the pinned one calls weak); in a mixed field a held reference keeps its membership and a new one is listed; a field the table does not know is refused when it holds a new reference. `data_references` hold one entry per derived `TSP.DataReference` occurrence, minus 0, the null sentinel (records older Keynotes archived may list each id once), and the per-component data index (`PackageMetadata.components[].data_references`) is rebuilt for every changed object. `PackageMetadata.components[].external_references` is rebuilt for every changed component: one entry per object in another component its payloads reference, a component's root object stored with no object identifier (never an explicit 0), `is_weak` only when every reference to the object is weak; entries no payload justifies are kept while their target exists (Keynote leaves such stale entries itself).
5. **Versions are inherited.** File-format version, read and write versions, every `MessageInfo.version`, and `BuildVersionHistory.plist` are copied from the template. The library never bumps a version.
6. **Styles by reference.** New content points at stylesheet entries that already exist. Through Phase 4 the library has no API that creates a style. Relaxed (Jay, 2026-10-21) for scene building only: a drawable's own look is a *style variation*, the record Keynote itself writes when a shape or text gets its own fill, stroke or font (parent a theme style, `is_variation`, only the overridden properties, its parent its one strong reference, registered in the document stylesheet's `styles` and under its parent in `parent_to_children_style_map`). Named styles are still never created.
7. **Keynote is the oracle.** A write is correct iff Keynote opens the output with no sheet and exports the expected PDF. "It parses" is not a pass.
8. **Fail loud.** A duplicate identifier, a dangling reference, an unsorted or out-of-range offset table, an unknown type ID, or a `DataReference` without a `DataInfo` and file is a typed error raised before any byte is written.

## 6. Module layout

Seven modules plus a scripts directory, one per layer, with dependencies pointing strictly downward. A module may import only the rows above it.

| Module | Owns | Depends on |
| --- | --- | --- |
| `IWASnappy` | Raw Snappy decode and encode; the 0x00 + 3-byte chunk framing | nothing |
| `IWAContainer` | Zip and package I/O, `Metadata/` plists, `Data/` store, previews | Rostrum's zip layer |
| `IWAArchive` | `ArchiveInfo` parsing, archive split and join, the raw object store (`[UInt64: RawObject]` with type, versions, bytes, reference lists) | IWASnappy, SwiftProtobuf (for `TSP.ArchiveInfo` only) |
| `IWASchema` | Generated SwiftProtobuf sources per pinned Keynote version, the type-ID registry, `decode(type:bytes:)` and `encode` dispatch with extension maps. Generated, never hand-edited | SwiftProtobuf |
| `KeynoteGraph` | Typed graph (`Document`, `Show`, `Slide`, `Drawable`, `TextStorage`), lazy decode, identifier allocator, surgery ops, reference derivation, consolidation, validator | IWAArchive, IWASchema, IWAContainer |
| `DeckMonkey` | Public API: Deck IR in and out, mirroring PresentationKit's surface | KeynoteGraph, Rostrum's Deck IR package |
| `KeynoteRender` | Track R: a slide as SVG (backgrounds, master objects, shapes, images, text laid out with Rostrum's font metrics). Read-only, portable | KeynoteGraph, Rostrum's font layer |
| `deckmonkey` | CLI: inspect, dump, roundtrip, verify, replace, image, slide, from-ir, schema, corpus | DeckMonkey |
| `Scripts/` | `protodump`, registry dump, `schema-diff`, macOS oracle, iOS oracle runner, corpus generator | macOS tools, Xcode |

`IWAArchive` has no schema dependency beyond `TSP.ArchiveInfo`, so a file from an unknown Keynote version still round-trips byte-for-byte through the raw store (invariants 1 and 2) even when nothing in it can be decoded.

## 7. Schema pipeline

The schema is derived from the installed Keynote binary by a repeatable `make schema` and committed per version. Nothing in `IWASchema` is written by hand.

1. **Extract.** `Scripts/schema/protodump extract` scans the installed Keynote (found by bundle id, `Scripts/keynote-app.sh`; on the M4 it is "Keynote Creator Studio.app") — the main executable and every embedded framework — for serialized `FileDescriptorProto` blobs: find `.proto` filename suffixes, scan back to the `0x0A` length-delimited tag, walk the wire format while tags stay valid, and validate by decoding as `Google.Protobuf.FileDescriptorProto`. 15.4: 34 files across 10 binaries, every import resolved, duplicates byte-identical.
2. **Render.** Each descriptor is rendered back into `.proto` source for review and diff. Fix-ups: `-` in identifiers becomes `_`; package names kept; `required` fields kept as-is so SwiftProtobuf enforces them at encode time (invariant 8).
3. **Generate.** The descriptors go straight to `protoc-gen-swift` as a `CodeGeneratorRequest` (`Visibility=Public`), with `json_name` filled the way protoc would; no `protoc` and no `.proto` parsing, so a rendering slip cannot reach generated code. Output is committed under `Sources/IWASchema/Generated/<keynote-version>/`.
4. **Registry.** `TSPRegistry` (type number → message) is recovered statically: Frida and lldb cannot attach to a hardened-runtime Keynote with SIP on. `Scripts/schema/registry-dump.py` reads every `-[TSPRegistry set…MessageType:…]` call out of the arm64 disassembly and identifies each message by its descriptor (descriptor table + index into `file_level_metadata`), cross-checked against every surviving `default_instance` symbol (Scripts/schema/README.md). Emit `registry-<version>.json` — types, declared-deprecated types, every registration — then generate the type switch and the union of the extension maps from the JSON plus the descriptors.
5. **Pin.** On open, read `BuildVersionHistory.plist` and `Properties.plist`; select the matching generated module. A file written by a newer Keynote opens read-only through the raw store, and any write is refused with `schemaNewerThanLibrary` (invariants 5 and 8).
6. **Diff.** `make schema-diff` re-extracts against the current Keynote and diffs `.proto` and registry output against the pinned version. CI fails on any rename or removed field until a dated migration note lands in `Docs/schema-changes.md`. Prior art shows renames between minor releases (Keynote 10.2 to 11.2), so this runs on every Keynote update, not on a schedule.

The pinned version for Phase 0 is Keynote 15.4 (7051.0.79), the build on the M4 today (OQ-2). It is recorded in `CLAUDE.md` and is the name of the first generated schema directory.

## 8. Reader design

Open is cheap and lazy: the container is indexed, every `.iwa` is decompressed into the raw store, and nothing is decoded until asked for.

- **Load order.** Read `PackageMetadata` (identifier 2) first for the component list, then every component in two passes: non-merge archives populate the store; `should_merge` archives are kept as separate raw payloads attached to the same identifier. Typed decode of a merged object applies the base payload and then each merge payload through `Message.merge(serializedBytes:)`, so the raw store never loses the original bytes (invariant 1).
- **Raw object.** `RawObject { id: UInt64, type: UInt32, versions: [UInt32], payload: Data, objectRefs: [UInt64], dataRefs: [UInt64], component: ComponentID }`. This is what round-trips.
- **Typed access.** `document.decode(id, as: KN_SlideArchive.self)`, `document.dereference(ref)`, cached per identifier. A decode failure is a typed error that names the identifier and type; an unknown type ID falls back to the raw object and marks the document read-only for that object (invariant 8 applies at write, not read).
- **Navigation.** `document.show.slides` (in slide-tree order, with skip and depth), `slide.master`, `slide.drawables` (z-order), `slide.placeholders`, `drawable.textStorage`, `storage.text`, `storage.runs(of: .characterStyle)`. These are thin proxies over decoded messages, not copies.
- **Media.** `document.data(for: dataRef) -> Data` resolves through `PackageMetadata.datas` to `Data/<file_name>`; digest is checked on read and a mismatch is reported, not thrown.
- **Metadata.** `Properties.plist`, `BuildVersionHistory.plist`, `DocumentIdentifier` and the previews are exposed as-is and carried through save untouched (invariant 5).

## 9. Writer design

The writer is graph surgery on a template, followed by consolidation and validation. There is no "build a document" path.

**Mutation model.** Surgery ops mark objects dirty: `replaceText`, `replaceImage`, `cloneSlide`, `deleteSlide`, `moveSlide`, `insertTextBox`, `fillPlaceholder`. Save re-serializes only dirty objects; every other object is emitted from its original payload (invariant 2).

**Identifier allocation.** `IDAllocator(seed: max(lastObjectIdentifier, maxIDInStore) + 1)`; save writes the new high-water mark back into `PackageMetadata.last_object_identifier` (invariant 3).

**Reference derivation.** Before emit, each dirty message is traversed with a SwiftProtobuf `Visitor` that collects every `TSP.Reference` and `TSP.DataReference` identifier it contains, with the field each came from. Keynote lists only strong references in `object_references`: weak ones (parent and owner back-pointers, UI state) are left out and may dangle — 807 do in the Phase 0 corpus. Which fields are strong is not in the schema, and it depends on which Keynote archived the record: decks saved by 6.5–8.1 list some fields that 15.4 does not. `make reference-strength` therefore learns the pinned Keynote's rule from the in-repo decks it alone authored (`Corpus/templates`, `Corpus/features`) into `Sources/IWASchema/Registry/reference-strength-<version>.json` — 15.4 over 106 template and 12 feature decks: 210 fields, 194 strong, 16 weak, 0 mixed, covering 169 of the 201 fields seen in older decks and 99% of their reference occurrences — reproducible from the repository with no private deck. The rule of invariant 4 turns the traversal into the lists. The same traversal, with an identifier map instead of a collector, rewrites references during clone. Acceptance test AT-07 proves the rule reproduces Keynote's own lists on the whole corpus before any mutation code is trusted (invariant 4). Fields the generated corpus never exercises (builds, nested slide-tree children, some legacy table internals) are added as hand-authored feature decks arrive; until then an edit adding a reference in one is refused.

**Text replace (Phase 1).** Replace `StorageArchive.text[0]` (every corpus storage holds exactly one string) and remap every offset-keyed attribute table through an edit script of (oldRange → newRange), in UTF-16 code units, the unit iWork indexes in; paragraphs end in `\r`. Entries starting inside the replaced range collapse to the entry in force at the range start; the entry in force at the range end is re-anchored just after the new text, so the text after the edit keeps its own style; entries after shift by the length delta, and on a collision (a deletion) the later entry wins. Character runs are start/end pairs (`6→style`, then a bare `10`). Phase 1 scope is single-run replacement: the new text inherits the style in force at the first replaced character. Smart fields and hyperlinks overlapping the range are removed and reported (the corpus's hyperlinks are `TSWP.HyperlinkFieldArchive` in `table_smartfield`, in slide text and in presenter notes). Refused rather than guessed: a paragraph break in the range or the new text, an attachment or footnote anchored inside the range, tracked changes, a range splitting a surrogate pair. Only tables the storage already has are written: an empty table Keynote never wrote makes it "upgrade" the storage on every read, and a corpus test proves an empty edit re-encodes all 10,420 storages byte for byte. Multi-style preservation is Phase 4.

**Image replace (Phase 2).** As Keynote 15.4 writes an inserted image: `Data/<stem>-<id>.<ext>`, a `DataInfo` (identifier, file\_name, preferred\_file\_name = the original name, digest = SHA-1 of the bytes, image attributes with the pixel size, materialized\_length), the `TSD.ImageArchive` repointed with `naturalSize`, `originalSize` and its traced outline at the new size; the frame is kept and Keynote's "-small" thumbnail dropped. A `DataInfo` with no remaining referrers is dropped along with its file and its data-metadata entry, so no orphan is written (0 of 5,996 in Keynote's own files). Keynote also indexes data use per component (`PackageMetadata.components[].data_references`: data → object → count) and loads data by it; save rebuilds the entries of every changed object from its payload. Images Keynote has edited (adjustments, instant alpha, kept originals) are refused. Movies and audio clips (a `TSD.MovieArchive`, `audioOnly` for audio) go the same way: the media file, `endTime` = its duration and the video size read from the MPEG-4 boxes, a poster image supplied by the caller for video (a frame cannot be rendered portably), and the old fingerprint dropped; live-video placeholders, streaming media and switching between audio and video are refused. Theme photos backed by app resources (a `DataInfo` with no or an empty file name) are replaced the same way; the resource stays while masters use it.

**Slide move and delete (Phase 3a, as built).** The show's `slideTree.slides` lists slide nodes; each slide lives in its own component, which in 15.4-authored decks nothing outside references strongly but its node. Move reorders the list. Delete removes the node and the component, its `ComponentInfo` and the references to it, then collects what only the slide kept alive, as Keynote's save does: objects whose every strong referrer is gone (a table's model and tiles, a chart's non-style archives), the calculation engine's dependency records whose owner (by reference, owner UUID or base-owner UUID) is gone, components left empty, and data only removed objects used. After deleting a table, Keynote's next save still rebuilds a few dependency records of the remaining tables (a derived cache).

**Slide clone (Phase 3).** Depth-first copy from `KN.SlideArchive` over `objectRefs`, stopping at the shared-node set: masters, theme, stylesheet, every style archive, document, package metadata, show, slide tree. Each visited object gets a fresh identifier; references are rewritten through the identifier map; a new slide node is appended to the slide tree at the requested index. Masters and placeholders stay linked by not being cloned. As built (3a): references are rewritten at the wire level by a schema-driven rewriter (the extracted descriptors say which fields are `TSP.Reference` and `TSP.UUID`; every other byte is copied), each copied object gets a fresh UUID in the new component's UUID map, the new `ComponentInfo` and the Document component's reference to it are added, and `last_object_identifier` is raised. Slides with tables, charts or builds are refused for now: they register owners and targets by UUID with the calculation engine and the build system. Cross-deck clone (3b) first reconciles the target's theme and stylesheet by reference and refuses on mismatch. As built (3b, `importSlide`): the copy is the same held-only closure; every reference leaving it is re-pointed at the target's own objects, never at a copy (invariant 6): a style by `style_identifier`, else name, when exactly one style of that type matches; an anonymous variation (a master's placeholder or text-box style with theme overrides) by correspondence: each source master paired with the target master of the same name, placeholders by kind and other drawables by type in order, the style a counterpart uses in the same field (majority over all masters), else a byte-identical variation of the counterpart parent; the master by name; the stylesheet to the target's document stylesheet; a reference the source leaves dangling to a fresh unused identifier. Any style without a match refuses the import, naming them all. Role-based counterparts (from masters) apply to any style; position-based ones (from the theme's preset slots: every Apple theme has the same six table and six chart presets, and everything under a preset pair is paired field by field) apply only to presets and unnamed styles. Data comes along under new data identifiers (shared when the digest is already there), with its `DataMetadata`. Tables are registered with the target's calculation engine (strict: a table whose dependency records name an owner outside its own family, i.e. formulas reading another table, is refused). Objects of a source object container join the target's, created as object 61 when the target has none (Keynote's fixed identifier; any other makes it rewrite the deck on read). The copy takes on the target theme. Builds are refused.

**Consolidation.** Each component is emitted as one archive stream of full objects, no `should_merge`; the component table is rewritten to exactly the files emitted; stale `.iwa` files are not carried over. Zip layout is the default output; package form is a flag.

**Validator.** Runs before any byte is written and raises a typed error on: duplicate identifier, dangling reference, offset table unsorted or past the text length, `DataReference` without `DataInfo` or file, unknown type ID in a dirty object, `last_object_identifier` below any identifier in use (invariant 8).

## 10. Oracle harness

`Scripts/oracle` takes a `.key` and returns a JSON verdict; `deckmonkey verify` wraps it. It is the only place Keynote is automated, and it only ever opens, exports, and closes.

1. Copy the file to a temp directory so Keynote never touches the artifact under test.
2. `osascript`: `tell application "Keynote" to open POSIX file …`, then poll `exists document 1` with a 30 s timeout.
3. Repair and incompatibility detection: through System Events, any sheet or dialog attached to the Keynote process after open is a FAIL, captured by title and button labels. Keynote's "can't be opened", "needs a newer version", and repair prompts are all sheets.
4. `export document 1 to POSIX file … as PDF`, then `close document 1 saving no`.
5. Rasterize the PDF at 72 dpi with CoreGraphics (a 40-line Swift tool in `Scripts/`), compare page-by-page against the golden PDF: pixel mismatch count and the bounding box of mismatched pixels. Round-trip expects 0 mismatches; a mutation expects mismatches only inside a caller-supplied mask (the replaced text's frame, the image's frame, the new slide).
6. `log show --predicate 'process == "Keynote"' --last 2m`, filtered for TSP, archive, repair, and unable; any hit is recorded and fails the verdict. The unified log is more specific than the UI about what Keynote disliked.
7. Verdict: `{opens, sheet, pdfMismatch, pdfMismatchBounds, logHits, keynoteVersion}`.

Runs on the M4 under a logged-in user session with Keynote's automation permission granted once. CI invokes it only on the `oracle` label; Linux CI runs everything else. Flakiness is handled by one retry and a quarantine list, never by relaxing the verdict.

**iOS oracle (in scope, online by Gate 2).** Keynote for iPadOS runs the same TSP engine with less tolerance than the Mac build, so it catches the silent-corruption case AT-23 is about. Mechanism: an XCUITest runner on a USB-attached iPad drives Keynote for iPadOS through accessibility. The file is pushed to the device (iCloud Drive or `devicectl`), opened from Files into Keynote, any alert is a FAIL, Share → Export → PDF lands in Files, and the PDF is pulled back and diffed against the macOS export at 0 mismatched pixels (AT-27). It costs minutes per file, so it runs at gates and on the quarantine list, not on every test; `deckmonkey verify --ios` invokes it.

## 11. Corpus

The corpus is the hostile sweep from Rostrum applied to Keynote: every theme, every feature, real decks, and the same deck across Keynote versions. For now no deck is committed: `make corpus` builds the corpus locally from the committed scripts (`Scripts/corpus-gen`, `deckmonkey corpus hostile`, `make goldens`), recording each deck in a local `Corpus/manifest.json` (digest, last save, file format, oracle Keynote). Golden PDFs are ~9 MB each (~1 GB for the templates) and would stay local even if decks were later committed under git LFS. The oracle needs Keynote anyway, so anyone who can check a golden can make one.

| Directory | Contents | Phase 0 target |
| --- | --- | --- |
| `Corpus/templates/` | One deck per built-in theme, standard and wide, with every master layout instantiated once; generated by a one-time AppleScript in `Scripts/corpus-gen` | all themes × 2 sizes |
| `Corpus/features/` | Hand-authored, one feature each: lists, bidi text, smart fields, hyperlinks, masked images, shadows and reflections, each shape path type, groups, tables with formulas and merged cells, each chart type, equations, video, audio, GIF, 3D object, per-object builds, Magic Move, each transition, presenter notes, comments, skipped slides, slide numbers, locked objects, links to slides | ≥ 30 decks |
| `Corpus/wild/` | Real decks from Jay's archive, no customer material; Jay builds the selection: 10 for Phase 0, 40 by Phase 3, spread across saves from Keynote 6 through 15.4, both slide sizes, media-heavy and build-heavy (OQ-5) | ≥ 10 decks |
| `Corpus/versions/` | The same feature deck saved by each Keynote version available, for schema pinning | every version on hand |
| `Corpus/hostile/` | Deliberately broken copies: duplicate identifier, dangling reference, truncated chunk, unknown type ID, offset past text length | one per validator rule |

Phase 0 gate requires ≥ 40 files across the first four directories; Phase 3 requires ≥ 150. Ingest is `deckmonkey corpus add <file>`, which records the Keynote version, runs the oracle, and stores the golden PDF beside the file.

## 12. Phases and gates

Six phases, strictly sequential. A gate is passed only by the acceptance tests it names (section 14) plus the oracle; nothing in a later phase starts on a partial gate.

_Roadmap diagram (six phases, each gated) lives in the Claude doc: https://claude.ai/code/artifact/2c664888-c7ca-4f19-bc94-42a0b8b9c24e_

Phase 0 is the accent because it is the only phase whose output nobody else consumes; every later gate reuses Gate 0's harness and corpus.

**Phase 0 — Foundation.** Schema pipeline for Keynote 15.4 (7051.0.79); `IWASnappy`, `IWAContainer`, `IWAArchive`, `IWASchema`; raw store with two-pass merge; `deckmonkey inspect`, `dump`, `roundtrip`, `verify`; corpus ≥ 40 with golden PDFs; macOS oracle harness. Gate 0: AT-01 to AT-13, roundtrip CLEAN 40/40, oracle 40/40 with 0 mismatched pixels and no sheets.

**Phase 1 — Text replace.** Offset-table remap, single-run semantics, smart-field and hyperlink removal rule, validator. Gate 1: AT-14 to AT-17 on 25 replacement cases, oracle 25/25, PDF mismatches confined to the replaced text's frame.

**Phase 2 — Image and media replace.** `DataInfo` creation with SHA-1 digests, data-reference derivation, orphan removal, video and audio through the same path; iOS oracle runner online. Gate 2: AT-18, AT-19 and AT-27, macOS and iOS oracle pass, mismatches confined to the image frame.

**Phase 3 — Slide surgery.** 3a: clone, delete, move within a deck. 3b: cross-deck clone with theme and stylesheet reconciliation. Gate 3: AT-20 to AT-23, cloned page pixel-identical to its source, Keynote re-save adds no objects, corpus ≥ 150.

**Phase 4 — New drawables and Deck IR.** Text box, image, and shape insertion using template styles; placeholder fill; multi-style text preservation; `deckmonkey from-ir` so Lectern emits `.key` from the same IR it feeds Rostrum. Gate 4: AT-24, 25 IR fixtures at 0 mismatched pixels against Keynote's own export of hand-built reference decks, re-save idempotent on macOS and iOS.

**Phase 5 — Builds, transitions, and the siblings.** Build and transition edits verified through movie export; Pages and Numbers readers on the shared modules; schema migration between Keynote versions; preview regeneration decision. Gate 5: build keyframes match in exported movie frames; AT-25 across every version in `Corpus/versions/`.

**Track R — Preview renderer (read-only, parallel to the writer phases).** `KeynoteRender` turns a slide into SVG, the form Duo already draws through WebKit, so a viewer can show a `.key` without Keynote. It never writes a file, so it cannot break an invariant, and it runs beside the writer phases rather than after Gate 4 (OQ-9). Order: R1 slide size, backgrounds, master objects, images with masks, shapes with fills and strokes; R2 text (paragraph and character styles, lists, shrink-to-fit, vertical alignment) measured with Rostrum's `FontMetrics`; R3 groups, lines and connectors, tables, charts, movies' posters. Fonts come from the caller as a Rostrum `FontLibrary`; a face it lacks falls back to an estimate and is reported. Gate R: AT-28 and AT-29.

## 13. CLI: deckmonkey

`deckmonkey` is the acceptance surface, the way `pptx-tool` is for Rostrum: every gate is a `deckmonkey` invocation with a machine-readable exit code and JSON report.
Exit codes: `0` pass, `1` fail, `2` usage error, `3` refused by design (a Keynote '09 APXL file, out
of scope per section 2). Gates count a `3` as skipped, never as a pass or a failure.

| Subcommand | Does | Phase |
| --- | --- | --- |
| `inspect <file>` | Component list, object count by type, versions, schema match, warnings for unknown type IDs | 0 |
| `dump <file> [component or id]` | YAML of decoded objects with references shown as `@id`; raw hex for undecodable objects | 0 |
| `roundtrip <file>` | Open, save, compare decompressed archives per component; prints `CLEAN n/n` or the first differing identifier | 0 |
| `verify <file> [--golden pdf] [--mask rect] [--ios]` | Validator plus oracle harness; `--ios` adds the iPad runner; JSON verdict; non-zero exit on any failure | 0 (`--ios` from 2) |
| `schema extract` / `schema diff` | Runs the section 7 pipeline against the installed Keynote | 0 |
| `corpus add <file>` | Ingests a corpus file, records Keynote version, stores golden PDF | 0 |
| `replace <file> --find --replace [--storage id]` | Text replace | 1 |
| `image <file> --object id --with path` | Image or media replace | 2 |
| `slide clone / delete / move <file> --index n [--from other.key]` | Slide surgery | 3 |
| `from-ir <deck.json> --template t.key -o out.key` | Deck IR to `.key` | 4 |

Every mutating subcommand runs the validator before writing and refuses on the first error; `--force` does not exist.

## 14. Acceptance tests

Twenty-nine tests, each a `swift test` case or a `deckmonkey verify` run with a fixed expected output. A test is passed only when it is green on the full corpus for its phase, not on a sample. There is no mismatch threshold anywhere except AT-29, the preview renderer's (OQ-9): the goal is perfect fidelity, and every pixel comparison is against Keynote's own export (OQ-8).

| # | Test | Phase |
| --- | --- | --- |
| AT-01 | Snappy decode of every chunk in the corpus matches a reference decoder's output (reference run once in CI, hashes cached) | 0 |
| AT-02 | Snappy encode then decode is identity on 10,000 random buffers, including empty, one byte, and sizes crossing the 64 KiB block boundary | 0 |
| AT-03 | Reframe of a deframed `.iwa` decompresses to identical bytes for every corpus file | 0 |
| AT-04 | Archive split then join is identity on every `.iwa` | 0 |
| AT-05 | Every type ID in the corpus resolves in the pinned registry; the test prints any that do not and fails | 0 |
| AT-06 | Every strong `TSP.Reference` (listed in `object_references`) in every Keynote-authored corpus file resolves to an existing object; weak ones may dangle | 0 |
| AT-07 | In every deck the pinned Keynote alone authored, the strong-reference rule (invariant 4) applied to each derived traversal equals the stored `object_references` set for every archive; in older decks stored ⊆ derived and the edit rule drops no stored reference; a reference field missing from the strength table fails | 0 |
| AT-08 | Derived `data_references` occurrences minus the null id 0 equal the stored list as a multiset in decks the pinned Keynote alone authored, and as a set in older decks | 0 |
| AT-09 | `deckmonkey roundtrip` reports CLEAN on 40/40 corpus files | 0 |
| AT-10 | Oracle: 40/40 round-tripped files open with no sheet, no log hits, 0 mismatched pixels against the golden PDF | 0 |
| AT-11 | After save, `Properties.plist`, `BuildVersionHistory.plist`, every `PackageMetadata` version field and every `MessageInfo.version` are byte-identical to the input | 0 |
| AT-12 | A synthetic unknown field injected into a copy survives decode, mutation of a sibling field, and encode | 0 |
| AT-13 | `swift build` and `swift test` are green on Linux for every module except `deckmonkey verify` | 0 |
| AT-14 | Same-length text replace: oracle pass; every attribute table byte-identical to the input | 1 |
| AT-15 | Longer and shorter text replace: every offset table sorted and within the new length; oracle pass | 1 |
| AT-16 | Replace spanning a style boundary collapses to the style in force at range start; oracle pass | 1 |
| AT-17 | Replace overlapping a smart field or hyperlink removes it, reports it, and passes the oracle | 1 |
| AT-18 | Image replace: new `DataInfo.digest` equals SHA-1 of the file; oracle pass; mismatches only inside the image frame | 2 |
| AT-19 | Image replace leaves no `DataInfo` without a referrer and no file in `Data/` without a `DataInfo` | 2 |
| AT-20 | Clone: the clone's subgraph shares no identifier with the source outside the shared-node set; PDF page n+1 is pixel-identical to page n | 3 |
| AT-21 | Delete: no dangling reference remains; oracle pass; page count drops by one | 3 |
| AT-22 | Move: slide-tree order equals the request; oracle pass; pages reorder accordingly | 3 |
| AT-23 | Idempotence: Keynote opens the output, re-saves it, and the re-saved file's object histogram by type equals the output's | 3 |
| AT-24 | 25 Deck IR fixtures produce decks that open, pass both oracles, and match Keynote's own export of the hand-built reference deck at 0 mismatched pixels | 4 |
| AT-25 | A file from a newer Keynote opens read-only through the raw store; any write raises `schemaNewerThanLibrary` | 0 |
| AT-26 | Each file in `Corpus/hostile/` raises its named validator error and writes nothing | 0 |
| AT-28 | Track R: every slide of every template and feature deck renders to well-formed SVG with no thrown error, and every drawable kind it cannot draw is reported by name, never silently dropped | R |
| AT-29 | Track R: `Scripts/render/compare.swift` rasterizes each slide's SVG through WebKit and the golden PDF's page through CoreGraphics at 960 points wide and reports the share of pixels whose colour differs by more than 48/255 in any channel; the gate is a median at or below 3% and no slide above 15% over the templates and feature decks. A slide that needs what its file does not hold (a built-in theme's photo or texture, which Keynote downloads from Apple and never stores in the deck; a font the machine lacks) cannot be judged from the file: it is drawn with a reported stand-in and counted, not barred (`Scripts/render/gate.py`) | R |
| AT-27 | iOS oracle: every file that passes AT-10 also opens in Keynote for iPadOS with no alert and exports a PDF at 0 mismatched pixels against the macOS export | 2 |

## 15. Risks

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Schema churn on every Keynote release (renames observed between minor versions) | Certain | Per-version generated module; `schema diff` on every update; read-only fallback for newer files (AT-25) |
| Silent corruption: output opens today, breaks on Keynote re-save or on iPadOS | High | AT-23 idempotence; iOS oracle from Gate 2 (AT-27) |
| Registry dump needs Frida, which may need SIP relaxed | Medium | Fallback parses registry strings from the binary; `registry-<version>.json` is committed so extraction is rare |
| Clean-room and licensing: protos derive from Apple's binary; WorkKit is AGPL-3.0; DeckMonkey ships MIT | Medium | Generate our own protos and registry; treat WorkKit and keynote-parser as design references only, no copied code |
| macOS oracle flakiness: modal sheets, GUI session, permission prompts | Medium | Dedicated user session, 30 s timeouts, one retry, quarantine list, never a relaxed verdict |
| iOS oracle brittleness: XCUITest against a third-party app, iPadOS updates moving the share sheet | Medium | Accessibility identifiers over coordinates; runner pinned to one iPadOS build; runs at gates only |
| Perfect-fidelity bar for IR → .key: Keynote's text autosizing and line breaking must be reproduced, not approximated | Medium | Golden is Keynote's own export of a hand-built reference deck; a mismatch is investigated and fixed in the writer, never thresholded away |
| Snappy edge cases at the 64 KiB block boundary and long literals | Low | AT-02 fuzz; AT-01 reference comparison |
| Text offset model is richer than assumed (bidi, attachments, overlapping hyperlinks) | Medium | Phase 1 scope is single-run; AT-15 asserts table integrity rather than semantics; Phase 4 widens |
| `required` fields in extracted protos reject partially built messages at encode | Low | Templates always supply them; the validator reports the field name |

## 16. Decisions

All eight open questions were answered on 2026-10-14 and are applied throughout this spec. Claude Code can start.

- [x] OQ-1 Name: DeckMonkey. Applied to the package, the public module `DeckMonkey`, and the `deckmonkey` CLI.
- [x] OQ-2 Pinned Keynote: 15.4 (7051.0.79). Recorded in sections 3 and 7; goes into `CLAUDE.md` on day one.
- [x] OQ-3 Zip: reuse Rostrum's zip layer as a package dependency ("Yes" read as the first option; say so if it meant ZIPFoundation).
- [x] OQ-4 License: MIT, matching Rostrum. Confirm against Rostrum's `LICENSE` before the first push.
- [x] OQ-5 Wild corpus: Jay builds the selection. 10 decks for Phase 0, 40 by Phase 3, spread across saves from Keynote 6 through 15.4, both slide sizes, media-heavy and build-heavy.
- [x] OQ-6 iOS Keynote oracle: in scope, online by Gate 2 (section 10, AT-27).
- [x] OQ-7 Repo: new repo `DeckMonkey`; the Deck IR comes in as a dependency on Rostrum's IR package.
- [x] OQ-8 Fidelity: perfect. AT-24 is 0 mismatched pixels against Keynote's own export of a reference deck; no threshold anywhere in the suite.
- [x] OQ-9 Rendering (Jay, 2026-10-16): DeckMonkey gets a read-only preview renderer (track R) so Duo can show Keynote decks. Its gate, AT-29, measures similarity with a threshold: this is the one exception to OQ-8, because a preview is drawn by another engine and is never the file. Every writer gate keeps 0 mismatched pixels.

## 17. References

Design references only. No code is copied from any of them (section 15).

- [Reverse Engineering iWork](https://andrews.substack.com/p/reverse-engineering-iwork), Andrew Sampson, October 2025: descriptor extraction from the binary, pure-Swift Snappy, `TSPRegistry` dump via Frida, two-pass merge, extension handling.
- [6over3/WorkKit](https://github.com/6over3/WorkKit): Swift package parsing Keynote, Pages, and Numbers with a visitor API; read-only; AGPL-3.0. Its `proto/` and `scripts/` directories show the pipeline shape.
- [psobot/keynote-parser](https://www.github.com/psobot/keynote-parser): Python unpack, pack, and in-place text and image replacement; its release notes document proto renames between Keynote 10.2 and 11.2 and the lack of backward compatibility.
- masaccio/numbers-parser: Python read and write for Numbers; the closest existing writer and the model for template-based mutation.
- obriensp/iWorkFileFormat: the original public description of the IWA format and `protodump`.
- apple/swift-protobuf: runtime, `protoc-gen-swift`, and the `Visitor` protocol used for reference derivation.
- Rostrum Phase 0 and `lectern-spec-v1.0.md`: the invariants, gate definition, and CLI-as-oracle pattern this spec mirrors.
