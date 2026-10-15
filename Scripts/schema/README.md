# Schema pipeline (docs/spec.md §7)

Nothing in `Sources/IWASchema` is hand-written. `make schema` runs these steps against the
installed Keynote (found by bundle id, `Scripts/keynote-app.sh`; it refuses any build but the pin)
and writes the result under a version directory. Pinned for Phase 0: **Keynote 15.4 (7051.0.79)**.
The pipeline is deterministic: a re-run on the same Keynote leaves git clean.

| Step | Tool | Output |
| --- | --- | --- |
| 1 Extract | `protodump extract` scans the main executable and every embedded framework for serialized `FileDescriptorProto`s: find `.proto` suffixes, step back over the name to its length and the `0x0A` tag, walk the wire format while tags stay valid for `FileDescriptorProto`, keep what decodes and carries the name it was found by. The same file in two binaries must be byte-identical; every import must be found. 34 files in 15.4, across 10 binaries. | `proto/15.4/descriptors.pb` (a `FileDescriptorSet` in dependency order) |
| 2 Render | `Render.swift` turns each descriptor back into `.proto` source (`-` in identifiers → `_`; `required` kept). For people and `schema-diff` only: generation never reads it. | `proto/15.4/*.proto` |
| 3 Generate | `protodump generate` hands the descriptors straight to `protoc-gen-swift` as a `CodeGeneratorRequest` (`Visibility=Public`): no `protoc`, no `.proto` parsing. It fills `json_name` the way protoc does, since embedded descriptors lack it. `protoc-gen-swift` is built from the exact swift-protobuf the library resolves. | `Sources/IWASchema/Generated/15.4/*.pb.swift` |
| 4 Registry | `registry-dump.py` reads `TSPRegistry`'s registration calls out of the arm64 disassembly (see below). | `Sources/IWASchema/Registry/registry-15.4.json` |
| 5 Dispatch | `protodump dispatch` emits the type-number switch and the union of every file's extension map. Swift names come from `SwiftProtobufNamer`, the namer protoc-gen-swift itself uses. | `Sources/IWASchema/Generated/15.4/Dispatch.swift` |
| 6 Diff | `make schema-diff` re-extracts into a scratch directory and diffs descriptors, rendered protos and registry against the pinned tree. A difference means a new Keynote: new `SCHEMA_VERSION`, dated note in `docs/schema-changes.md`. | report, exit code |

## The registry, statically

Keynote fills `TSPRegistry` at launch from one `<Prefix>RegisterPersistentClasses` function per
framework plus `-[TSPRegistry registerPersistenceMessages]`. The dynamic route (Frida, lldb) is
closed on a stock Mac: Keynote is hardened-runtime with library validation and no
`get-task-allow`, and SIP is on. So `registry-dump.py` reads the calls instead. Each registration
compiles to the same shape:

```
bl   <X::default_instance()>                    ; x3: prototype (symbol often stripped)
ldr  x8, [xT, #0x58]                            ; xT = &descriptor_table_F → file_level_metadata
ldr  x4, [x8, #16*i]                            ; x4: descriptor of F's i-th message
mov  w2, #<type>                                ; or a uint32 constant loaded from memory
bl   <objc stub: setMessageType:messagePrototype:descriptor:unarchiveClassname:>
```

The message is identified the way Keynote identifies it, by descriptor: the table names its own
file (a `const char*` at `+0x10`, so stripped table symbols do not matter), and protobuf lays out
`file_level_metadata` as the file's messages in **post-order** (nested before parent), 16 bytes
each. Two independent cross-checks run on every extraction: each table's `default_instances` array
(at `+0x48`, same order) must match the flattening wherever a `_<Message>_default_instance_`
symbol survives (1,038 slots in 15.4), and each call site's prototype symbol, where it survives,
must name the descriptor's message (411 call sites). A table may compile fewer messages than its
descriptor declares (TSKArchives: 47 of 49), only ever at the end. Objc stubs resolve to selectors
through `__objc_stubs` → `__objc_selrefs` (chained-fixup target) → `__objc_methname`.

Nothing is guessed: an untraceable type or descriptor, a symbol that disagrees, or one type
registered to two messages by the same kind of call fails the run. Result for 15.4: 625 types,
101 declared deprecated, 11 upgrade-only class mappings. AT-05 (every corpus type resolves, as a
message or as declared deprecated) is the completeness check.

Prior art read, never copied (AGPL / MIT; docs/spec.md §17): WorkKit's `scripts/` and `proto/`,
keynote-parser's `protos/`. Neither informed the static registry method above.
