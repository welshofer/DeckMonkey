# DeckMonkey developer entry points. The merge gate is `make gate`.

SWIFT ?= swift
# Private decks live outside the tree: DECKMONKEY_CORPUS, or a git-ignored .deckmonkey-corpus pointer file.
CORPUS ?= $(shell if [ -n "$$DECKMONKEY_CORPUS" ]; then echo "$$DECKMONKEY_CORPUS"; elif [ -f .deckmonkey-corpus ]; then head -1 .deckmonkey-corpus; fi)

PYTHON ?= .venv/bin/python

.PHONY: gates gate2 gate3 gate1 corpus goldens reference-strength build test gate roundtrip-corpus oracle-corpus snappy-reference snappy-check snappy-vectors schema schema-tools schema-diff clean

build:
	$(SWIFT) build

test:
	$(SWIFT) test

## Merge gate: tests green, every corpus deck round-trips CLEAN, and AT-01 holds on the corpus.
gate: test roundtrip-corpus snappy-check snappy-vectors

## Round-trip every .key under $(CORPUS) and Corpus/ through the CLI.
roundtrip-corpus:
	@$(SWIFT) build --product deckmonkey >/dev/null
	@find $(CORPUS) Corpus -path Corpus/hostile -prune -o -name '*.key' -prune -print0 2>/dev/null | { \
	  fail=0; n=0; skip=0; \
	  while IFS= read -r -d '' f; do \
	    .build/debug/deckmonkey roundtrip "$$f" >/tmp/deckmonkey-rt.log 2>&1; rc=$$?; \
	    if [ $$rc -eq 3 ]; then skip=$$((skip+1)); continue; fi; \
	    n=$$((n+1)); \
	    if [ $$rc -ne 0 ]; then fail=$$((fail+1)); echo "FAIL $$f"; cat /tmp/deckmonkey-rt.log; fi; \
	  done; \
	  echo "roundtrip-corpus: $$((n-fail))/$$n clean ($$skip legacy '09 deck(s) refused as designed)"; [ $$fail -eq 0 ]; }

## Run the Keynote oracle over every corpus deck's round-trip output (macOS only).
oracle-corpus:
	@$(SWIFT) build --product deckmonkey >/dev/null
	@find $(CORPUS) Corpus -path Corpus/hostile -prune -o -name '*.key' -prune -print0 2>/dev/null | { \
	  fail=0; n=0; skip=0; \
	  while IFS= read -r -d '' f; do \
	    out=/tmp/deckmonkey-oracle-$$((n+skip+1)).key; \
	    .build/debug/deckmonkey roundtrip "$$f" -o $$out >/dev/null 2>&1; rc=$$?; \
	    if [ $$rc -eq 3 ]; then skip=$$((skip+1)); continue; fi; \
	    n=$$((n+1)); \
	    [ $$rc -eq 0 ] || { fail=$$((fail+1)); echo "FAIL roundtrip $$f"; continue; }; \
	    golden="$${f%.key}.golden.pdf"; \
	    case "$$f" in Corpus/*) [ -f "$$golden" ] || { fail=$$((fail+1)); echo "FAIL $$f: no golden PDF (run make goldens)"; continue; } ;; esac; \
	    if [ -f "$$golden" ]; then Scripts/oracle.sh $$out --golden "$$golden" || { fail=$$((fail+1)); echo "FAIL oracle $$f"; }; \
	    else Scripts/oracle.sh $$out || { fail=$$((fail+1)); echo "FAIL oracle $$f"; }; fi; \
	  done; \
	  echo "oracle-corpus: $$((n-fail))/$$n pass ($$skip legacy '09 deck(s) refused as designed)"; [ $$fail -eq 0 ]; }

## The whole local corpus from the committed scripts (macOS, Keynote): the 106 template decks, the
## 12 feature decks, the hostile copies (AT-26) and the golden PDFs. Nothing it writes is committed.
corpus:
	Scripts/corpus-gen/corpus-gen.sh --out Corpus/templates
	Scripts/corpus-gen/features.sh --out Corpus/features
	@$(SWIFT) build --product deckmonkey >/dev/null
	.build/debug/deckmonkey corpus hostile --from Corpus/templates/basic-white_wide.key --out Corpus/hostile
	@$(MAKE) goldens

## Golden PDFs for every in-repo corpus deck, exported by the Keynote oracle (macOS, Keynote).
## Local only: git-ignored, rebuilt from the committed decks.
goldens:
	@$(SWIFT) build --product deckmonkey >/dev/null
	@for c in templates features; do \
	  [ -d Corpus/$$c ] && ls Corpus/$$c/*.key >/dev/null 2>&1 && .build/debug/deckmonkey corpus add --category $$c Corpus/$$c/*.key | tail -1; \
	done; true

## Gate 1 (docs/spec.md §12): the text-replace cases through the oracle (macOS, Keynote; run with
## the machine left alone). Scripts/gate1/cases.local.tsv, if present, adds private-deck cases.
gate1:
	@$(SWIFT) build --product deckmonkey >/dev/null
	python3 -I Scripts/gate1/gate1.py

## Gate 2 (images and media) and Gate 3a (slide move, delete, clone) through the oracle.
gate2:
	@$(SWIFT) build --product deckmonkey >/dev/null
	python3 -I Scripts/gate1/gate2.py

gate3:
	@$(SWIFT) build --product deckmonkey >/dev/null
	python3 -I Scripts/gate1/gate3.py

## Every oracle gate in sequence (about an hour of Keynote; leave the machine alone).
gates: gate1 gate2 gate3

## AT-01 (docs/spec.md §14). The reference Snappy decoder is cramjam, in a local venv.
.venv/bin/python:
	python3 -m venv .venv && .venv/bin/pip install -q cramjam

## Run the reference decoder once over the private corpus; hashes land next to the decks, never in the repo.
snappy-reference: .venv/bin/python
	@[ -n "$(CORPUS)" ] || { echo "no corpus: set DECKMONKEY_CORPUS or write .deckmonkey-corpus"; exit 2; }
	$(PYTHON) Scripts/snappy-crosscheck.py hash "$(CORPUS)" --out "$(CORPUS)/.snappy-reference.json"
	@if [ -d Corpus/templates ]; then $(PYTHON) Scripts/snappy-crosscheck.py hash Corpus/templates --out Corpus/.snappy-reference.json; fi

## Our decoder against the cached reference hashes, then the reference decoder against our compressor.
snappy-check: .venv/bin/python
	@[ -f "$(CORPUS)/.snappy-reference.json" ] || { echo "no $(CORPUS)/.snappy-reference.json: run make snappy-reference"; exit 2; }
	@$(SWIFT) build --product deckmonkey >/dev/null
	.build/debug/deckmonkey snappy-check "$(CORPUS)/.snappy-reference.json" --emit .build/snappy-ours
	$(PYTHON) Scripts/snappy-crosscheck.py verify-ours .build/snappy-ours
	@if [ -f Corpus/.snappy-reference.json ]; then \
	  .build/debug/deckmonkey snappy-check Corpus/.snappy-reference.json --emit .build/snappy-ours-corpus && \
	  $(PYTHON) Scripts/snappy-crosscheck.py verify-ours .build/snappy-ours-corpus; fi

## The reference decoder against our compression of the fixture vectors (written by `swift test`).
snappy-vectors: .venv/bin/python
	@[ -f .build/snappy-vectors-ours.json ] || { echo "no .build/snappy-vectors-ours.json: run make test first"; exit 2; }
	$(PYTHON) Scripts/snappy-crosscheck.py verify-vectors .build/snappy-vectors-ours.json

## Schema pipeline (docs/spec.md §7, Scripts/schema/README.md): extract, render, generate, registry,
## dispatch — from the installed Keynote, which must be the pinned build. Deterministic: a re-run on
## the same Keynote leaves git clean.
SCHEMA_VERSION ?= 15.4
SCHEMA_BUILD ?= 7051.0.79
SCHEMA_TOOLS := Scripts/schema/.build/release
SCHEMA_PROTO := Scripts/schema/proto/$(SCHEMA_VERSION)
SCHEMA_SWIFT := Sources/IWASchema/Generated/$(SCHEMA_VERSION)
SCHEMA_REGISTRY := Sources/IWASchema/Registry/registry-$(SCHEMA_VERSION).json

schema-tools:
	@cd Scripts/schema && $(SWIFT) build -c release --product protodump >/dev/null && $(SWIFT) build -c release --product protoc-gen-swift >/dev/null

schema: schema-tools
	@app="$$(Scripts/keynote-app.sh)" && found="$$(Scripts/keynote-app.sh --version)" && \
	  [ "$$found" = "$(SCHEMA_VERSION) ($(SCHEMA_BUILD))" ] || { echo "make schema: Keynote is $$found, pinned $(SCHEMA_VERSION) ($(SCHEMA_BUILD))"; exit 1; }; \
	  mkdir -p $(SCHEMA_PROTO) $(SCHEMA_SWIFT) && rm -f $(SCHEMA_PROTO)/*.proto $(SCHEMA_SWIFT)/*.swift && \
	  $(SCHEMA_TOOLS)/protodump extract "$$app" --out $(SCHEMA_PROTO) | tail -1 && \
	  $(SCHEMA_TOOLS)/protodump generate $(SCHEMA_PROTO)/descriptors.pb --plugin $(SCHEMA_TOOLS)/protoc-gen-swift --out $(SCHEMA_SWIFT) && \
	  python3 -I Scripts/schema/registry-dump.py "$$app" $(SCHEMA_PROTO)/descriptors.pb --out $(SCHEMA_REGISTRY) && \
	  $(SCHEMA_TOOLS)/protodump dispatch $(SCHEMA_PROTO)/descriptors.pb $(SCHEMA_REGISTRY) $(SCHEMA_SWIFT) --out $(SCHEMA_SWIFT)/Dispatch.swift && \
	  cp $(SCHEMA_PROTO)/descriptors.pb Sources/IWASchema/Registry/descriptors-$(SCHEMA_VERSION).pb

## Learn which reference fields the pinned Keynote lists (invariant 4) from the decks it authored
## (Corpus/templates and Corpus/features, built by `make corpus`); decks with any other save in
## their history are skipped. Reproducible from the repo's scripts alone: no private deck is read.
reference-strength:
	@$(SWIFT) build --product deckmonkey >/dev/null
	.build/debug/deckmonkey reference-strength --out Sources/IWASchema/Registry/reference-strength-$(SCHEMA_VERSION).json Corpus/templates Corpus/features

## Re-extract from the installed Keynote into a scratch dir and diff against the pinned tree. Fails on
## any difference; a new Keynote needs a new SCHEMA_VERSION and a dated note in docs/schema-changes.md.
schema-diff: schema-tools
	@app="$$(Scripts/keynote-app.sh)" && tmp="$$(mktemp -d)" && \
	  $(SCHEMA_TOOLS)/protodump extract "$$app" --out "$$tmp" >/dev/null && \
	  python3 -I Scripts/schema/registry-dump.py "$$app" "$$tmp/descriptors.pb" --out "$$tmp/registry.json" >/dev/null && \
	  diff -r -x descriptors.pb -x registry.json $(SCHEMA_PROTO) "$$tmp" && cmp -s $(SCHEMA_PROTO)/descriptors.pb "$$tmp/descriptors.pb" && \
	  diff $(SCHEMA_REGISTRY) "$$tmp/registry.json" && echo "schema-diff: installed Keynote matches $(SCHEMA_VERSION)"

clean:
	rm -rf .build .venv
