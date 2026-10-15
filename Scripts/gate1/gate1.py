#!/usr/bin/env python3
"""gate1.py — Gate 1 (docs/spec.md §12): text replace cases through the Keynote oracle.

usage: Scripts/gate1/gate1.py [cases.tsv ...] [--work DIR]
       (default: Scripts/gate1/cases.tsv, plus Scripts/gate1/cases.local.tsv when present)

Each case: deck, find, replace, kind (AT-14 same length, AT-15 longer/shorter, AT-16 across a
style boundary, AT-17 overlapping a hyperlink). A deck path starting "corpus:" is resolved in the
private corpus (DECKMONKEY_CORPUS or .deckmonkey-corpus); private cases live in the git-ignored
cases.local.tsv so no private text enters the repository.

A case passes when `deckmonkey replace` succeeds (AT-17: and reports a removed field), Keynote
opens the output with no sheet and no persistence log errors and the same page count, and every
changed page's pixel box lies on a page holding replaced text and, where that text's frame is
known, inside the union of the frames (plus a margin for antialiasing). Prints one line per case
and a summary; exit 0 only if every case passes. Needs macOS and Keynote; run from the repo root.
"""
import json, os, subprocess, sys, tempfile

MARGIN = 4  # points: antialiasing and caret-free text edges spill a little past the frame


def corpus_root():
    env = os.environ.get("DECKMONKEY_CORPUS")
    if env: return env
    if os.path.exists(".deckmonkey-corpus"):
        return os.path.expanduser(open(".deckmonkey-corpus").read().split("\n")[0].strip())
    return None


def run(*args, check=True):
    p = subprocess.run(list(args), capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"{args[0]} {args[1] if len(args) > 1 else ''}: exit {p.returncode}: {p.stdout[-400:]} {p.stderr[-400:]}")
    return p


def oracle(deck, out_dir, golden=None):
    args = ["Scripts/oracle.sh", deck, "--out", out_dir] + (["--golden", golden] if golden else [])
    p = run(*args, check=False)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except Exception:
        raise RuntimeError(f"oracle gave no verdict: {p.stdout[-300:]} {p.stderr[-300:]}")


def main():
    args = sys.argv[1:]
    work = tempfile.mkdtemp(prefix="deckmonkey-gate1.")
    if "--work" in args:
        i = args.index("--work"); work = args[i + 1]; del args[i:i + 2]
        os.makedirs(work, exist_ok=True)
    files = args or ["Scripts/gate1/cases.tsv"] + (["Scripts/gate1/cases.local.tsv"] if os.path.exists("Scripts/gate1/cases.local.tsv") else [])
    cases = []
    for f in files:
        for line in open(f, encoding="utf-8"):
            if not line.strip() or line.startswith("#"): continue
            deck, find, replace, kind = line.rstrip("\n").split("\t")
            cases.append((deck, find, replace, kind))
    root = corpus_root()
    dm = ".build/debug/deckmonkey"
    goldens = {}
    passed = 0
    for n, (deck, find, replace, kind) in enumerate(cases, 1):
        label = f"{n:2} {kind:5} {os.path.basename(deck)}: {find!r} → {replace!r}"
        try:
            if deck.startswith("corpus:"):
                if not root: raise RuntimeError("no private corpus configured")
                deck = os.path.join(root, deck[len("corpus:"):])
            out = os.path.join(work, f"case{n}.key")
            r = run(dm, "replace", deck, "--find", find, "--replace", replace, "-o", out)
            storages = [int(x) for x in r.stdout.split("storage(s): ", 1)[1].split("\n")[0].split(", ")]
            removed = "removed " in r.stdout
            if kind == "AT-17" and not removed: raise RuntimeError("no overlapping field was reported removed")
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
            places = [json.loads(run(dm, "locate", out, "--storage", str(s)).stdout) for s in storages]
            for page, x0, y0, x1, y1 in diff["pageBounds"]:
                here = [p for p in places if p["page"] == page]
                if not here: raise RuntimeError(f"page {page} changed but holds no replaced text")
                frames = [p["frame"] for p in here]
                if all(f is not None for f in frames):
                    fx0 = min(f["x"] for f in frames) - MARGIN; fy0 = min(f["y"] for f in frames) - MARGIN
                    fx1 = max(f["x"] + f["width"] for f in frames) + MARGIN; fy1 = max(f["y"] + f["height"] for f in frames) + MARGIN
                    if x0 < fx0 or y0 < fy0 or x1 > fx1 or y1 > fy1:
                        raise RuntimeError(f"page {page}: change {x0},{y0}–{x1},{y1} outside frame {fx0:.0f},{fy0:.0f}–{fx1:.0f},{fy1:.0f}")
            pages = len(diff["pageBounds"])
            print(f"PASS {label}  ({len(storages)} storage(s), {pages} page(s) changed, {diff['mismatch']} px{', field removed' if removed else ''})")
            passed += 1
        except Exception as e:
            print(f"FAIL {label}  {e}")
        sys.stdout.flush()
    print(f"gate1: {passed}/{len(cases)} pass (work: {work})")
    sys.exit(0 if passed == len(cases) else 1)


if __name__ == "__main__":
    main()
