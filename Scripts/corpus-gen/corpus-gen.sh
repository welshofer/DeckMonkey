#!/bin/bash
# corpus-gen.sh — Corpus/templates (docs/spec.md §11): one deck per built-in Keynote theme, standard
# (1024×768) and wide (1920×1080), with every master layout instantiated once.
#
# usage: Scripts/corpus-gen/corpus-gen.sh [--out Corpus/templates] [--only "<theme name>"]...
#
# Keynote authors every byte: this script only asks it to create, fill and save new documents, the
# way a person would. Built-in themes are the ones whose id starts with "Application/"; themes the
# user installed (id "CloudKit/…") are never used, so nothing private enters the corpus. Each
# layout's title (and body, where the layout has one) gets "<theme> · <layout>" text, so the
# golden PDFs carry text and text-replace tests have a target. Safe beside open documents: it
# touches only the document it just made, by reference, and closes it without saving again.
#
# Requires macOS, Keynote, and Automation permission for the terminal → Keynote.

set -euo pipefail

OUT="Corpus/templates"
ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --only) ONLY+=("$2"); shift 2 ;;
    *) echo "usage: $0 [--out dir] [--only theme]..." >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# argv: theme id, width, height, output path, label. Prints the number of slides saved.
read -r -d '' AS_MAKE <<'APPLESCRIPT' || true
on run argv
  set themeId to item 1 of argv
  set w to (item 2 of argv) as integer
  set h to (item 3 of argv) as integer
  set outFile to POSIX file (item 4 of argv)
  set label to item 5 of argv
  with timeout of 600 seconds
    tell application id "com.apple.Keynote"
      set chosenTheme to first theme whose id is themeId
      set d to make new document with properties {document theme:chosenTheme, width:w, height:h}
      try
        set layouts to every master slide of d
        repeat with ms in layouts
          set s to make new slide at end of slides of d with properties {base slide:ms}
          set caption to label & " · " & (name of ms)
          try
            if title showing of s then set object text of default title item of s to caption
          end try
          try
            if body showing of s then set object text of default body item of s to caption & " body"
          end try
        end repeat
        -- The document's first slide came from the default layout before ours; drop it so each
        -- layout appears exactly once.
        if (count of slides of d) > (count of layouts) then delete slide 1 of d
        set n to count of slides of d
        save d in outFile
        close d saving no
        return n
      on error message number code
        try
          close d saving no
        end try
        error message number code
      end try
    end tell
  end timeout
end run
APPLESCRIPT

# Built-in theme ids and names, tab-separated.
read -r -d '' AS_THEMES <<'APPLESCRIPT' || true
tell application id "com.apple.Keynote"
  set out to ""
  repeat with t in every theme
    if (id of t) starts with "Application/" then set out to out & (id of t) & tab & (name of t) & linefeed
  end repeat
  return out
end tell
APPLESCRIPT

slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g'; }

made=0; failed=0
while IFS=$'\t' read -r id name; do
  [[ -n "$id" ]] || continue
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    keep=false; for o in "${ONLY[@]}"; do [[ "$o" == "$name" ]] && keep=true; done
    $keep || continue
  fi
  for size in standard wide; do
    if [[ $size == standard ]]; then w=1024; h=768; else w=1920; h=1080; fi
    file="$OUT/$(slug "$name")_$size.key"
    rm -rf "$file"
    if n=$(printf '%s\n' "$AS_MAKE" | osascript - "$id" "$w" "$h" "$file" "$name" 2>&1); then
      echo "made $(basename "$file"): $n slides"
      made=$((made + 1))
    else
      echo "FAILED $(basename "$file"): $n" >&2
      failed=$((failed + 1))
    fi
  done
done <<< "$(printf '%s\n' "$AS_THEMES" | osascript -)"
echo "corpus-gen: $made deck(s) in $OUT, $failed failed"
[[ $failed -eq 0 ]]
