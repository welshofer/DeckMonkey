# Schema pipeline (docs/spec.md §7)

Nothing in `Sources/IWASchema` is hand-written. `make schema` runs these steps against the
installed Keynote and commits the result under a version directory. Pinned for Phase 0:
**Keynote 15.4 (7051.0.79)**.

| Step | Tool | Output |
| --- | --- | --- |
| 1 Extract | `Scripts/schema/protodump` (Swift) scans `/Applications/Keynote.app/Contents/MacOS/Keynote` and its embedded frameworks for serialized `FileDescriptorProto` blobs: find `.proto` suffixes, scan back to the `0x0A` tag, walk the wire format to the terminating null tag, validate by decoding as `Google_Protobuf_FileDescriptorProto`. | `proto/15.4/*.proto` (rendered) |
| 2 Render | SwiftProtobuf `Visitor` over each descriptor back to `.proto` source. Fix-ups: `-` in identifiers → `_`; keep package names; keep `required`. | same |
| 3 Generate | `protoc --swift_out=Sources/IWASchema/Generated/15.4 --swift_opt=Visibility=Public proto/15.4/*.proto` | committed Swift |
| 4 Registry | `Scripts/schema/registry-dump.js` (Frida) reads `TSPRegistry.sharedRegistry()`'s description for `type -> class` lines; fallback parses those strings out of the binary. | `Sources/IWASchema/Registry/registry-15.4.json` |
| 5 Dispatch | `Scripts/schema/gen-dispatch` emits `decode(type:bytes:)` with each message's extension map from the registry JSON plus the generated Swift. | `Sources/IWASchema/Generated/15.4/Dispatch.swift` |
| 6 Diff | `make schema-diff` re-extracts and diffs against the pinned tree; CI fails on any rename or removed field until `docs/schema-changes.md` carries a dated note. | report |

Until step 1 lands, `TypeRegistry` loads an empty placeholder and everything runs through the raw
store only. That is by design: the raw layer must round-trip with no schema at all (invariants 1, 2).

Prior art to read, never to copy (AGPL / MIT; docs/spec.md §17): WorkKit's `scripts/` and
`proto/` directories, keynote-parser's `protos/`.
