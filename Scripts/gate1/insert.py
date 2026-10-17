#!/usr/bin/env python3
"""insert.py — new text boxes and pictures from DeckMonkey's parts, against Keynote inserting them.

usage: Scripts/gate1/insert.py [template.key ...] [--work DIR]

For each template, on slide 1 (0-based), Keynote makes a text item ("Inserted by DeckMonkey", width
600, its vertical centre at y 540, left edge 160) and a picture (a generated 256 × 256 PNG at
900,300, 400 × 400) through AppleScript and saves the golden; DeckMonkey inserts the same through
`deckmonkey insert`, from the bundled parts. The case passes when the validator passes, Keynote
opens DeckMonkey's file with no sheet and no persistence errors, every page is pixel-identical to
the golden's, and Keynote's re-save keeps the object histogram (AT-23). AppleScript stores a text
item's position as given plus half its height, so the golden places its top at the whole point
nearest the requested centre minus half the height Keynote computed, and DeckMonkey inserts at the
centre that gives. Needs macOS and Keynote; run with the machine left alone.
"""
import json, os, shutil, struct, subprocess, sys, tempfile, uuid, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate1 import oracle, run  # noqa: E402

TEXT, X, YC, W = "Inserted by DeckMonkey", 160, 540, 600
IMAGE = (900, 300, 400, 400)

GOLDEN = '''on run argv
  set f to POSIX file (item 1 of argv)
  set token to item 2 of argv
  set out to POSIX file (item 3 of argv)
  set pic to POSIX file (item 4 of argv)
  with timeout of 300 seconds
    tell application id "com.apple.Keynote"
      open f
      repeat 120 times
        if (count of (every document whose name contains token)) > 0 then exit repeat
        delay 0.5
      end repeat
      set d to first document whose name contains token
      try
        set s to slide 2 of d
        tell s to set t to make new text item with properties {object text:"%s"}
        set width of t to %d
        set h to height of t
        set p to round (%d - h / 2) rounding down
        set position of t to {%d, p}
        set centre to p + h / 2
        tell s to set i to make new image with properties {file:pic}
        set width of i to %d
        set height of i to %d
        set position of i to {%d, %d}
        save d in out
      on error message
        close (every document whose name contains token) saving no
        error message
      end try
      close (every document whose name contains token) saving no
    end tell
  end timeout
  return "saved " & centre
end run''' % (TEXT, W, YC, X, IMAGE[2], IMAGE[3], IMAGE[0], IMAGE[1])


def png(path, size=256):
    raw = b"".join(b"\x00" + b"".join(bytes(((x * 255) // (size - 1), (y * 255) // (size - 1), 128)) for x in range(size)) for y in range(size))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def golden(template, picture, out):
    token = "oracle-" + uuid.uuid4().hex[:8]
    work = tempfile.mkdtemp(prefix="deckmonkey-insert.")
    copy = os.path.join(work, f"{token}-deck.key")
    shutil.copytree(template, copy) if os.path.isdir(template) else shutil.copy(template, copy)
    saved = os.path.join(work, f"{token}-golden.key")
    r = subprocess.run(["osascript", "-", copy, token, saved, picture], input=GOLDEN, capture_output=True, text=True)
    if not r.stdout.strip().startswith("saved") or not os.path.exists(saved):
        raise RuntimeError(f"Keynote did not build the golden: {r.stderr.strip() or r.stdout.strip()}")
    shutil.move(saved, out)
    return r.stdout.strip().split()[1]


def main():
    args = sys.argv[1:]
    work = tempfile.mkdtemp(prefix="deckmonkey-insert.")
    if "--work" in args:
        i = args.index("--work"); work = args[i + 1]; del args[i:i + 2]
        os.makedirs(work, exist_ok=True)
    templates = args or [f"Corpus/templates/{t}.key" for t in ("basic-white_wide", "kyoto_wide", "chalkboard_wide", "academy_standard")]
    picture = os.path.join(work, "picture.png")
    png(picture)
    dm, passed = ".build/debug/deckmonkey", 0
    for n, template in enumerate(templates, 1):
        label = f"{n:2} {os.path.basename(template)}: a text box and a picture on slide 1"
        try:
            golden_deck = os.path.join(work, f"golden{n}.key")
            centre = golden(template, picture, golden_deck)
            out = os.path.join(work, f"case{n}.key")
            run(dm, "insert", template, "--slide", "1", "--text", TEXT, "--frame", f"{X},{centre},{W},0", "-o", out)
            run(dm, "insert", out, "--slide", "1", "--image", picture, "--frame", ",".join(map(str, IMAGE)), "-o", out)
            if "FAIL" in run(dm, "verify", out, check=False).stdout: raise RuntimeError("validator fails on the output")
            gv = oracle(golden_deck, os.path.join(work, f"golden{n}"))
            if not gv["pass"]: raise RuntimeError(f"the golden does not pass the oracle: {gv}")
            v = oracle(out, os.path.join(work, f"oracle{n}"))
            if not v["opens"] or v["sheet"] is not None or v["logHits"] != 0 or not v["pdf"]:
                raise RuntimeError(f"oracle: opens={v['opens']} sheet={v['sheet']} logHits={v['logHits']}")
            m = json.loads(run("swift", "Scripts/pdfmatch.swift", gv["pdf"], v["pdf"]).stdout)
            wrong = [j + 1 for j, got in enumerate(m["matches"]) if j + 1 not in got]
            if m["pages"][0] != m["pages"][1] or wrong:
                d = json.loads(run("swift", "Scripts/pdfdiff.swift", gv["pdf"], v["pdf"], check=False).stdout or "{}")
                raise RuntimeError(f"pages {wrong} differ from Keynote's own (mismatch {d.get('mismatch')}, bounds {d.get('bounds')})")
            resaved = os.path.join(work, f"case{n}-resaved.key")
            run("Scripts/resave.sh", out, resaved)
            def histogram(path):
                return run(dm, "inspect", path).stdout.split("types:", 1)[1].split("validation", 1)[0]
            a, b = histogram(out), histogram(resaved)
            if a != b: raise RuntimeError(f"AT-23: Keynote's re-save changes the object histogram: {sorted(set(a.splitlines()) ^ set(b.splitlines()))[:8]}")
            print(f"PASS {label}")
            passed += 1
        except Exception as e:
            print(f"FAIL {label}  {e}")
        sys.stdout.flush()
    print(f"insert: {passed}/{len(templates)} pass (work: {work})")
    sys.exit(0 if passed == len(templates) else 1)


if __name__ == "__main__":
    main()
