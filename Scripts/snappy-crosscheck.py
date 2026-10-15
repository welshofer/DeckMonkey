#!/usr/bin/env python3
"""AT-01: cross-check DeckMonkey's Snappy codec against a reference implementation.

The reference is cramjam (Rust `snap`, format-identical to Google's Snappy, which is what Keynote
links). This script is the only place the reference runs; everything the Swift side needs from it
is cached as SHA-256 hashes and reference-compressed vectors, so the Swift tests and `deckmonkey
snappy-check` never need Python at test time.

    vectors --out FILE          regenerate Tests/DeckMonkeyTests/Fixtures/snappy-vectors.json
    hash DECK... --out FILE     reference manifest for decks (or directories of decks): per
                                component, per chunk, the SHA-256 of the reference decode
    verify-ours DIR             decode DeckMonkey-compressed .iwa files (written by
                                `deckmonkey snappy-check --emit DIR`) with the reference decoder
    verify-vectors FILE         decode DeckMonkey's compression of each vector (written by the
                                Swift test to .build/snappy-vectors-ours.json) with the reference

Setup: python3 -m venv .venv && .venv/bin/pip install cramjam   (or `make .venv/bin/python`).
No deck bytes are written anywhere by this script: the hash manifest holds names and hashes only.
"""
import argparse
import base64
import hashlib
import io
import json
import os
import sys
import zipfile

try:
    import cramjam
except ImportError:  # pragma: no cover
    sys.exit("snappy-crosscheck.py needs cramjam: python3 -m venv .venv && .venv/bin/pip install cramjam")

MANIFEST_FORMAT = "deckmonkey-snappy-reference/1"
VECTORS_FORMAT = "deckmonkey-snappy-vectors/1"
REFERENCE = f"cramjam {cramjam.__version__} (snap)"
MASK64 = (1 << 64) - 1


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ref_compress(data: bytes) -> bytes:
    return bytes(cramjam.snappy.compress_raw(data))


def ref_decompress(data: bytes) -> bytes:
    return bytes(cramjam.snappy.decompress_raw(data))


# --- deterministic inputs (mirrored by Tests/DeckMonkeyTests/SnappyReferenceTests.swift) --------

class SplitMix64:
    def __init__(self, seed: int):
        self.state = seed & MASK64

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)


def gen_input(spec: dict) -> bytes:
    kind = spec["kind"]
    n = spec.get("length", 0)
    if kind == "bytes":
        return base64.b64decode(spec["b64"])
    if kind == "repeat":
        pattern = base64.b64decode(spec["pattern_b64"])
        return (pattern * (n // len(pattern) + 1))[:n]
    if kind == "period":
        period, multiplier = spec["period"], spec["multiplier"]
        return bytes(((i % period) * multiplier) & 0xFF for i in range(n))
    rng = SplitMix64(spec["seed"])
    if kind == "random":
        return bytes(rng.next() & 0xFF for _ in range(n))
    if kind == "mixed":
        out = bytearray()
        while len(out) < n:
            run = rng.next() % 64 + 1
            byte = rng.next() & 0xFF
            out += bytes([byte]) * min(run, n - len(out))
            if len(out) < n and rng.next() % 4 == 0:
                out.append(rng.next() & 0xFF)
        return bytes(out)
    raise ValueError(f"unknown input kind {kind}")


def vector_specs():
    def b(name, data):
        return name, {"kind": "bytes", "b64": base64.b64encode(data).decode()}

    def rep(name, pattern, length):
        return name, {"kind": "repeat", "pattern_b64": base64.b64encode(pattern).decode(), "length": length}

    def rnd(name, seed, length):
        return name, {"kind": "random", "seed": seed, "length": length}

    def mixed(name, seed, length):
        return name, {"kind": "mixed", "seed": seed, "length": length}

    def period(name, p, multiplier, length):
        return name, {"kind": "period", "period": p, "multiplier": multiplier, "length": length}

    phrase = b"Keynote keeps its presentations in Snappy-chunked protobufs. "
    specs = [
        b("empty", b""),
        b("one-byte", b"K"),
        b("abc-x4", b"abcabcabcabc"),
        b("all-byte-values", bytes(range(256))),
        b("all-byte-values-x3", bytes(range(256)) * 3),
        rnd("random-60", 60, 60),            # 1-byte literal tag (len-1 < 60)
        rnd("random-61", 61, 61),            # literal length needs 1 extra byte
        rnd("random-62", 62, 62),
        rnd("random-255", 255, 255),
        rnd("random-256", 256, 256),         # 1 extra byte → 2 extra bytes
        rnd("random-257", 257, 257),
        rnd("random-4096", 4096, 4096),
        rnd("random-65537", 65537, 65537),   # 3 extra bytes; crosses the 64 KiB block
        rep("run-zero-100000", b"\x00", 100_000),           # offset-1 copies, max length chains
        rep("run-ff-70000", b"\xff", 70_000),
        rep("period-2", b"ab", 5_000),
        rep("period-4", b"abcd", 5_000),
        rep("period-8", b"abcdefgh", 5_000),
        rep("period-9", b"abcdefghi", 5_000),
        rep("period-11", b"abcdefghijk", 5_000),
        rep("period-12", b"abcdefghijkl", 5_000),
        rep("phrase", phrase, 10_000),
        rep("phrase-300001", phrase, 300_001),             # many blocks of highly compressible text
        period("period-2047", 2047, 7, 20_000),      # 1-byte-offset copies end at offset 2047
        period("period-2048", 2048, 7, 20_000),      # first 2-byte offsets
        period("period-2049", 2049, 7, 20_000),
        period("period-65535", 65_535, 13, 140_000),  # largest 2-byte offset
        period("period-65536", 65_536, 13, 140_000),  # no match within a block
        mixed("mixed-1000", 1000, 1_000),
        mixed("mixed-65535", 65535, 65_535),
        mixed("mixed-65536", 65536, 65_536),
        mixed("mixed-65537", 65537, 65_537),
        mixed("mixed-131072", 131072, 131_072),
    ]
    return specs


def cmd_vectors(args):
    vectors = []
    for name, spec in vector_specs():
        data = gen_input(spec)
        compressed = ref_compress(data)
        assert ref_decompress(compressed) == data
        vectors.append({
            "name": name,
            "input": spec,
            "input_sha256": sha256(data),
            "reference_b64": base64.b64encode(compressed).decode(),
        })
    doc = {"format": VECTORS_FORMAT, "reference": REFERENCE, "vectors": vectors}
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    total = sum(len(base64.b64decode(v["reference_b64"])) for v in vectors)
    print(f"{len(vectors)} vectors, {total} reference-compressed bytes → {args.out}")


# --- decks ---------------------------------------------------------------------------------------

def split_chunks(iwa: bytes):
    pos = 0
    while pos < len(iwa):
        if pos + 4 > len(iwa):
            raise ValueError(f"truncated chunk header at {pos}")
        if iwa[pos] != 0:
            raise ValueError(f"chunk header byte {iwa[pos]:#x} at {pos}, expected 0")
        length = iwa[pos + 1] | (iwa[pos + 2] << 8) | (iwa[pos + 3] << 16)
        pos += 4
        if pos + length > len(iwa):
            raise ValueError(f"truncated chunk body at {pos}")
        yield iwa[pos:pos + length]
        pos += length


def read_package(path: str):
    """Returns (components {name: bytes}, note) for a .key zip or package directory."""
    entries = {}
    if os.path.isdir(path):
        for root, _dirs, files in os.walk(path):
            for name in files:
                full = os.path.join(root, name)
                rel = os.path.relpath(full, path).replace(os.sep, "/")
                if rel.startswith("Index/") or rel == "Index.zip" or rel.lower().startswith("index.apxl"):
                    with open(full, "rb") as f:
                        entries[rel] = f.read()
    else:
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                if info.is_dir():
                    continue
                if info.filename.startswith("Index/") or info.filename == "Index.zip" or info.filename.lower().startswith("index.apxl"):
                    entries[info.filename] = z.read(info)
    if any(k.lower().startswith("index.apxl") for k in entries):
        return None, "legacy"
    if "Index.zip" in entries:
        with zipfile.ZipFile(io.BytesIO(entries.pop("Index.zip"))) as inner:
            for info in inner.infolist():
                if info.is_dir():
                    continue
                flat = info.filename if info.filename.startswith("Index/") else "Index/" + info.filename
                entries[flat] = inner.read(info)
    components = {k: v for k, v in entries.items() if k.startswith("Index/") and k.endswith(".iwa")}
    if not components:
        return None, "not-an-iwork-package"
    return components, None


def find_decks(paths):
    for p in paths:
        if p.lower().endswith(".key"):
            yield p
        elif os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                keep = []
                for d in sorted(dirs):
                    if d.lower().endswith(".key"):
                        yield os.path.join(root, d)      # package directory: do not descend
                    else:
                        keep.append(d)
                dirs[:] = keep
                for f in sorted(files):
                    if f.lower().endswith(".key"):
                        yield os.path.join(root, f)


def cmd_hash(args):
    out_dir = os.path.dirname(os.path.abspath(args.out)) or "."
    decks = []
    chunk_total = 0
    for deck in sorted(set(find_decks(args.decks))):
        rel = os.path.relpath(os.path.abspath(deck), out_dir)
        components, note = read_package(deck)
        if note:
            decks.append({"path": rel, "skipped": note})
            print(f"  {deck}: skipped ({note})")
            continue
        comps = []
        for name in sorted(components):
            iwa = components[name]
            chunk_hashes = []
            whole = hashlib.sha256()
            for body in split_chunks(iwa):
                plain = ref_decompress(body)
                chunk_hashes.append(sha256(plain))
                whole.update(plain)
            comps.append({
                "name": name,
                "chunks": len(chunk_hashes),
                "compressed_sha256": sha256(iwa),
                "decompressed_sha256": whole.hexdigest(),
                "chunk_sha256": chunk_hashes,
            })
            chunk_total += len(chunk_hashes)
        decks.append({"path": rel, "components": comps})
        print(f"  {deck}: {len(comps)} components, {sum(c['chunks'] for c in comps)} chunks")
    doc = {"format": MANIFEST_FORMAT, "reference": REFERENCE, "decks": decks}
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    hashed = sum(1 for d in decks if "components" in d)
    print(f"{hashed} deck(s) hashed, {len(decks) - hashed} skipped, {chunk_total} chunks → {args.out}")


def cmd_verify_ours(args):
    with open(os.path.join(args.dir, "manifest.json")) as f:
        manifest = json.load(f)
    failures = 0
    for item in manifest["items"]:
        with open(os.path.join(args.dir, item["file"]), "rb") as f:
            iwa = f.read()
        whole = hashlib.sha256()
        try:
            for body in split_chunks(iwa):
                whole.update(ref_decompress(body))
        except Exception as e:  # noqa: BLE001 — any reference-decoder rejection is a failure
            failures += 1
            print(f"FAIL {item['file']}: reference decoder rejected our output: {e}")
            continue
        if whole.hexdigest() != item["decompressed_sha256"]:
            failures += 1
            print(f"FAIL {item['file']}: reference decode of our output differs from the original")
    n = len(manifest["items"])
    print(f"verify-ours: {n - failures}/{n} DeckMonkey-compressed components decode identically with the reference")
    sys.exit(1 if failures else 0)


def cmd_verify_vectors(args):
    with open(args.file) as f:
        ours = json.load(f)
    fixture = ours.get("fixture") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "DeckMonkeyTests", "Fixtures", "snappy-vectors.json")
    with open(fixture) as f:
        vectors = {v["name"]: v for v in json.load(f)["vectors"]}
    failures = 0
    for item in ours["items"]:
        spec = vectors.get(item["name"])
        if spec is None:
            failures += 1
            print(f"FAIL {item['name']}: not in the fixture")
            continue
        expected = gen_input(spec["input"])
        try:
            plain = ref_decompress(base64.b64decode(item["ours_b64"]))
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"FAIL {item['name']}: reference decoder rejected our output: {e}")
            continue
        if plain != expected:
            failures += 1
            print(f"FAIL {item['name']}: reference decode of our output differs ({len(plain)} vs {len(expected)} bytes)")
    n = len(ours["items"])
    print(f"verify-vectors: {n - failures}/{n} DeckMonkey-compressed vectors decode identically with the reference")
    sys.exit(1 if failures else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("vectors")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_vectors)
    p = sub.add_parser("hash")
    p.add_argument("decks", nargs="+")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_hash)
    p = sub.add_parser("verify-ours")
    p.add_argument("dir")
    p.set_defaults(func=cmd_verify_ours)
    p = sub.add_parser("verify-vectors")
    p.add_argument("file")
    p.set_defaults(func=cmd_verify_vectors)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
