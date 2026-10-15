"""Shared helpers for building synthetic IWA archives in Python: protobuf wire encoding,
`TSP.ArchiveInfo` / `TSP.MessageInfo` headers, Apple's chunk framing, and a deterministic RNG.

Used by make-synthetic-key.py and make-hostile-corpus.py. Nothing here reads or writes Keynote
bytes; it mirrors the format as documented in docs/spec.md §4 and confirmed from the corpus.
Needs cramjam for the Snappy blocks (see snappy-crosscheck.py).
"""
import io
import plistlib
import zipfile

import cramjam

MASK64 = (1 << 64) - 1


class SplitMix64:
    """Same generator as IWASnappyTests / DeckMonkeyTests, so fixtures are reproducible."""

    def __init__(self, seed):
        self.state = seed & MASK64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)


# --- protobuf wire format ----------------------------------------------------------------------

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


def read_varint(data, pos):
    shift = 0
    value = 0
    while True:
        b = data[pos]
        pos += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, pos
        shift += 7


def field_varint(num, v):
    return varint(num << 3) + varint(v)


def field_bytes(num, data):
    return varint((num << 3) | 2) + varint(len(data)) + data


def packed(nums):
    return b"".join(varint(n) for n in nums)


# --- TSP.MessageInfo / TSP.ArchiveInfo ---------------------------------------------------------

def message_info(type_id, length, refs=(), data_refs=(), version=(2, 0, 0)):
    out = field_varint(1, type_id) + field_bytes(2, packed(version)) + field_varint(3, length)
    if refs:
        out += field_bytes(5, packed(refs))
    if data_refs:
        out += field_bytes(6, packed(data_refs))
    return out


def archive_info(identifier, infos, merge=False):
    """`identifier=None` omits field 1 (a hostile header)."""
    out = b""
    if identifier is not None:
        out += field_varint(1, identifier)
    for info in infos:
        out += field_bytes(2, info)
    if merge:
        out += field_varint(3, 1)
    return out


def record(identifier, type_id, payload, refs=(), merge=False):
    info = archive_info(identifier, [message_info(type_id, len(payload), refs)], merge)
    return varint(len(info)) + info + payload


def payload(rng, size):
    """Plausible protobuf-ish bytes: two varint fields then a length-delimited blob of noise."""
    out = field_varint(1, rng.next() % 1000) + field_varint(2, rng.next() % 7)
    blob = bytes(rng.next() & 0xFF for _ in range(max(0, size - len(out) - 3)))
    return out + field_bytes(3, blob)


# --- Apple's .iwa chunk framing ---------------------------------------------------------------

def frame_body(body):
    """One chunk: 0x00, 24-bit little-endian compressed length, raw Snappy block."""
    return bytes([0, len(body) & 0xFF, (len(body) >> 8) & 0xFF, (len(body) >> 16) & 0xFF]) + body


def frame(decompressed, chunk_size):
    out = bytearray()
    for start in range(0, max(1, len(decompressed)), chunk_size):
        out += frame_body(bytes(cramjam.snappy.compress_raw(decompressed[start:start + chunk_size])))
    return bytes(out)


def split_chunks(iwa):
    pos = 0
    while pos < len(iwa):
        if iwa[pos] != 0:
            raise ValueError(f"chunk header byte {iwa[pos]:#x} at {pos}")
        length = iwa[pos + 1] | (iwa[pos + 2] << 8) | (iwa[pos + 3] << 16)
        pos += 4
        yield iwa[pos:pos + length]
        pos += length


def deframe(iwa):
    return b"".join(bytes(cramjam.snappy.decompress_raw(body)) for body in split_chunks(iwa))


# --- container ------------------------------------------------------------------------------

def plist(obj):
    return plistlib.dumps(obj, fmt=plistlib.FMT_XML)


def zip_entries(entries):
    """A deterministic STORED zip of {name: bytes}, entries sorted by name."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            z.writestr(info, entries[name])
    return buf.getvalue()


def read_zip(data):
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        return {i.filename: z.read(i) for i in z.infolist() if not i.is_dir()}
