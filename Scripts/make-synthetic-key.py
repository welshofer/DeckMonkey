#!/usr/bin/env python3
"""Builds Tests/DeckMonkeyTests/Fixtures/synthetic-raw.key: a structurally valid iWork package
(zip form) whose archive records carry pseudo-random payloads. It exercises the container, the
chunk framing (chunks cut at arbitrary offsets, as the format allows) and the raw store — never
the typed layer, since the payloads are not real Keynote messages. No Keynote bytes involved.

Deterministic: the same script always writes the same bytes. Needs cramjam (see snappy-crosscheck.py).
"""
import argparse
import io
import plistlib
import zipfile

import cramjam

MASK64 = (1 << 64) - 1


class SplitMix64:
    def __init__(self, seed):
        self.state = seed & MASK64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)


def varint(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field_varint(num, v):
    return varint(num << 3) + varint(v)


def field_bytes(num, data):
    return varint((num << 3) | 2) + varint(len(data)) + data


def packed(nums):
    return b"".join(varint(n) for n in nums)


def message_info(type_id, length, refs=(), data_refs=()):
    out = field_varint(1, type_id) + field_bytes(2, packed([2, 0, 0])) + field_varint(3, length)
    if refs:
        out += field_bytes(5, packed(refs))
    if data_refs:
        out += field_bytes(6, packed(data_refs))
    return out


def record(identifier, type_id, payload, refs=(), merge=False):
    info = field_varint(1, identifier) + field_bytes(2, message_info(type_id, len(payload), refs))
    if merge:
        info += field_varint(3, 1)
    return varint(len(info)) + info + payload


def payload(rng, size):
    # Plausible protobuf-ish bytes: a few varint fields then a length-delimited blob of noise.
    out = field_varint(1, rng.next() % 1000) + field_varint(2, rng.next() % 7)
    blob = bytes(rng.next() & 0xFF for _ in range(max(0, size - len(out) - 3)))
    return out + field_bytes(3, blob)


def frame(decompressed, chunk_size):
    out = bytearray()
    for start in range(0, max(1, len(decompressed)), chunk_size):
        body = bytes(cramjam.snappy.compress_raw(decompressed[start:start + chunk_size]))
        out += bytes([0, len(body) & 0xFF, (len(body) >> 8) & 0xFF, (len(body) >> 16) & 0xFF])
        out += body
    return bytes(out)


def build():
    rng = SplitMix64(0xDEC0)
    # Document.iwa: object 1 references 2 and 3; 2 references 3; 3 is a leaf with a big payload
    # so the component spans several arbitrarily cut chunks.
    doc = b"".join([
        record(1, 1, payload(rng, 200), refs=[2, 3]),
        record(2, 2, payload(rng, 120), refs=[3]),
        record(3, 10_000, payload(rng, 6_000)),
    ])
    # Metadata.iwa: one object, plus a merge record that has no base (Keynote writes these).
    meta = b"".join([
        record(11_006, 11_006, payload(rng, 80), refs=[1]),
        record(500, 3, payload(rng, 40), merge=True),
    ])
    components = {
        "Index/Document.iwa": frame(doc, 1_000),
        "Index/Metadata.iwa": frame(meta, 100),
    }
    properties = plistlib.dumps({
        "fileFormatVersion": "15.4",
        "revision": "1",
        "documentUUID": "6D1B9A3E-0000-4000-8000-DECC0DE00001",
    }, fmt=plistlib.FMT_XML)
    history = plistlib.dumps(["M15.4-7051.0.79-2"], fmt=plistlib.FMT_XML)
    entries = {
        "Metadata/Properties.plist": properties,
        "Metadata/BuildVersionHistory.plist": history,
        "Metadata/DocumentIdentifier": b"6D1B9A3E-0000-4000-8000-DECC0DE00001",
        **components,
    }
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            z.writestr(info, entries[name])
    return buf.getvalue()


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
