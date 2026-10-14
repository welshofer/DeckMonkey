# DeckMonkey developer entry points. The merge gate is `make gate`.

SWIFT ?= swift
CORPUS ?= $(DECKMONKEY_CORPUS)

.PHONY: build test gate roundtrip-corpus oracle-corpus schema schema-diff clean

build:
	$(SWIFT) build

test:
	$(SWIFT) test

## Merge gate: tests green AND every corpus deck round-trips CLEAN.
gate: test roundtrip-corpus

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

## Schema pipeline (docs/spec.md §7, Scripts/schema/README.md). Not yet implemented.
schema:
	@echo "make schema: implement Scripts/schema per Scripts/schema/README.md" && exit 1

schema-diff:
	@echo "make schema-diff: implement after make schema" && exit 1

clean:
	rm -rf .build
