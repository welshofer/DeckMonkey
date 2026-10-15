# Handoff to Claude Code — DeckMonkey Phase 0

Open a terminal in the repo and run `claude`. Paste the prompt below as the first message.
`CLAUDE.md` is loaded automatically and carries the conventions; this prompt carries the first
day's work. Set `DECKMONKEY_CORPUS` first so the corpus suite has something to chew on.

```
cd ~/Developer/DeckMonkey
echo ~/Developer/DeckMonkey-corpus > .deckmonkey-corpus   # git-ignored pointer to the private decks
claude
```

---

## Kickoff prompt

You are picking up DeckMonkey, a Swift library that reads and writes native Keynote `.key` files.
Read `CLAUDE.md` first (conventions, invariants, the Phase 0 task list), then `docs/spec.md`
sections 5, 9, 12 and 14 (the contract). The scaffold was written without a compiler or a real
`.key` in reach; your first job is first contact with both.

Work in this order, committing after each step with a message that says what and why:

1. **Build and test.** `swift build` then `swift test`. Fix anything the Swift 6.2 compiler
   rejects (the code was written blind; expect a handful of strict-concurrency or API nits).
   Target: zero warnings, every suite green. `CorpusTests` is skipped until step 3.

2. **First contact with a real deck.** With `.deckmonkey-corpus` pointing at the private decks, run
   `swift run deckmonkey inspect <any .key>` and then `swift run deckmonkey dump <same file>
   Index/Document.iwa`. Compare what you see against `docs/spec.md` §4: component names, whether
   `Index/` is flat or a nested `Index.zip`, `MessageInfo` field numbers (type=1, version=2,
   length=3, object_references=5, data_references=6 are the assumptions), whether the reference
   lists are packed, and the `BuildVersionHistory.plist` entry format. Correct the code and the
   §4 table from the bytes, never the other way around, and add a regression test for each
   correction using a synthetic stream (no real deck bytes enter the repo).

3. **Round-trip.** `swift run deckmonkey roundtrip <file>` on every private deck, then
   `swift test` so `CorpusTests` runs. The bar is `CLEAN n/n` and no validator errors. A
   difference means a header re-encoded differently from how Keynote wrote it (non-minimal
   varints, field order) or a chunk-framing surprise; find the first differing identifier the
   report names and fix the raw layer, keeping invariant 2 (untouched records re-emit from
   original bytes). Then `make gate`.

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
