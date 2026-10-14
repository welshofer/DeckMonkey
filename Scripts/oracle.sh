#!/bin/bash
# oracle.sh — Keynote is the acceptance oracle (docs/spec.md §10).
#
# usage: Scripts/oracle.sh <file.key> [--golden expected.pdf] [--out dir]
# Prints a JSON verdict and exits 0 on pass, 1 on fail.
#   {opens, sheet, pdfMismatch, pdfMismatchBounds, logHits, keynoteVersion, pdf}
#
# Requirements: macOS, Keynote installed, a logged-in GUI session, Automation permission for
# Terminal/osascript → Keynote and System Events granted once. Never touches the input file:
# it works on a copy. Only ever opens, exports, and closes.
#
# First cut written without a Keynote in reach — the first run on the M4 is expected to need
# adjustment (AppleScript element names, sheet detection). Keep the verdict shape stable.

set -euo pipefail

INPUT=""
GOLDEN=""
OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --golden) GOLDEN="$2"; shift 2 ;;
    --out) OUTDIR="$2"; shift 2 ;;
    *) INPUT="$1"; shift ;;
  esac
done
[[ -n "$INPUT" ]] || { echo "usage: $0 <file.key> [--golden expected.pdf] [--out dir]" >&2; exit 2; }
[[ "$(uname)" == "Darwin" ]] || { echo '{"error":"oracle requires macOS"}'; exit 1; }

WORK="${OUTDIR:-$(mktemp -d /tmp/deckmonkey-oracle.XXXXXX)}"
mkdir -p "$WORK"
COPY="$WORK/$(basename "$INPUT")"
rm -rf "$COPY"
cp -R "$INPUT" "$COPY"
PDF="$WORK/export.pdf"
rm -f "$PDF"

KEYNOTE_VERSION=$(defaults read /Applications/Keynote.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown")
START=$(date -u +"%Y-%m-%d %H:%M:%S")

OPENS=false
SHEET="null"
LOGHITS=0
PDFMISMATCH="null"
PDFBOUNDS="null"

# 1. Open, with a 30 s timeout. Any sheet or dialog on the Keynote process after open is a FAIL.
set +e
osascript <<APPLESCRIPT
with timeout of 45 seconds
  tell application "Keynote"
    activate
    open POSIX file "$COPY"
  end tell
end timeout
APPLESCRIPT
OPEN_RC=$?
set -e

# 2. Sheet / dialog detection.
sleep 2
SHEET_TEXT=$(osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "Keynote"
    if exists sheet 1 of window 1 then
      try
        return (name of sheet 1 of window 1) & " | " & (value of static text 1 of sheet 1 of window 1)
      on error
        return "sheet"
      end try
    end if
    if exists window "alert" then return "alert"
  end tell
end tell
return ""
APPLESCRIPT
)
if [[ -n "$SHEET_TEXT" ]]; then
  SHEET=$(printf '%s' "$SHEET_TEXT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
fi

if [[ $OPEN_RC -eq 0 && -z "$SHEET_TEXT" ]]; then
  OPENS=true
  # 3. Export PDF and close without saving.
  set +e
  osascript <<APPLESCRIPT
with timeout of 120 seconds
  tell application "Keynote"
    export front document to POSIX file "$PDF" as PDF
    close front document saving no
  end tell
end timeout
APPLESCRIPT
  set -e
else
  # Dismiss whatever is up and close so the next run starts clean.
  osascript -e 'tell application "System Events" to tell process "Keynote" to keystroke escape' >/dev/null 2>&1 || true
  osascript -e 'tell application "Keynote" to close every document saving no' >/dev/null 2>&1 || true
fi

# 4. Unified log: anything Keynote complained about while loading.
LOGHITS=$(log show --style compact --start "$START" --predicate 'process == "Keynote"' 2>/dev/null \
  | grep -i -E 'TSP|archive|repair|unable|corrupt|unarchiv' | grep -v -i 'deckmonkey' | wc -l | tr -d ' ')

# 5. PDF comparison against the golden.
if [[ -n "$GOLDEN" && -f "$PDF" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  DIFF=$(swift "$SCRIPT_DIR/pdfdiff.swift" "$GOLDEN" "$PDF" 2>/dev/null || echo '{"mismatch":-1,"bounds":null}')
  PDFMISMATCH=$(printf '%s' "$DIFF" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mismatch"])')
  PDFBOUNDS=$(printf '%s' "$DIFF" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["bounds"]))')
fi

PASS=true
[[ "$OPENS" == true ]] || PASS=false
[[ "$SHEET" == "null" ]] || PASS=false
[[ "$LOGHITS" == "0" ]] || PASS=false
if [[ "$PDFMISMATCH" != "null" && "$PDFMISMATCH" != "0" ]]; then PASS=false; fi

printf '{"opens":%s,"sheet":%s,"pdfMismatch":%s,"pdfMismatchBounds":%s,"logHits":%s,"keynoteVersion":"%s","pdf":"%s","pass":%s}\n' \
  "$OPENS" "$SHEET" "$PDFMISMATCH" "$PDFBOUNDS" "$LOGHITS" "$KEYNOTE_VERSION" "$PDF" "$PASS"
[[ "$PASS" == true ]]
