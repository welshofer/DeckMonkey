#!/bin/bash
# resave.sh — AT-23 (docs/spec.md §14): Keynote opens a file and saves it again as a new file.
#
# usage: Scripts/resave.sh <in.key> <out.key>
# Exit 0 when Keynote saved <out.key>; 1 otherwise (2 on usage). Like oracle.sh it works on a copy
# named oracle-<token>-…, addresses only that document, and closes it without touching any other;
# keyboard or mouse input during the run fails it (Keynote is in front).

set -euo pipefail
[[ $# -eq 2 && -e "$1" ]] || { echo "usage: $0 <in.key> <out.key>" >&2; exit 2; }
IN="$1"; OUT="$2"
WORK="$(mktemp -d /tmp/deckmonkey-resave.XXXXXX)"
TOKEN="oracle-$(uuidgen | tr -d - | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
COPY="$WORK/$TOKEN-$(basename "$IN")"
cp -R "$IN" "$COPY"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -rf "$OUT"
RUN_START=$(date +%s)

read -r -d '' AS_RESAVE <<'APPLESCRIPT' || true
on run argv
  set f to POSIX file (item 1 of argv)
  set token to item 2 of argv
  set out to POSIX file (item 3 of argv)
  with timeout of 600 seconds
    tell application id "com.apple.Keynote"
      open f
      repeat 120 times
        if (count of (every document whose name contains token)) > 0 then exit repeat
        delay 0.5
      end repeat
      set d to first document whose name contains token
      save d in out
      set names to name of every document whose name contains token
      repeat with n in names
        close document (contents of n) saving no
      end repeat
    end tell
  end timeout
  return "saved"
end run
APPLESCRIPT

SAVED="$WORK/$TOKEN-resaved.key"   # tokened, so the renamed open document still matches the token
result=$(printf '%s\n' "$AS_RESAVE" | osascript - "$COPY" "$TOKEN" "$SAVED" 2>&1 || true)
IDLE=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !seen { printf "%d", $NF / 1000000000; seen = 1 }')
ELAPSED=$(( $(date +%s) - RUN_START ))
# Keynote renames the document to the saved file's name, which carries the token too.
printf '%s\n' 'on run argv
  tell application id "com.apple.Keynote"
    repeat with n in (name of every document whose name contains (item 1 of argv))
      close document (contents of n) saving no
    end repeat
  end tell
end run' | osascript - "$TOKEN" >/dev/null 2>&1 || true
if [[ -n "$IDLE" && "$IDLE" -lt "$ELAPSED" ]]; then echo "input reached the machine during the run: rerun" >&2; exit 1; fi
[[ "$result" == saved && -e "$SAVED" ]] || { echo "Keynote did not save: $result" >&2; exit 1; }
mv "$SAVED" "$OUT"
echo "$OUT"
