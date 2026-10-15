#!/usr/bin/env python3
"""gate3.py — Gate 3a (docs/spec.md §12, AT-20 clone, AT-21 delete, AT-22 move) through the oracle.

usage: Scripts/gate1/gate3.py [cases.tsv ...] [--work DIR]   (default: Scripts/gate1/slides.tsv)

Each case: deck, operation ("move N M", "delete N" or "clone N", 0-based show-order indexes), kind. A case
passes when the edit succeeds, the output validates, Keynote opens it with no sheet and no
persistence errors, and every page of its PDF is pixel-identical to the original page expected
there: the original's non-skipped slides, in the new order, minus a deleted one (AT-21: the page
count drops by one when a shown slide is deleted), and a clone identical to its source (AT-20);
and when Keynote opens the output and saves it again, the object histogram by type is unchanged
(AT-23, Scripts/resave.sh). Needs macOS and Keynote; run from the repo root
with the machine left alone.
"""
import json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate1 import corpus_root, oracle, run  # noqa: E402


def shown(dm, deck):
    """Slide identifiers of the non-skipped slides, in show order (the PDF's pages)."""
    out = []
    for line in run(dm, "slide", "list", deck).stdout.splitlines():
        cols = line.split("\t")
        if not (len(cols) > 4 and cols[4] == "skipped"): out.append(cols[2])
    return out


def main():
    args = sys.argv[1:]
    work = tempfile.mkdtemp(prefix="deckmonkey-gate3.")
    if "--work" in args:
        i = args.index("--work"); work = args[i + 1]; del args[i:i + 2]
        os.makedirs(work, exist_ok=True)
    files = args or ["Scripts/gate1/slides.tsv"]
    cases = [l.rstrip("\n").split("\t") for f in files for l in open(f, encoding="utf-8") if l.strip() and not l.startswith("#")]
    root, dm = corpus_root(), ".build/debug/deckmonkey"
    goldens, passed = {}, 0
    for n, (deck, operation, kind) in enumerate(cases, 1):
        label = f"{n:2} {kind:5} {os.path.basename(deck)}: {operation}"
        try:
            if deck.startswith("corpus:"):
                if not root: raise RuntimeError("no private corpus configured")
                deck = os.path.join(root, deck[len("corpus:"):])
            out = os.path.join(work, f"case{n}.key")
            op = operation.split()
            before = shown(dm, deck)
            if op[0] == "move":
                run(dm, "slide", "move", deck, "--index", op[1], "--to", op[2], "-o", out)
            elif op[0] == "delete":
                run(dm, "slide", "delete", deck, "--index", op[1], "-o", out)
            elif op[0] == "clone":
                run(dm, "slide", "clone", deck, "--index", op[1], "-o", out)
            else:
                raise RuntimeError(f"unknown operation {operation}")
            if "FAIL" in run(dm, "verify", out, check=False).stdout: raise RuntimeError("validator fails on the output")
            after = shown(dm, out)
            # The original page shown at each new page; a clone shows its source's page.
            source = [l.split("\t")[2] for l in run(dm, "slide", "list", deck).stdout.splitlines()][int(op[1])] if op[0] == "clone" else None
            expected = [before.index(s if s in before else source) + 1 for s in after]
            if op[0] == "delete" and len(after) not in (len(before), len(before) - 1): raise RuntimeError("AT-21: page count")
            golden = deck[:-4] + ".golden.pdf"
            if not os.path.exists(golden):
                if deck not in goldens:
                    v = oracle(deck, os.path.join(work, f"golden{n}"))
                    if not v["pass"]: raise RuntimeError(f"the original does not pass the oracle: {v}")
                    goldens[deck] = v["pdf"]
                golden = goldens[deck]
            v = oracle(out, os.path.join(work, f"oracle{n}"))
            if not v["opens"] or v["sheet"] is not None or v["logHits"] != 0 or not v["pdf"]:
                raise RuntimeError(f"oracle: opens={v['opens']} sheet={v['sheet']} logHits={v['logHits']}")
            m = json.loads(run("swift", "Scripts/pdfmatch.swift", golden, v["pdf"]).stdout)
            if m["pages"][1] != len(expected): raise RuntimeError(f"{m['pages'][1]} pages, expected {len(expected)}")
            wrong = [(j + 1, e, got) for j, (e, got) in enumerate(zip(expected, m["matches"])) if e not in got]
            if wrong: raise RuntimeError(f"pages not identical to the expected originals (page, expected, equal-to): {wrong[:5]}")
            # AT-23: Keynote's own re-save of the output keeps the object histogram by type.
            resaved = os.path.join(work, f"case{n}-resaved.key")
            run("Scripts/resave.sh", out, resaved)
            def histogram(path):
                text = run(dm, "inspect", path).stdout
                return text.split("types:", 1)[1].split("validation", 1)[0]
            if histogram(out) != histogram(resaved): raise RuntimeError("AT-23: Keynote's re-save changes the object histogram")
            print(f"PASS {label}  ({len(before)} → {len(after)} pages, every page identical to its original; re-save idempotent)")
            passed += 1
        except Exception as e:
            print(f"FAIL {label}  {e}")
        sys.stdout.flush()
    print(f"gate3: {passed}/{len(cases)} pass (work: {work})")
    sys.exit(0 if passed == len(cases) else 1)


if __name__ == "__main__":
    main()
