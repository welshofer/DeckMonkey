# Handoff to Claude Code — DeckMonkey Phase 0

The working copy on the M4 at `~/Developer/DeckMonkey` was written file-by-file before the
GitHub repo existed, so turn it into a real clone once (keeps the `.build` cache and the
git-ignored `.deckmonkey-corpus` pointer), then open Claude Code in it and paste the prompt below
as the first message. `CLAUDE.md` is loaded automatically and carries the conventions; this
prompt carries the first day's work.

```
cd ~/Developer/DeckMonkey
git init -q && git remote add origin https://github.com/welshofer/DeckMonkey
git fetch -q origin && git reset -q --hard origin/main && git branch -q -M main && git branch -u origin/main
echo ~/Developer/DeckMonkey-corpus > .deckmonkey-corpus   # git-ignored pointer to the private decks
git status --short                                        # expect: nothing
claude
```

---

## Kickoff prompt

You are picking up DeckMonkey, a Swift library that reads and writes native Keynote `.key` files.
Read `CLAUDE.md` first (conventions, invariants, the Phase 0 task list and what first contact
already proved), then `docs/spec.md` sections 5, 9, 12 and 14 (the contract).

State on handoff: the package builds and all suites are green on this Mac; `CorpusTests` reports
`roundtrip CLEAN 28/28` over the private decks with zero validation issues. Confirm that first —
`swift build && swift test` — then work in this order, committing after each step with a message
that says what and why:

1. **Hands on the CLI.** `swift run deckmonkey inspect <any .key>` and `swift run deckmonkey dump
   <same file> Index/Document.iwa` on a few private decks (the test harness could not pass CLI
   arguments, so the CLI itself has not been exercised on a real deck). Fix anything that
   surprises; add a synthetic-stream regression test for each fix (no deck bytes enter the repo).

2. **`make snappy-reference`, then `make gate`.** The first runs the reference Snappy decoder
   (cramjam, in a `.venv` it creates) over the private corpus once and caches hashes next to the
   decks; `gate` then includes AT-01 in both directions. It must pass before anything else lands.

3. **Verify the §4 table against bytes.** `docs/spec.md` §4 was written from prior art; first
   contact confirmed `MessageInfo` fields 1/2/3/5/6 and the container layouts. Correct the table
   from what `dump` shows, never the other way around.

4. **Oracle, first run.** Open one round-trip output in Keynote by hand and confirm no sheet
   appears. Then run `Scripts/oracle.sh <round-trip output> --golden <PDF you exported from the
   original in Keynote>`. The AppleScript element names and sheet detection were written without
   Keynote in reach; repair them until the JSON verdict is `pass: true` on a clean file and
   `pass: false` with `sheet` populated on a deliberately truncated copy. Keep the verdict shape.

5. **Schema pipeline.** Follow `Scripts/schema/README.md`: extract descriptors from
   `/Applications/Keynote.app/Contents/MacOS/Keynote` (and embedded frameworks), render `.proto`,
   generate Swift into `Sources/IWASchema/Generated/15.4/`, dump `TSPRegistry` into
   `Sources/IWASchema/Registry/registry-15.4.json`, generate the dispatch switch. Then AT-05:
   every type ID in the corpus resolves. Clean-room: WorkKit (AGPL) and keynote-parser are
   references for the pipeline's shape, never a source of code or proto files.

6. **Reference derivation.** AT-06/07/08: with the typed layer in place, walk each decoded payload
   with a SwiftProtobuf `Visitor`, collect every `TSP.Reference` / `TSP.DataReference`, and prove
   the derived lists equal the stored `object_references` / `data_references` on the whole corpus.
   Then promote dangling references to `.error` in `Validator`.

Stop and report when Gate 0's remaining items are the ones that need Jay: the synthetic corpus
(`Scripts/corpus-gen`, the hand-authored feature decks) and the 40-file oracle run. Do not start
Phase 1 on a partial Gate 0.

Rules that override anything else you infer: no PPTX bridge, no AppleScript write path, no
synthesis from empty, no new styles, private decks never enter the repo, Keynote is the oracle,
and a change that breaks an invariant in `CLAUDE.md` is a design change to raise, not a fix.
