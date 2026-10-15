#!/usr/bin/env python3
"""Builds Tests/DeckMonkeyTests/Fixtures/synthetic-raw.key: a structurally valid iWork package
(zip form) whose archive records carry pseudo-random payloads. It exercises the container, the
chunk framing (chunks cut at arbitrary offsets, as the format allows) and the raw store — never
the typed layer, since the payloads are not real Keynote messages. No Keynote bytes involved.

Deterministic: the same script always writes the same bytes. Needs cramjam (see snappy-crosscheck.py).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iwa_synth as S  # noqa: E402

DOCUMENT_UUID = "6D1B9A3E-0000-4000-8000-DECC0DE00001"
BUILD = "M15.4-7051.0.79-2"


def build():
    rng = S.SplitMix64(0xDEC0)
    # Document.iwa: object 1 references 2 and 3; 2 references 3; 3 is a leaf with a big payload
    # so the component spans several arbitrarily cut chunks.
    doc = b"".join([
        S.record(1, 1, S.payload(rng, 200), refs=[2, 3]),
        S.record(2, 2, S.payload(rng, 120), refs=[3]),
        S.record(3, 10_000, S.payload(rng, 6_000)),
    ])
    # Metadata.iwa: one object, plus a merge record that has no base (Keynote writes these).
    meta = b"".join([
        S.record(11_006, 11_006, S.payload(rng, 80), refs=[1]),
        S.record(500, 3, S.payload(rng, 40), merge=True),
    ])
    entries = {
        "Index/Document.iwa": S.frame(doc, 1_000),
        "Index/Metadata.iwa": S.frame(meta, 100),
        "Metadata/Properties.plist": S.plist({
            "fileFormatVersion": "15.4",
            "revision": "1",
            "documentUUID": DOCUMENT_UUID,
        }),
        "Metadata/BuildVersionHistory.plist": S.plist([BUILD]),
        "Metadata/DocumentIdentifier": DOCUMENT_UUID.encode(),
    }
    return S.zip_entries(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    data = build()
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"{len(data)} bytes → {args.out}")


if __name__ == "__main__":
    main()
