#!/usr/bin/env python3
"""gate.py — AT-29 (track R) over every deck with a golden PDF.

usage: python3 -I Scripts/render/gate.py [deck.key ...] [--out DIR] [--jobs N]

For each deck (default: Corpus/templates/*.key and Corpus/features/*.key that have
<deck>.golden.pdf beside them) runs `deckmonkey render` and `compare` (Scripts/render/compare.swift,
built into .build/compare), then prints each deck's median and worst page, the 15 worst pages
overall, and the corpus median and worst against AT-29's bar (median <= 3%, no page above 15%).
Exit 0 when the bar is met, 1 otherwise. Keynote is not involved: the goldens were exported once.
"""
import concurrent.futures, glob, json, os, statistics, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DECKMONKEY = os.path.join(ROOT, ".build/debug/deckmonkey")
COMPARE = os.path.join(ROOT, ".build/compare")
MEDIAN_BAR, WORST_BAR = 0.03, 0.15


def run(deck, out):
    name = os.path.basename(deck)[:-4]
    svg, cmp = os.path.join(out, name, "svg"), os.path.join(out, name, "compare")
    golden = deck[:-4] + ".golden.pdf"
    r = subprocess.run([DECKMONKEY, "render", deck, "-o", svg], capture_output=True, text=True)
    if r.returncode != 0:
        return name, None, r.stderr.strip()
    r = subprocess.run([COMPARE, svg, golden, cmp], capture_output=True, text=True)
    try:
        result = json.load(open(os.path.join(cmp, "compare.json")))
    except (OSError, ValueError):
        return name, None, r.stderr.strip() or r.stdout.strip()
    problems = json.load(open(os.path.join(svg, "render.json")))
    return name, result, sorted({p for s in problems for p in s["problems"]})


def main():
    args = sys.argv[1:]
    out = tempfile.mkdtemp(prefix="deckmonkey-render-gate.")
    jobs = 4
    if "--out" in args:
        i = args.index("--out"); out = args[i + 1]; del args[i:i + 2]
    if "--jobs" in args:
        i = args.index("--jobs"); jobs = int(args[i + 1]); del args[i:i + 2]
    decks = args or sorted(glob.glob(os.path.join(ROOT, "Corpus/templates/*.key")) + glob.glob(os.path.join(ROOT, "Corpus/features/*.key")))
    decks = [d for d in decks if os.path.exists(d[:-4] + ".golden.pdf")]
    subprocess.run(["swift", "build"], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(["swiftc", "-O", "-o", COMPARE, os.path.join(ROOT, "Scripts/render/compare.swift")], check=True)
    pages, failures = [], []
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        for name, result, extra in pool.map(lambda d: run(d, out), decks):
            if result is None:
                failures.append(name); print(f"{name}: FAILED {extra}"); continue
            shares = [p["mismatch"] for p in result["pages"] if "mismatch" in p]
            errors = [p for p in result["pages"] if "error" in p]
            pages += [(p["mismatch"], name, p["page"]) for p in result["pages"] if "mismatch" in p]
            if errors: failures.append(name)
            print(f"{name}: median {statistics.median(shares or [0]) * 100:.2f}%, worst {max(shares or [0]) * 100:.2f}% over {len(shares)} pages"
                  + (f"; {len(errors)} page errors" if errors else "") + (f"; not drawn: {', '.join(extra)}" if extra else ""))
    shares = sorted(p[0] for p in pages)
    print("\nworst pages:")
    for share, name, page in sorted(pages, reverse=True)[:15]:
        print(f"  {share * 100:6.2f}%  {name} page {page}  ({out}/{name}/compare/page-{page}.png)")
    median, worst = (statistics.median(shares), shares[-1]) if shares else (0, 0)
    ok = not failures and median <= MEDIAN_BAR and worst <= WORST_BAR
    print(f"\nAT-29 {'PASS' if ok else 'FAIL'}: {len(shares)} pages from {len(decks)} decks, median {median * 100:.2f}% (bar {MEDIAN_BAR * 100:.0f}%), "
          f"worst {worst * 100:.2f}% (bar {WORST_BAR * 100:.0f}%), {len(failures)} decks failed; output in {out}")
    json.dump({"pages": [{"deck": n, "page": p, "mismatch": s} for s, n, p in pages], "median": median, "worst": worst},
              open(os.path.join(out, "gate.json"), "w"), indent=1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
