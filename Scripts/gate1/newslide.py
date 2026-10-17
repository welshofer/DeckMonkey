#!/usr/bin/env python3
"""newslide.py — new slides on masters, against Keynote's own New Slide.

usage: Scripts/gate1/newslide.py [template.key ...] [--work DIR]
       (default: four templates of different themes)

For each template, Keynote adds one slide per master at the end of a copy through its own AppleScript
(`make new slide with properties {base layout: …}`) and saves the golden; DeckMonkey adds the same
slides with `deckmonkey slide new`. The case passes when the validator passes, Keynote opens
DeckMonkey's file with no sheet and no persistence errors, every page is pixel-identical to the
golden's, and Keynote's re-save keeps the object histogram (AT-23). Needs macOS and Keynote; run from
the repo root with the machine left alone.
"""
import json, os, shutil, subprocess, sys, tempfile, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate1 import oracle, run  # noqa: E402

GOLDEN = '''on run argv
  set f to POSIX file (item 1 of argv)
  set token to item 2 of argv
  set out to POSIX file (item 3 of argv)
  with timeout of 600 seconds
    tell application id "com.apple.Keynote"
      open f
      repeat 120 times
        if (count of (every document whose name contains token)) > 0 then exit repeat
        delay 0.5
      end repeat
      set d to first document whose name contains token
      try
        set names to name of every slide layout of d
        repeat with n in names
          set l to (first slide layout of d whose name is (contents of n))
          tell d to make new slide at end of slides with properties {base layout:l}
        end repeat
        save d in out
      on error message
        close (every document whose name contains token) saving no
        error message
      end try
      close (every document whose name contains token) saving no
    end tell
  end timeout
  set AppleScript's text item delimiters to "|"
  return names as text
end run'''


def golden(template, out):
    token = "oracle-" + uuid.uuid4().hex[:8]
    work = tempfile.mkdtemp(prefix="deckmonkey-newslide.")
    copy = os.path.join(work, f"{token}-deck.key")
    shutil.copytree(template, copy) if os.path.isdir(template) else shutil.copy(template, copy)
    saved = os.path.join(work, f"{token}-golden.key")
    r = subprocess.run(["osascript", "-", copy, token, saved], input=GOLDEN, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(saved):
        raise RuntimeError(f"Keynote did not build the golden: {r.stderr.strip() or r.stdout.strip()}")
    shutil.move(saved, out)
    return r.stdout.strip()


def main():
    args = sys.argv[1:]
    work = tempfile.mkdtemp(prefix="deckmonkey-newslide.")
    if "--work" in args:
        i = args.index("--work"); work = args[i + 1]; del args[i:i + 2]
        os.makedirs(work, exist_ok=True)
    templates = args or [f"Corpus/templates/{t}.key" for t in ("basic-white_wide", "kyoto_wide", "showcase_wide", "academy_standard")]
    dm, passed = ".build/debug/deckmonkey", 0
    for n, template in enumerate(templates, 1):
        label = f"{n:2} {os.path.basename(template)}: one new slide per master"
        try:
            golden_deck = os.path.join(work, f"golden{n}.key")
            names = golden(template, golden_deck)
            out = os.path.join(work, f"case{n}.key")
            run(dm, "slide", "new", template, "--master", names, "-o", out)
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
                raise RuntimeError(f"{m['pages']} pages; pages {wrong} differ from Keynote's own (mismatch {d.get('mismatch')}, bounds {d.get('bounds')})")
            resaved = os.path.join(work, f"case{n}-resaved.key")
            run("Scripts/resave.sh", out, resaved)
            def histogram(path):
                return run(dm, "inspect", path).stdout.split("types:", 1)[1].split("validation", 1)[0]
            a, b = histogram(out), histogram(resaved)
            if a != b:
                diff = [l for l in set(a.splitlines()) ^ set(b.splitlines())]
                raise RuntimeError(f"AT-23: Keynote's re-save changes the object histogram: {sorted(diff)[:8]}")
            print(f"PASS {label}  ({m['pages'][1]} pages identical to Keynote's own; re-save unchanged)")
            passed += 1
        except Exception as e:
            print(f"FAIL {label}  {e}")
        sys.stdout.flush()
    print(f"newslide: {passed}/{len(templates)} pass (work: {work})")
    sys.exit(0 if passed == len(templates) else 1)


if __name__ == "__main__":
    main()
