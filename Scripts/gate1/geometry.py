#!/usr/bin/env python3
"""geometry.py — moving and resizing a drawable, against Keynote doing the same.

usage: Scripts/gate1/geometry.py [cases.tsv] [--work DIR]   (default: Scripts/gate1/geometry.tsv)

Each case: deck, slide (0-based), AppleScript class (image, shape, text item, or "title"/"body" for
the slide's placeholders), the object's current frame, and the new frame (points, x,y,w,h). DeckMonkey
places the object with `deckmonkey object --frame`; Keynote does the same to a copy through its own
AppleScript (the element whose position and size match the current frame), saving the golden. The
case passes when the validator passes, Keynote opens DeckMonkey's file with no sheet and no
persistence errors, every page is pixel-identical to the golden's, and Keynote's re-save keeps the
object histogram (AT-23). Needs macOS and Keynote; run from the repo root with the machine left alone.
"""
import json, os, shutil, subprocess, sys, tempfile, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate1 import oracle, run  # noqa: E402

GOLDEN = '''on run argv
  set f to POSIX file (item 1 of argv)
  set token to item 2 of argv
  set out to POSIX file (item 3 of argv)
  set slideIndex to (item 4 of argv) as integer
  set wanted to item 5 of argv
  set ox to (item 6 of argv) as real
  set oy to (item 7 of argv) as real
  set ow to (item 8 of argv) as real
  set oh to (item 9 of argv) as real
  set nx to (item 10 of argv) as real
  set ny to (item 11 of argv) as real
  set nw to (item 12 of argv) as real
  set nh to (item 13 of argv) as real
  with timeout of 300 seconds
    tell application id "com.apple.Keynote"
      open f
      repeat 120 times
        if (count of (every document whose name contains token)) > 0 then exit repeat
        delay 0.5
      end repeat
      set d to first document whose name contains token
      try
        set s to slide slideIndex of d
        if wanted is "title" then
          set n to default title item of s
        else if wanted is "body" then
          set n to default body item of s
        else
          if wanted is "image" then
            set candidates to every image of s
          else if wanted is "shape" then
            set candidates to every shape of s
          else
            set candidates to every text item of s
          end if
          set n to missing value
          repeat with c in candidates
            set p to position of c
            if n is missing value and (my abs_(((item 1 of p) as real) - ox)) < 1.5 and (my abs_(((item 2 of p) as real) - oy)) < 1.5 and (my abs_((width of c) - ow)) < 1.5 and (my abs_((height of c) - oh)) < 1.5 then set n to contents of c
          end repeat
          if n is missing value then error "no " & wanted & " at the given frame"
        end if
        set width of n to nw
        set height of n to nh
        set position of n to {nx, ny}
        save d in out
      on error message
        close (every document whose name contains token) saving no
        error message
      end try
      close (every document whose name contains token) saving no
    end tell
  end timeout
  return "saved"
end run
on abs_(x)
  if x < 0 then return -x
  return x
end abs_'''


def golden(deck, slide, kind, old, new, out):
    token = "oracle-" + uuid.uuid4().hex[:8]
    work = tempfile.mkdtemp(prefix="deckmonkey-geometry.")
    copy = os.path.join(work, f"{token}-deck.key")
    shutil.copytree(deck, copy) if os.path.isdir(deck) else shutil.copy(deck, copy)
    saved = os.path.join(work, f"{token}-golden.key")
    args = ["osascript", "-", copy, token, saved, str(slide + 1), kind] + [str(v) for v in old + new]
    r = subprocess.run(args, input=GOLDEN, capture_output=True, text=True)
    if r.stdout.strip() != "saved" or not os.path.exists(saved):
        raise RuntimeError(f"Keynote did not build the golden: {r.stderr.strip() or r.stdout.strip()}")
    if os.path.exists(out): shutil.rmtree(out) if os.path.isdir(out) else os.remove(out)
    shutil.move(saved, out)


def main():
    args = sys.argv[1:]
    work = tempfile.mkdtemp(prefix="deckmonkey-geometry.")
    if "--work" in args:
        i = args.index("--work"); work = args[i + 1]; del args[i:i + 2]
        os.makedirs(work, exist_ok=True)
    files = args or ["Scripts/gate1/geometry.tsv"]
    cases = [l.rstrip("\n").split("\t") for f in files for l in open(f, encoding="utf-8") if l.strip() and not l.startswith("#")]
    dm, passed = ".build/debug/deckmonkey", 0
    for n, (deck, slide, kind, old, new) in enumerate(cases, 1):
        old_f = [float(v) for v in old.split(",")]
        new_f = [float(v) for v in new.split(",")]
        label = f"{n:2} {os.path.basename(deck)} slide {slide} {kind} {old} -> {new}"
        try:
            items = json.loads(run(dm, "object", deck, "--slide", slide).stdout)
            if kind in ("title", "body"):
                match = [d for d in items if d["kind"] == "placeholder" and d["name"].lower() == kind]
            else:
                wanted = {"image": "image", "shape": "shape", "text item": "text"}[kind]
                match = [d for d in items if d["kind"] == wanted and all(abs(a - b) < 1.5 for a, b in zip(d["frame"], old_f))]
            if len(match) != 1: raise RuntimeError(f"{len(match)} objects match")
            out = os.path.join(work, f"case{n}.key")
            run(dm, "object", deck, "--object", str(match[0]["id"]), "--frame", new, "-o", out)
            if "FAIL" in run(dm, "verify", out, check=False).stdout: raise RuntimeError("validator fails on the output")
            golden_deck = os.path.join(work, f"golden{n}.key")
            golden(deck, int(slide), kind, old_f, new_f, golden_deck)
            gv = oracle(golden_deck, os.path.join(work, f"golden{n}"))
            if not gv["pass"]: raise RuntimeError(f"the golden does not pass the oracle: {gv}")
            v = oracle(out, os.path.join(work, f"oracle{n}"))
            if not v["opens"] or v["sheet"] is not None or v["logHits"] != 0 or not v["pdf"]:
                raise RuntimeError(f"oracle: opens={v['opens']} sheet={v['sheet']} logHits={v['logHits']}")
            m = json.loads(run("swift", "Scripts/pdfmatch.swift", gv["pdf"], v["pdf"]).stdout)
            wrong = [j + 1 for j, got in enumerate(m["matches"]) if j + 1 not in got]
            if m["pages"][0] != m["pages"][1] or wrong:
                d = json.loads(run("swift", "Scripts/pdfdiff.swift", gv["pdf"], v["pdf"], check=False).stdout or "{}")
                raise RuntimeError(f"pages {wrong} differ from Keynote's own edit (mismatch {d.get('mismatch')}, bounds {d.get('bounds')})")
            resaved = os.path.join(work, f"case{n}-resaved.key")
            run("Scripts/resave.sh", out, resaved)
            def histogram(path):
                return run(dm, "inspect", path).stdout.split("types:", 1)[1].split("validation", 1)[0]
            if histogram(out) != histogram(resaved): raise RuntimeError("AT-23: Keynote's re-save changes the object histogram")
            print(f"PASS {label}")
            passed += 1
        except Exception as e:
            print(f"FAIL {label}  {e}")
        sys.stdout.flush()
    print(f"geometry: {passed}/{len(cases)} pass (work: {work})")
    sys.exit(0 if passed == len(cases) else 1)


if __name__ == "__main__":
    main()
