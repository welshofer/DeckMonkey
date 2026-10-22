#!/usr/bin/env python3
"""stages.py — AT-30 (builds): every build stage of every deck with a stages golden.

usage: python3 -I Scripts/render/stages.py [deck.key ...] [--out DIR] [--jobs N]

For each deck with <deck>.stages.pdf beside it (Keynote's export with "each stage of builds":
`Scripts/oracle.sh <deck> --stages`; default: every such deck in the private corpus) runs
`deckmonkey render --stages` and `compare`. The step model passes when every deck has as many stage
pages as Keynote printed (one per slide without builds, one per stage with); the pictures are judged
as AT-29 judges slides (median <= 3%, no judged page above 15%; pages needing what the file lacks
are counted, not barred, as are stages after an action build, whose moves and turns are not
applied yet). Exit 0 when both hold, 1 otherwise.
"""
import concurrent.futures, glob, json, os, statistics, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DECKMONKEY = os.path.join(ROOT, ".build/debug/deckmonkey")
COMPARE = os.path.join(ROOT, ".build/compare")
MEDIAN_BAR, WORST_BAR = 0.03, 0.15
COMPARE_TIMEOUT = 600
UNJUDGED = ("theme image", "theme photo", "font ", "picture frame", "3d chart", "build action")


def corpus():
    path = os.environ.get("DECKMONKEY_CORPUS")
    if not path and os.path.exists(os.path.join(ROOT, ".deckmonkey-corpus")):
        path = open(os.path.join(ROOT, ".deckmonkey-corpus")).read().strip()
    return path


def run(deck, out):
    name = os.path.basename(deck)[:-4]
    svg, cmp = os.path.join(out, name, "svg"), os.path.join(out, name, "compare")
    golden = deck[:-4] + ".stages.pdf"
    r = subprocess.run([DECKMONKEY, "render", deck, "-o", svg, "--stages"], capture_output=True, text=True)
    if r.returncode != 0:
        return name, None, r.stderr.strip()
    try:
        r = subprocess.run([COMPARE, svg, golden, cmp], capture_output=True, text=True, timeout=COMPARE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return name, None, f"compare did not finish in {COMPARE_TIMEOUT} s (rerun the deck)"
    try:
        result = json.load(open(os.path.join(cmp, "compare.json")))
    except (OSError, ValueError):
        return name, None, r.stderr.strip() or r.stdout.strip()
    report = {p["page"]: p for p in json.load(open(os.path.join(svg, "render.json")))}
    for p in result["pages"]:
        info = report.get(p["page"], {})
        p["stage"], p["stages"] = info.get("stage", 0), info.get("stages", 1)
        p["unjudged"] = any(x.startswith(UNJUDGED) for x in info.get("problems", []))
    return name, result, len(report)


def main():
    args = sys.argv[1:]
    out = tempfile.mkdtemp(prefix="deckmonkey-stages-gate.")
    jobs = 4
    if "--out" in args:
        i = args.index("--out"); out = args[i + 1]; del args[i:i + 2]
    if "--jobs" in args:
        i = args.index("--jobs"); jobs = int(args[i + 1]); del args[i:i + 2]
    base = corpus()
    decks = args or (sorted(glob.glob(os.path.join(base, "**/*.key"), recursive=True)) if base else [])
    decks = [d for d in decks if os.path.exists(d[:-4] + ".stages.pdf")]
    if not decks:
        print("no deck has a <deck>.stages.pdf (make them with Scripts/oracle.sh <deck> --stages)"); sys.exit(1)
    subprocess.run(["swift", "build"], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(["swiftc", "-O", "-o", COMPARE, os.path.join(ROOT, "Scripts/render/compare.swift")], check=True)
    pages, failures, miscounted = [], [], []
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        for name, result, extra in pool.map(lambda d: run(d, out), decks):
            if result is None:
                failures.append(name); print(f"{name}: FAILED {extra}"); continue
            golden_pages = result.get("goldenPages", len(result["pages"]))
            staged = [p for p in result["pages"] if p.get("stages", 1) > 1]
            shares = [p["mismatch"] for p in staged if "mismatch" in p]
            if extra != golden_pages:
                miscounted.append(name)
            pages += [(p["mismatch"], name, p["page"], p["unjudged"]) for p in staged if "mismatch" in p]
            print(f"{name}: {extra} stage pages (Keynote {golden_pages}){'' if extra == golden_pages else ' MISCOUNTED'}; "
                  f"{len(staged)} on slides with builds, median {statistics.median(shares or [0]) * 100:.2f}%, worst {max(shares or [0]) * 100:.2f}%")
    judged = [p for p in pages if not p[3]]
    shares = sorted(p[0] for p in judged)
    print("\nworst judged stage pages:")
    for share, name, page, _ in sorted(judged, reverse=True)[:10]:
        print(f"  {share * 100:6.2f}%  {name} page {page}  ({out}/{name}/compare/page-{page}.png)")
    median, worst = (statistics.median(shares), shares[-1]) if shares else (0, 0)
    ok = not failures and not miscounted and median <= MEDIAN_BAR and worst <= WORST_BAR
    print(f"\nAT-30 {'PASS' if ok else 'FAIL'}: {len(decks)} decks, {len(miscounted)} miscounted, {len(failures)} failed; "
          f"{len(shares)} judged stage pages, median {median * 100:.2f}% (bar {MEDIAN_BAR * 100:.0f}%), worst {worst * 100:.2f}% "
          f"(bar {WORST_BAR * 100:.0f}%); {len(pages) - len(judged)} unjudged; output in {out}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
