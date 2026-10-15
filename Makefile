# DeckMonkey developer entry points. The merge gate is `make gate`.

SWIFT ?= swift
# Private decks live outside the tree: DECKMONKEY_CORPUS, or a git-ignored .deckmonkey-corpus pointer file.
CORPUS ?= $(shell if [ -n "$$DECKMONKEY_CORPUS" ]; then echo "$$DECKMONKEY_CORPUS"; elif [ -f .deckmonkey-corpus ]; then head -1 .deckmonkey-corpus; fi)

PYTHON ?= .venv/bin/python

.PHONY: build test gate roundtrip-corpus oracle-corpus snappy-reference snappy-check snappy-vectors schema schema-diff clean

build:
	$(SWIFT) build

test:
	$(SWIFT) test

## Merge gate: tests green, every corpus deck round-trips CLEAN, and AT-01 holds on the corpus.
gate: test roundtrip-corpus snappy-check snappy-vectors

## Round-trip every .key under $(CORPUS) and Corpus/ through the CLI.
roundtrip-corpus:
	@$(SWIFT) build --product deckmonkey >/dev/null
	@fail=0; n=0; \
	for f in $$(find $(CORPUS) Corpus -name '*.key' -prune 2>/dev/null); do \
	  n=$$((n+1)); \
	  if ! .build/debug/deckmonkey roundtrip "$$f" >/tmp/deckmonkey-rt.log 2>&1; then fail=$$((fail+1)); echo "FAIL $$f"; cat /tmp/deckmonkey-rt.log; fi; \
	done; \
	echo "roundtrip-corpus: $$((n-fail))/$$n clean"; [ $$fail -eq 0 ]

## Run the Keynote oracle over every corpus deck's round-trip output (macOS only).
oracle-corpus:
	@$(SWIFT) build --product deckmonkey >/dev/null
	@fail=0; n=0; \
	for f in $$(find $(CORPUS) Corpus -name '*.key' -prune 2>/dev/null); do \
	  n=$$((n+1)); out=/tmp/deckmonkey-oracle-$$n.key; \
	  .build/debug/deckmonkey roundtrip "$$f" -o $$out >/dev/null || { fail=$$((fail+1)); echo "FAIL roundtrip $$f"; continue; }; \
	  golden="$${f%.key}.golden.pdf"; \
	  if [ -f "$$golden" ]; then Scripts/oracle.sh $$out --golden "$$golden" || { fail=$$((fail+1)); echo "FAIL oracle $$f"; }; \
	  else Scripts/oracle.sh $$out || { fail=$$((fail+1)); echo "FAIL oracle $$f"; }; fi; \
	done; \
	echo "oracle-corpus: $$((n-fail))/$$n pass"; [ $$fail -eq 0 ]

## AT-01 (docs/spec.md §14). The reference Snappy decoder is cramjam, in a local venv.
.venv/bin/python:
	python3 -m venv .venv && .venv/bin/pip install -q cramjam

## Run the reference decoder once over the private corpus; hashes land next to the decks, never in the repo.
snappy-reference: .venv/bin/python
	@[ -n "$(CORPUS)" ] || { echo "no corpus: set DECKMONKEY_CORPUS or write .deckmonkey-corpus"; exit 2; }
	$(PYTHON) Scripts/snappy-crosscheck.py hash "$(CORPUS)" --out "$(CORPUS)/.snappy-reference.json"

## Our decoder against the cached reference hashes, then the reference decoder against our compressor.
snappy-check: .venv/bin/python
	@[ -f "$(CORPUS)/.snappy-reference.json" ] || { echo "no $(CORPUS)/.snappy-reference.json: run make snappy-reference"; exit 2; }
	@$(SWIFT) build --product deckmonkey >/dev/null
	.build/debug/deckmonkey snappy-check "$(CORPUS)/.snappy-reference.json" --emit .build/snappy-ours
	$(PYTHON) Scripts/snappy-crosscheck.py verify-ours .build/snappy-ours

## The reference decoder against our compression of the fixture vectors (written by `swift test`).
snappy-vectors: .venv/bin/python
	@[ -f .build/snappy-vectors-ours.json ] || { echo "no .build/snappy-vectors-ours.json: run make test first"; exit 2; }
	$(PYTHON) Scripts/snappy-crosscheck.py verify-vectors .build/snappy-vectors-ours.json

## Schema pipeline (docs/spec.md §7, Scripts/schema/README.md). Not yet implemented.
schema:
	@echo "make schema: implement Scripts/schema per Scripts/schema/README.md" && exit 1

schema-diff:
	@echo "make schema-diff: implement after make schema" && exit 1

clean:
	rm -rf .build .venv
