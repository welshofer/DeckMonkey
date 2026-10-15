#!/usr/bin/env python3
"""Builds Corpus/hostile/: deliberately broken copies of a source deck, one per validator rule
(docs/spec.md §11, AT-26), plus manifest.json naming the error each file must raise and the stage
at which it must raise it. The Swift test (DeckMonkeyTests/HostileCorpusTests) and `deckmonkey
verify` must both refuse every file here and write nothing.

    make-hostile-corpus.py --source Tests/DeckMonkeyTests/Fixtures/synthetic-raw.key --out Corpus/hostile

The source is a synthetic deck (no Keynote bytes); once Corpus/templates exists, pointing --source
at a Keynote-authored deck produces the same cases on real content. Deterministic for a given source.
Needs cramjam (see snappy-crosscheck.py).

Stages, as the Swift test applies them:
  open      KeynoteDocument.open must throw `expects`
  validate  open succeeds; validate() reports an issue of kind `expects` at severity error;
            save throws KeynoteError.validationFailed
  save      open succeeds and validates clean; save throws `expects`
`requires: "registry"` marks a case the raw store cannot judge until the pinned type registry is
populated (Phase 0 step 3); the test skips it while the registry is empty.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iwa_synth as S  # noqa: E402

MANIFEST_FORMAT = "deckmonkey-hostile/1"
NEWER_BUILD = "M16.0-8000.0.1-1"


def cases(source_entries):
    """Yields (file name, stage, expects, note, entries) for each hostile copy."""
    e = dict(source_entries)
    doc_name = next(n for n in sorted(e) if n.startswith("Index/") and n.endswith(".iwa"))
    other = [n for n in sorted(e) if n.startswith("Index/") and n.endswith(".iwa") and n != doc_name]
    meta_name = other[0] if other else doc_name
    doc_plain = S.deframe(e[doc_name])
    meta_plain = S.deframe(e[meta_name])
    rng = S.SplitMix64(0xBAD)

    # Identifiers already present, so the duplicate collides with a real base object.
    first_id, _ = S.read_varint(doc_plain, S.read_varint(doc_plain, 0)[1] + 1)

    def with_doc(plain):
        c = dict(e)
        c[doc_name] = S.frame(plain, 1_000)
        return c

    def with_meta_raw(iwa):
        c = dict(e)
        c[meta_name] = iwa
        return c

    def with_entry(name, data):
        c = dict(e)
        c[name] = data
        return c

    # --- validate stage: the raw store sees the problem, the validator must block the save ------
    yield ("duplicate-identifier.key", "validate", "ValidationIssue.duplicateIdentifier",
           f"a second non-merge record with identifier {first_id} appended to {doc_name}",
           with_doc(doc_plain + S.record(first_id, 2, S.payload(rng, 64))))
    yield ("dangling-reference.key", "validate", "ValidationIssue.danglingObjectReference",
           "a record whose object_references name identifier 999999, which no component defines",
           with_doc(doc_plain + S.record(777_001, 2, S.payload(rng, 64), refs=[999_999])))
    yield ("unknown-type.key", "validate", "ValidationIssue.unknownType",
           "a record of message type 999999, absent from every Keynote registry (needs the pinned registry)",
           with_doc(doc_plain + S.record(777_002, 999_999, S.payload(rng, 64))))

    # --- open stage: the container, framing, codec or archive reader must refuse ---------------
    yield ("truncated-chunk.key", "open", "IWAChunkingError.truncated",
           f"{doc_name} cut 10 bytes short, inside the last chunk's body",
           with_entry(doc_name, e[doc_name][:-10]))
    bad_header = bytearray(e[doc_name])
    bad_header[0] = 0x01
    yield ("bad-chunk-header.key", "open", "IWAChunkingError.invalidHeader",
           f"first chunk header byte of {doc_name} is 0x01 instead of 0x00",
           with_entry(doc_name, bytes(bad_header)))
    yield ("corrupt-snappy-copy.key", "open", "SnappyError.invalidCopy",
           f"{meta_name} is one chunk whose Snappy block copies from before the start of the output",
           with_meta_raw(S.frame_body(bytes([0x04, 0x15, 0x09]))))
    yield ("corrupt-snappy-length.key", "open", "SnappyError.lengthMismatch",
           f"{meta_name} is one chunk whose Snappy preamble promises 4 bytes but the block yields 3",
           with_meta_raw(S.frame_body(bytes([0x04, 0x08, 0x61, 0x62, 0x63]))))
    yield ("truncated-record.key", "open", "ArchiveStreamError.truncated",
           f"the decompressed stream of {doc_name} ends 20 bytes into the last record's payload",
           with_doc(doc_plain[:-20]))
    yield ("header-too-long.key", "open", "ArchiveStreamError.headerTooLong",
           f"{meta_name} begins with a record whose header length (1000) exceeds the stream",
           with_meta_raw(S.frame(S.varint(1000) + b"\x08\x01", 1_000)))
    headless_payload = b"\x08\x01\x10\x02\x18\x03\x20\x04"
    headless = S.archive_info(None, [S.message_info(2, len(headless_payload))])
    yield ("missing-identifier.key", "open", "ArchiveInfoError.missingIdentifier",
           f"a record appended to {meta_name} whose ArchiveInfo has no identifier (field 1)",
           with_meta_raw(S.frame(meta_plain + S.varint(len(headless)) + headless + headless_payload, 1_000)))
    yield ("legacy-apxl.key", "open", "IWAPackageError.unsupportedLegacyFormat",
           "Keynote '09 layout: index.apxl at the root, no Index/",
           {"index.apxl": b'<?xml version="1.0"?>\n<key:presentation xmlns:key="http://developer.apple.com/namespaces/keynote2" key:version="92008102400"/>\n',
            "thumbs/st0.tiff": b"II*\x00\x08\x00\x00\x00\x00\x00"})
    yield ("no-index.key", "open", "IWAPackageError.notAnIWorkPackage",
           "a zip with Metadata/ but no Index/ components",
           {n: e[n] for n in e if n.startswith("Metadata/")})
    yield ("not-a-zip.key", "open", "IWAPackageError.notAZip",
           "4096 bytes that are neither a zip nor a package directory",
           None)   # raw bytes, written as-is below

    # --- save stage: opens and validates, but is read-only for this library -------------------
    newer = dict(e)
    history = [NEWER_BUILD]
    newer["Metadata/BuildVersionHistory.plist"] = S.plist(history)
    yield ("newer-keynote.key", "save", "KeynoteError.schemaNewerThanLibrary",
           f"BuildVersionHistory ends with {NEWER_BUILD}, newer than the pinned 15.4 schema (AT-25)",
           newer)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", required=True, help="a .key in zip form to break copies of")
    parser.add_argument("--out", required=True, help="directory to fill (Corpus/hostile)")
    args = parser.parse_args()
    with open(args.source, "rb") as f:
        source = S.read_zip(f.read())
    os.makedirs(args.out, exist_ok=True)
    files = []
    for name, stage, expects, note, entries in cases(source):
        if entries is None:
            rng = S.SplitMix64(0xB0D)
            data = bytes(rng.next() & 0xFF for _ in range(4096))
        else:
            data = S.zip_entries(entries)
        with open(os.path.join(args.out, name), "wb") as f:
            f.write(data)
        entry = {"file": name, "stage": stage, "expects": expects, "note": note}
        if expects == "ValidationIssue.unknownType":
            entry["requires"] = "registry"
        files.append(entry)
        print(f"  {name:28} {stage:9} {expects}")
    manifest = {
        "format": MANIFEST_FORMAT,
        "source": os.path.relpath(args.source, os.getcwd()),
        "generator": "Scripts/make-hostile-corpus.py",
        "files": files,
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    print(f"{len(files)} hostile files → {args.out}/")


if __name__ == "__main__":
    main()
