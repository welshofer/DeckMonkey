#!/bin/bash
# oracle.sh — Keynote is the acceptance oracle (docs/spec.md §10).
#
# usage: Scripts/oracle.sh <file.key> [--golden expected.pdf] [--out dir]
# Prints a JSON verdict and exits 0 on pass, 1 on fail, 2 on usage.
#   {opens, sheet, pdfMismatch, pdfMismatchBounds, logHits, keynoteVersion, pdf, pass}
#
# Requirements: macOS, Keynote installed (found by bundle id; KEYNOTE_APP overrides), a logged-in
# GUI session, Automation permission for the terminal → Keynote and System Events granted once.
#
# Safe to run while you have your own presentations open in Keynote:
# - The input is never touched. It is copied to `oracle-<random>-<name>.key` in a scratch folder,
#   and every AppleScript step addresses only the document or window carrying that unique token.
# - The script only opens, exports and closes (without saving) that copy. It never closes, saves,
#   or inspects any other document.
# - Paths reach AppleScript through argv, never by interpolation into script source.
#
# The AppleScript lives in variables piped to `osascript -`: macOS's bash 3.2 misparses heredocs
# inside $( ).

set -euo pipefail

# --- AppleScript -------------------------------------------------------------------------------

# argv: path. Opens without waiting: an alert raised during open would hang a blocking open event.
read -r -d '' AS_OPEN <<'APPLESCRIPT' || true
on run argv
  set f to POSIX file (item 1 of argv)
  tell application id "com.apple.Keynote"
    activate
    ignoring application responses
      open f
    end ignoring
  end tell
end run
APPLESCRIPT

# Prints the names of Keynote's dialog-subrole windows, one per line. Snapshotted before the open:
# Keynote can have dialog-subrole windows up that are not ours (Creator Studio's suggestions
# panel is one), and only a dialog that appears after the open counts against the copy.
read -r -d '' AS_DIALOGS <<'APPLESCRIPT' || true
on run argv
  set out to {}
  tell application "System Events"
    tell (first process whose bundle identifier is "com.apple.Keynote")
      repeat with w in windows
        try
          if value of attribute "AXSubrole" of w is in {"AXDialog", "AXSystemDialog"} then set end of out to (name of w)
        end try
      end repeat
    end tell
  end tell
  set AppleScript's text item delimiters to linefeed
  return out as text
end run
APPLESCRIPT

# argv: token, pre-existing dialog names (AS_DIALOGS output). Prints "open", "modal:<texts>" (a
# sheet on our window, or a dialog that was not up before the open), or "" while nothing is up yet.
read -r -d '' AS_STATE <<'APPLESCRIPT' || true
on texts(e)
  set out to {}
  tell application "System Events"
    try
      repeat with t in (static texts of e)
        set v to value of t
        if v is not missing value and v is not "" then set end of out to v
      end repeat
    end try
  end tell
  set AppleScript's text item delimiters to " | "
  return out as text
end texts

on run argv
  set token to item 1 of argv
  set preexisting to paragraphs of (item 2 of argv)
  tell application "System Events"
    tell (first process whose bundle identifier is "com.apple.Keynote")
      repeat with w in windows
        set sr to ""
        try
          set sr to value of attribute "AXSubrole" of w
        end try
        if sr is in {"AXDialog", "AXSystemDialog"} and (name of w) is not in preexisting then return "modal:" & my texts(w)
      end repeat
      repeat with w in windows
        if (name of w) contains token then
          if exists sheet 1 of w then return "modal:" & my texts(sheet 1 of w)
          return "open"
        end if
      end repeat
    end tell
  end tell
  return ""
end run
APPLESCRIPT

# argv: token, pdf path.
read -r -d '' AS_EXPORT <<'APPLESCRIPT' || true
on run argv
  set token to item 1 of argv
  set out to POSIX file (item 2 of argv)
  with timeout of 300 seconds
    tell application id "com.apple.Keynote"
      export (first document whose name contains token) to out as PDF
    end tell
  end timeout
end run
APPLESCRIPT

# argv: token, pre-existing dialog names. Dismisses anything modal that is ours (escape = cancel),
# then closes only the documents carrying the token, without saving. Names are snapshotted first:
# a `repeat with d in (every document whose …)` loop re-evaluates the list as documents close.
read -r -d '' AS_CLOSE <<'APPLESCRIPT' || true
on run argv
  set token to item 1 of argv
  set preexisting to paragraphs of (item 2 of argv)
  tell application "System Events"
    tell (first process whose bundle identifier is "com.apple.Keynote")
      repeat 3 times
        set blocked to false
        repeat with w in windows
          if ((name of w) contains token) and (exists sheet 1 of w) then set blocked to true
          try
            if value of attribute "AXSubrole" of w is in {"AXDialog", "AXSystemDialog"} and (name of w) is not in preexisting then set blocked to true
          end try
        end repeat
        if not blocked then exit repeat
        set frontmost to true
        key code 53
        delay 1
      end repeat
    end tell
  end tell
  tell application id "com.apple.Keynote"
    set names to name of every document whose name contains token
    repeat with n in names
      close document (contents of n) saving no
    end repeat
  end tell
end run
APPLESCRIPT

applescript() { local script="$1"; shift; printf '%s\n' "$script" | osascript - "$@" 2>/dev/null; }
json_string() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# --- Arguments ---------------------------------------------------------------------------------

INPUT=""
GOLDEN=""
OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --golden) [[ $# -ge 2 ]] || { echo "--golden needs a value" >&2; exit 2; }; GOLDEN="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || { echo "--out needs a value" >&2; exit 2; }; OUTDIR="$2"; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) INPUT="$1"; shift ;;
  esac
done
[[ -n "$INPUT" && -e "$INPUT" ]] || { echo "usage: $0 <file.key> [--golden expected.pdf] [--out dir]" >&2; exit 2; }
[[ -z "$GOLDEN" || -f "$GOLDEN" ]] || { echo "no such golden PDF: $GOLDEN" >&2; exit 2; }
[[ "$(uname)" == "Darwin" ]] || { echo '{"error":"oracle requires macOS"}'; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYNOTE_VERSION=$("$SCRIPT_DIR/keynote-app.sh" --version 2>/dev/null || echo "unknown")

WORK="${OUTDIR:-$(mktemp -d /tmp/deckmonkey-oracle.XXXXXX)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
TOKEN="oracle-$(uuidgen | tr -d - | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
COPY="$WORK/$TOKEN-$(basename "$INPUT")"
cp -R "$INPUT" "$COPY"
PDF="$WORK/$TOKEN-export.pdf"

OPENS=false
SHEET="null"
LOGHITS=0
PDFMISMATCH="null"
PDFBOUNDS="null"
START=$(date +"%Y-%m-%d %H:%M:%S")

BEFORE=$(applescript "$AS_DIALOGS" || true)
trap 'applescript "$AS_CLOSE" "$TOKEN" "$BEFORE" >/dev/null || true' EXIT

# --- 1. Open, then poll until our window is up or something modal appears ----------------------

applescript "$AS_OPEN" "$COPY" >/dev/null || true
STATE=""
for i in $(seq 1 60); do
  sleep 1
  # Right after another alert is dismissed Keynote can drop an open event. Re-sending it is
  # idempotent (an already-open document just comes forward).
  if [[ $i -eq 10 || $i -eq 30 ]]; then applescript "$AS_OPEN" "$COPY" >/dev/null || true; fi
  STATE=$(applescript "$AS_STATE" "$TOKEN" "$BEFORE" || true)
  [[ -z "$STATE" ]] || break
done
if [[ "$STATE" == "open" ]]; then
  # Late sheets (missing fonts, repaired content) attach after the window appears.
  sleep 3
  STATE=$(applescript "$AS_STATE" "$TOKEN" "$BEFORE" || true)
fi

case "$STATE" in
  open) OPENS=true ;;
  modal:*) SHEET=$(printf '%s' "${STATE#modal:}" | json_string) ;;
  *) SHEET=$(printf 'timeout: no document window after 60 s' | json_string) ;;
esac

# --- 2. Export PDF (only a clean open is exported; the trap closes the copy without saving) ----

if [[ "$OPENS" == true ]]; then
  applescript "$AS_EXPORT" "$TOKEN" "$PDF" >/dev/null || true
fi
[[ -f "$PDF" ]] || PDF=""

# --- 3. Unified log: what Keynote said about archives while it had our copy --------------------

# Only iWork errors and faults from the persistence layer (TSP* categories) and assertions that
# name it. A plain grep of Keynote's log is useless: every open of a pristine deck logs UI errors
# (status HUD, collaboration toolbar, sandbox URL tracker) and routine TSPPersistenceLogCat
# debug lines. `log` is /usr/bin/log explicitly: zsh has a `log` builtin.
LOG_PREDICATE='process == "Keynote" AND subsystem == "com.apple.iwork" AND (messageType == error OR messageType == fault) AND (category BEGINSWITH "TSP" OR (category == "TSUAssertCat" AND composedMessage CONTAINS "TSP"))'
LOGHITS=$(/usr/bin/log show --style compact --start "$START" --predicate "$LOG_PREDICATE" 2>/dev/null \
  | grep -c -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' || true)

# --- 4. PDF comparison against the golden ------------------------------------------------------

if [[ -n "$GOLDEN" ]]; then
  if [[ -n "$PDF" ]]; then
    DIFF=$(swift "$SCRIPT_DIR/pdfdiff.swift" "$GOLDEN" "$PDF" 2>/dev/null || echo '{"mismatch":-1,"bounds":null}')
    PDFMISMATCH=$(printf '%s' "$DIFF" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mismatch"])')
    PDFBOUNDS=$(printf '%s' "$DIFF" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["bounds"]))')
  else
    PDFMISMATCH=-1
  fi
fi

PASS=true
[[ "$OPENS" == true ]] || PASS=false
[[ "$SHEET" == "null" ]] || PASS=false
[[ "$LOGHITS" == "0" ]] || PASS=false
if [[ "$OPENS" == true && -z "$PDF" ]]; then PASS=false; fi
if [[ "$PDFMISMATCH" != "null" && "$PDFMISMATCH" != "0" ]]; then PASS=false; fi

printf '{"opens":%s,"sheet":%s,"pdfMismatch":%s,"pdfMismatchBounds":%s,"logHits":%s,"keynoteVersion":"%s","pdf":%s,"pass":%s}\n' \
  "$OPENS" "$SHEET" "$PDFMISMATCH" "$PDFBOUNDS" "$LOGHITS" "$KEYNOTE_VERSION" \
  "$(printf '%s' "$PDF" | json_string)" "$PASS"
[[ "$PASS" == true ]]
