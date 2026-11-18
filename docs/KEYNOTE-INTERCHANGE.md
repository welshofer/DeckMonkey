# Keynote Interchange in DeckMonkey

DeckMonkey exposes two distinct backends:

| Backend | Read/edit model | New authoring | Output |
| --- | --- | --- | --- |
| Native Keynote | `KeynoteDocument`, IWA graph surgery | `DeckIRWriter` on a Keynote-authored template | `.key` |
| Keynote Interchange | Rostrum's owned `KeyxDocument` | Shared `KeyxAuthor`, directly from `DeckIR` | `.keyx` |

No imported document passes through DeckIR. There is no `.key`/`.keyx`/PPTX
conversion, PowerPoint intermediate, Apple cloud call, or bundled Apple artwork.
The native graph API, builds, transitions, Magic Move and comments remain separate.
Apple calls interchange **1.0 beta**; it cannot represent all native features.

## Dependency status

**Development integration, not clean-checkout ready.** The `KeynoteInterchange`
product is implemented in Rostrum but is not in the currently pinned `1.1.0`
release. `Package.swift` declares the product without a machine-specific path or
an unpublished remote revision. A compatible published Rostrum release and an
updated minimum version/lockfile are required before this integration can ship.

For local development, use a frozen committed snapshot, not another session's
mutable checkout. The integration was developed against Rostrum
`ae7f973db433be59d8e6e551300591ffe4efa61b`:

```sh
# Set ROSTRUM_SOURCE to a local checkout containing the commit.
ROSTRUM_REV=ae7f973db433be59d8e6e551300591ffe4efa61b
SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/deckmonkey-rostrum.XXXXXX")"
git -C "$ROSTRUM_SOURCE" archive "$ROSTRUM_REV" | tar -x -C "$SNAPSHOT"
swift package resolve
swift package edit rostrum --path "$SNAPSHOT"
swift build --product deckmonkey
swift test --filter InterchangeTests
make keyx-check
```

SwiftPM's editable state and `Packages/` link are local and git-ignored; do not
commit them or replace the published package URL with that path. Keep the
snapshot while using the override. SwiftPM may remove the edited dependency from
`Package.resolved` during local builds; do not commit that transient lockfile
change. `swift package unedit rostrum` removes the
override, but builds will then fail until the published dependency is updated.

## CLI

```sh
deckmonkey keyx inspect input.keyx
deckmonkey keyx inspect input.keyx --slide 0
deckmonkey keyx verify input.keyx
deckmonkey keyx roundtrip input.keyx -o copy.keyx
deckmonkey keyx notes input.keyx --slide 0 --text "Presenter notes" -o edited.keyx
deckmonkey keyx notes input.keyx --slide 0 --remove -o without-notes.keyx
deckmonkey keyx from-ir deck.json -o new.keyx
deckmonkey keyx from-ir deck.json --template user-owned.keyx -o new.keyx
deckmonkey keyx from-ir deck.json --size 1024x768 --image intro=photo.png -o new.keyx
deckmonkey keyx render input.keyx -o preview/
```

Indexes are 0-based. The `--image` binding uses the source IR slide ID, may repeat
for different slides, and reads only explicitly supplied local PNG/JPEG/GIF files.
Output parent directories must exist. `render` creates its output directory.
`--size` uses points and cannot override a template's size. User-owned templates
need explicit, usable title/body or object placeholders and self-contained layouts.
Their starter slides are intentionally replaced; their theme, presets, resources
and unknown fields are retained, including unreferenced attachments. Do not use
a template containing private example resources you do not want in the output.

Every successful command returns JSON with `format: "keyx"`. Inspect reports
text, notes, tables, numeric chart values (including missing values as null),
resource filenames/sizes, fonts, shape counts, extraction warnings and semantic
diagnostics. It does not expose native object IDs or IWA component counts.
Authoring reports warnings and source-ID-to-authored-slide `slideGroups`, including
pagination. Unsupported geometry/layout detail may be approximated only as
documented by the shared author, with its warnings preserved in the result.

`notes --text` replaces the **entire note value** with plain text, intentionally
discarding the old note's formatting and fields; it does not rewrite other text,
objects or slides. `--remove` removes the note property instead of writing null:
null is not legal for notes. General find/replace, object and native slide surgery
are not exposed as interchange commands. Use the shared document API for explicit
property-level edits rather than flattening an imported deck.

`roundtrip` compares each original uncompressed ZIP entry's bytes after save and
reopen. `CLEAN` means the same names and payloads; `PRESERVED` means original
payloads match but the shared writer added absent default `manifest.json` and/or
`presets.json`, listed in `added`. ZIP compression, ordering and timestamps need
not match the input. Changed or removed original entries produce `DIFFERENT`
and exit 1. This is a preservation check, not visual acceptance.

Exit codes follow DeckMonkey: **0** pass, **1** invalid document/I/O/check failure,
**2** incorrect arguments, **3** unsupported/refused. Unknown or duplicate options
are rejected. Mislabeling interchange output as `.key`, using native commands on
`.keyx`, requesting `keyx render --stages`, or asking for conversion is refused.
Every document save uses the shared semantic validator before an atomic write.

## Public Swift API

`import DeckMonkey` re-exports `KeynoteInterchange`; there is no second JSON model,
writer, inspector or renderer in DeckMonkey.

```swift
import DeckMonkey

var document = try DeckMonkey.openInterchange(inputURL)
let firstSlide = try document.inspectSlide(at: 0)
try document.editSlide(at: 0) { slide in
    slide.setNote(.value(KeyxText("Updated notes")))
    // Unknown slide fields and unrelated content are still in slide.node.
}
try document.save(to: outputKeyxURL)
let preview = try KeyxPreviewRenderer.render(document, slideAt: 0)

let authored = try KeyxAuthor.render(deckIR)
try authored.document.save(to: newKeyxURL)
let preservation = try DeckMonkey.roundTripInterchange(inputURL, to: copyKeyxURL)
```

The shared value API also exposes `init(data:)`, `data()`, `KeyxNode`, `KeyxValue`,
tri-state `KeyxProperty` (`.inherited`, `.cleared`, `.value`), resource operations,
style resolution and authoring options. Supply `KeyxLimits` to `openInterchange`
for a smaller untrusted-input budget. The convenience file APIs and CLI enforce
`.keyx` extensions; direct `KeyxDocument.save(to:)` is the shared API and callers
must choose the correct filename.

Untouched JSON/resource/extension entries keep their bytes. Editing a JSON entry
preserves unknown fields and numeric spelling; its whitespace/key order may
change. Missing and null remain distinct. Property-level APIs do not promise
full schema semantics for unfamiliar fields; validation failures are errors,
not a reason to delete the offending data.

## Acceptance and limitations

`swift test --filter InterchangeTests` covers public file boundaries, payload
comparison (including deliberate corruption), shared authoring/inspection/preview,
surgical preservation and failed saves. `make keyx-check` exercises the real CLI
with synthetic text, notes, a table, a chart, an image, templates, unknown fields,
opaque resources, approximate SVGs and refusal/diagnostic cases. To keep evidence
locally, run:

```sh
python3 -I Scripts/keyx-check.py --work /path/to/new-evidence-directory
```

The script writes synthetic decks, SVGs and raw `commands.jsonl` output. No decks
or private corpus material belong in the repository.

These are portable checks, **not native Keynote acceptance**. The shared validator
is semantic, not all 242 Draft 2020-12 schemas. Previews are approximate and retain
per-slide warnings; they are not Keynote exports. Native open/no-repair and visual
acceptance are a separate coordinated gate, not established by this integration.
Do not run competing Keynote automation while another acceptance run owns it.

The shared author supports editable text, vector framing, notes, local images,
rectangular tables and numeric bar/line/pie charts. Some layouts become measured
reading-order text with warnings; complex diagrams, full chart styling, inferred
image crops and advanced table formatting are not claimed. Unsupported layouts,
ambiguous template placeholders and multi-series pie charts fail instead of
silently dropping data. The CLI's preview currently uses portable text estimates;
library callers may supply a `FontLibrary` and authoring `KeyxTextMeasurer`.

Builds/transitions/Magic Move, comments, Skip Slide, soundtracks/recordings, dynamic
backgrounds and other features excluded by Apple do not become lossless through
unknown-field preservation. Keynote regenerates slide identifiers when opening
interchange, so `slideGroups` is not a permanent external identity guarantee.

## References

- [Apple format documentation](https://developer.apple.com/documentation/keynoteinterchangeformat)
- [Authoring requirements](https://developer.apple.com/documentation/keynoteinterchangeformat/understanding-authoring-requirements-for-keynote-interchange-format)
- [Release notes](https://developer.apple.com/documentation/keynoteinterchangeformat/keynote-interchange-format-release-notes)
- [Apple's reference implementation](https://github.com/apple/creator-studio-doc-format/tree/995911cae658ffc98a1f63ccf314b5dd120d7652)
- Rostrum's `docs/KEYNOTE-INTERCHANGE.md` documents the shared implementation.
