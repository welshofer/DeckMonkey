#!/usr/bin/env python3
"""gate4.py — Gate 4 (docs/spec.md §12, AT-24): Deck IR fixtures to .key, against Keynote's own build.

usage: Scripts/gate4/gate4.py [cases.tsv ...] [--work DIR]   (default: Scripts/gate4/cases.tsv)

Each case: fixture (Corpus/ir/*.json), template deck. A case passes when `deckmonkey from-ir`
builds the deck, the validator passes, Keynote opens it with no sheet and no persistence errors,
every page of its PDF is pixel-identical to the same page of the golden (Keynote building the same
fixture itself through AppleScript, Scripts/gate4/golden.py; or a hand-built `<fixture>.golden.key`
beside the fixture, for content AppleScript cannot author), and Keynote's re-save keeps the object
histogram (AT-23). Needs macOS and Keynote; run from the repo root with the machine left alone.
"""
import json, os, subprocess, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gate1"))
from gate1 import oracle, run  # noqa: E402


def main():
    args = sys.argv[1:]
    work = tempfile.mkdtemp(prefix="deckmonkey-gate4.")
    if "--work" in args:
        i = args.index("--work"); work = args[i + 1]; del args[i:i + 2]
        os.makedirs(work, exist_ok=True)
    files = args or ["Scripts/gate4/cases.tsv"]
    cases = [l.rstrip("\n").split("\t") for f in files for l in open(f, encoding="utf-8") if l.strip() and not l.startswith("#")]
    dm, passed = ".build/debug/deckmonkey", 0
    for n, (fixture, template) in enumerate(cases, 1):
        label = f"{n:2} AT-24 {os.path.basename(fixture)} on {os.path.basename(template)}"
        try:
            out = os.path.join(work, f"case{n}.key")
            plan = os.path.join(work, f"plan{n}.json")
            run(dm, "from-ir", fixture, "--template", template, "--plan-out", plan, "-o", out)
            if "FAIL" in run(dm, "verify", out, check=False).stdout: raise RuntimeError("validator fails on the output")
            hand = fixture[:-5] + ".golden.key"
            if os.path.exists(hand):
                golden_deck = hand
            else:
                golden_deck = os.path.join(work, f"golden{n}.key")
                g = subprocess.run(["python3", "-I", "Scripts/gate4/golden.py", plan, template, golden_deck], capture_output=True, text=True)
                if g.returncode == 3: raise RuntimeError("needs a hand-built golden (sub-bullets): " + hand)
                if g.returncode != 0: raise RuntimeError(f"golden: {g.stderr.strip() or g.stdout.strip()}")
            gv = oracle(golden_deck, os.path.join(work, f"golden{n}"))
            if not gv["pass"]: raise RuntimeError(f"the golden does not pass the oracle: {gv}")
            v = oracle(out, os.path.join(work, f"oracle{n}"))
            if not v["opens"] or v["sheet"] is not None or v["logHits"] != 0 or not v["pdf"]:
                raise RuntimeError(f"oracle: opens={v['opens']} sheet={v['sheet']} logHits={v['logHits']}")
            m = json.loads(run("swift", "Scripts/pdfmatch.swift", gv["pdf"], v["pdf"]).stdout)
            if m["pages"][0] != m["pages"][1]: raise RuntimeError(f"{m['pages'][1]} pages, the golden has {m['pages'][0]}")
            wrong = [j + 1 for j, got in enumerate(m["matches"]) if j + 1 not in got]
            if wrong:
                d = json.loads(run("swift", "Scripts/pdfdiff.swift", gv["pdf"], v["pdf"], check=False).stdout or "{}")
                raise RuntimeError(f"pages {wrong} differ from Keynote's own build (mismatch {d.get('mismatch')}, bounds {d.get('bounds')})")
            resaved = os.path.join(work, f"case{n}-resaved.key")
            run("Scripts/resave.sh", out, resaved)
            def histogram(path):
                return run(dm, "inspect", path).stdout.split("types:", 1)[1].split("validation", 1)[0]
            if histogram(out) != histogram(resaved): raise RuntimeError("AT-23: Keynote's re-save changes the object histogram")
            print(f"PASS {label}  ({m['pages'][1]} pages, every page identical to Keynote's own build; re-save idempotent)")
            passed += 1
        except Exception as e:
            print(f"FAIL {label}  {e}")
        sys.stdout.flush()
    print(f"gate4: {passed}/{len(cases)} pass (work: {work})")
    sys.exit(0 if passed == len(cases) else 1)


if __name__ == "__main__":
    main()
