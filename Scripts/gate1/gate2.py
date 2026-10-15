#!/usr/bin/env python3
"""gate2.py — Gate 2 (docs/spec.md §12, AT-18 and AT-19): image replace cases through the oracle.

usage: Scripts/gate1/gate2.py [cases.tsv ...] [--work DIR]
       (default: Scripts/gate1/images.tsv, plus Scripts/gate1/images.local.tsv when present)

Each case: deck, image (an object identifier, or "page:N" for the first image on page N), the
replacement (one of the generated test images: stripes.png, stripes.jpg, stripes.gif, stripes.tiff,
tall.png, wide.jpg), kind. A case passes when `deckmonkey image` succeeds; the new DataInfo's
digest is the SHA-1 of the file and the image points at it (AT-18); no DataInfo is unreferenced
and no Data/ file undescribed (AT-19); Keynote opens the output with no sheet and no persistence
errors and the same page count; and every changed page is the image's page, the change inside the
image's frame (clipped to the page) plus a margin. AT-27 (the iPad oracle) is not run here.
Needs macOS and Keynote; run from the repo root, with the machine left alone.
"""
import hashlib, json, os, struct, subprocess, sys, tempfile, zipfile, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate1 import MARGIN, corpus_root, oracle, run  # noqa: E402


def png(path, w, h, pixel):
    raw = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def assets(d):
    png(f"{d}/stripes.png", 320, 240, lambda x, y: (220, 40, 40) if (x // 20) % 2 else (40, 40, 220))
    png(f"{d}/tall.png", 300, 900, lambda x, y: (40, 160, 60) if (y // 50) % 2 else (240, 220, 40))
    png(f"{d}/wide-src.png", 1200, 300, lambda x, y: ((x * 255) // 1199, 80, 200))
    for fmt, src, out in [("jpeg", "stripes.png", "stripes.jpg"), ("gif", "stripes.png", "stripes.gif"),
                          ("tiff", "stripes.png", "stripes.tiff"), ("jpeg", "wide-src.png", "wide.jpg")]:
        run("sips", "-s", "format", fmt, f"{d}/{src}", "--out", f"{d}/{out}")


def painted_box(at):
    """Where an image can paint: its frame, extended downward by its height for a reflection (drawn
    directly below the image), rotated about the frame's centre, plus a margin (more for a shadow or
    stroke). Axis-aligned, in page points."""
    import math
    f = at["frame"]
    if f is None: return None
    w, h = f["width"], f["height"] * (2 if at.get("reflection") else 1)
    cx, cy = f["x"] + f["width"] / 2, f["y"] + f["height"] / 2
    corners = [(f["x"], f["y"]), (f["x"] + w, f["y"]), (f["x"], f["y"] + h), (f["x"] + w, f["y"] + h)]
    a = math.radians(f["angle"])
    pts = [(cx + (x - cx) * math.cos(a) - (y - cy) * math.sin(a), cy + (x - cx) * math.sin(a) + (y - cy) * math.cos(a)) for x, y in corners]
    m = MARGIN + (40 if at.get("shadow") or at.get("stroke") else 0)
    return (min(p[0] for p in pts) - m, min(p[1] for p in pts) - m, max(p[0] for p in pts) + m, max(p[1] for p in pts) + m)


def data_listing(dm, deck):
    rows = []
    for line in run(dm, "data", deck).stdout.splitlines():
        cols = line.split("\t")
        rows.append(cols)
    return rows


def main():
    args = sys.argv[1:]
    work = tempfile.mkdtemp(prefix="deckmonkey-gate2.")
    if "--work" in args:
        i = args.index("--work"); work = args[i + 1]; del args[i:i + 2]
        os.makedirs(work, exist_ok=True)
    files = args or ["Scripts/gate1/images.tsv"] + (["Scripts/gate1/images.local.tsv"] if os.path.exists("Scripts/gate1/images.local.tsv") else [])
    cases = []
    for f in files:
        for line in open(f, encoding="utf-8"):
            if line.strip() and not line.startswith("#"):
                cases.append(line.rstrip("\n").split("\t"))
    assets(work)
    root = corpus_root()
    dm = ".build/debug/deckmonkey"
    goldens, passed = {}, 0
    for n, (deck, target, image, kind) in enumerate(cases, 1):
        label = f"{n:2} {kind:5} {os.path.basename(deck)}: {target} ← {image}"
        try:
            if deck.startswith("corpus:"):
                if not root: raise RuntimeError("no private corpus configured")
                deck = os.path.join(root, deck[len("corpus:"):])
            if target.startswith("page:"):
                page = target.split(":")[1]
                rows = [l.split("\t") for l in run(dm, "image", deck, "--list").stdout.splitlines()]
                ids = [r[0] for r in rows if r[2] == f"page {page}"]
                if not ids: raise RuntimeError(f"no image on page {page}")
                target = ids[0]
            src = os.path.join(work, image)
            out = os.path.join(work, f"case{n}.key")
            r = run(dm, "image", deck, "--object", target, "--with", src, "-o", out)
            new_name = r.stdout.split("Data/", 1)[1].split(" ")[0]
            # AT-18: the digest is the SHA-1 of the bytes we gave, stored under the new name.
            sha1 = hashlib.sha1(open(src, "rb").read()).hexdigest()
            rows = data_listing(dm, out)
            mine = [c for c in rows if len(c) > 1 and c[1] == new_name]
            if not mine or f"digest {sha1}" not in mine[0][3]: raise RuntimeError(f"AT-18: no DataInfo for {new_name} with digest {sha1}")
            if f"referrers {target}" not in mine[0][5] and target not in mine[0][5]: raise RuntimeError(f"AT-18: {new_name} is not referred to by image {target}")
            # AT-19: nothing unreferenced, nothing undescribed.
            orphans = [c[0] for c in rows if len(c) > 5 and c[5] == "referrers none"]
            undescribed = [c[1] for c in rows if c[0] == "UNDESCRIBED"]
            if orphans or undescribed: raise RuntimeError(f"AT-19: unreferenced {orphans} undescribed {undescribed}")
            golden = deck[:-4] + ".golden.pdf"
            if not os.path.exists(golden):
                if deck not in goldens:
                    v = oracle(deck, os.path.join(work, f"golden{n}"))
                    if not v["pass"]: raise RuntimeError(f"the original does not pass the oracle: {v}")
                    goldens[deck] = v["pdf"]
                golden = goldens[deck]
            v = oracle(out, os.path.join(work, f"oracle{n}"), golden)
            if not v["opens"] or v["sheet"] is not None or v["logHits"] != 0 or not v["pdf"]:
                raise RuntimeError(f"oracle: opens={v['opens']} sheet={v['sheet']} logHits={v['logHits']}")
            diff = json.loads(run("swift", "Scripts/pdfdiff.swift", golden, v["pdf"]).stdout)
            if diff["pages"][0] != diff["pages"][1]: raise RuntimeError(f"page count {diff['pages']}")
            at = json.loads(run(dm, "locate", out, "--object", target).stdout)
            box = painted_box(at)
            for page, x0, y0, x1, y1 in diff["pageBounds"]:
                if page != at["page"]: raise RuntimeError(f"page {page} changed; the image is on page {at['page']}")
                if box is not None and (x0 < box[0] or y0 < box[1] or x1 > box[2] or y1 > box[3]):
                    raise RuntimeError(f"change {x0},{y0}–{x1},{y1} outside the image's painted box {[round(v) for v in box]}")
            print(f"PASS {label}  (Data/{new_name}, {len(diff['pageBounds'])} page(s) changed, {diff['mismatch']} px)")
            passed += 1
        except Exception as e:
            print(f"FAIL {label}  {e}")
        sys.stdout.flush()
    print(f"gate2: {passed}/{len(cases)} pass (work: {work})")
    sys.exit(0 if passed == len(cases) else 1)


if __name__ == "__main__":
    main()
