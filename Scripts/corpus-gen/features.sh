#!/bin/bash
# features.sh — Corpus/features (docs/spec.md §11): one deck per feature, authored by Keynote.
#
# usage: Scripts/corpus-gen/features.sh [--out Corpus/features] [--only <feature>]...
#
# Like corpus-gen.sh, this only asks Keynote to create, fill and save new documents (Basic White,
# wide), and touches nothing else. Media assets are synthesized here (generated images, `say`
# audio, a QuickTime export of a template deck), so nothing external enters the corpus.
#
# Keynote's AppleScript dictionary cannot create hyperlinks, smart fields, equations, groups or
# builds, nor set interactive cell formats or slide-number visibility: those features need
# hand-authored decks. Objects are created by telling the slide (`tell s to make new …`); the
# `make new … at …` forms fail with "AppleEvent handler failed". Movies and audio are made as
# images of a media file (`make new movie` silently makes nothing).

set -euo pipefail

OUT="Corpus/features"
ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --only) ONLY+=("$2"); shift 2 ;;
    *) echo "usage: $0 [--out dir] [--only feature]..." >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$(mktemp -d /tmp/deckmonkey-assets.XXXXXX)"
trap 'rm -rf "$ASSETS"' EXIT

# --- Assets ----------------------------------------------------------------------------------------

python3 - "$ASSETS" <<'PY'
import struct, sys, zlib
out = sys.argv[1]
def png(w, h, pixel):
    raw = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(f"{out}/gradient.png", "wb").write(png(320, 240, lambda x, y: (x * 255 // 319, y * 255 // 239, 160)))
open(f"{out}/checker.png", "wb").write(png(256, 256, lambda x, y: (240, 240, 240) if (x // 32 + y // 32) % 2 else (30, 30, 30)))
open(f"{out}/large.png", "wb").write(png(1600, 1200, lambda x, y: ((x * 7) % 256, (y * 5) % 256, ((x + y) * 3) % 256)))
PY
sips -s format jpeg "$ASSETS/gradient.png" --out "$ASSETS/gradient.jpg" >/dev/null
sips -s format gif "$ASSETS/checker.png" --out "$ASSETS/checker.gif" >/dev/null
say -o "$ASSETS/voice.aiff" "DeckMonkey feature corpus, audio sample."
afconvert -f m4af -d aac "$ASSETS/voice.aiff" "$ASSETS/voice.m4a"

# --- The runner: a fresh document, the feature's body, save, close --------------------------------

# argv: output path, asset dir. $BODY is spliced in; it sees d (document), s (slide 1), assets.
run_feature() {
  local name="$1" body="$2" file="$OUT/$1.key"
  rm -rf "$file"
  local head='on run argv
  set outFile to POSIX file (item 1 of argv)
  set assets to item 2 of argv
  with timeout of 900 seconds
    tell application id "com.apple.Keynote"
      set d to make new document with properties {document theme:(first theme whose id is "Application/21_BasicWhite/Standard"), width:1920, height:1080}
      try
        set s to slide 1 of d
        set blank to (first slide layout of d whose name is "Blank")'
  local tail='        set n to count of slides of d
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
end run'
  local script="$head"$'\n'"$body"$'\n'"$tail"
  if n=$(printf '%s\n' "$script" | osascript - "$file" "$ASSETS" 2>&1); then
    echo "made $name.key: $n slides"
  else
    echo "FAILED $name.key: $n" >&2
    return 1
  fi
}

wants() { [[ ${#ONLY[@]} -eq 0 ]] && return 0; for o in "${ONLY[@]}"; do [[ "$o" == "$1" ]] && return 0; done; return 1; }

NAMES=()
BODIES=()
feature() { NAMES+=("$1"); BODIES+=("$2"); }   # parallel arrays: bash 3.2 has no associative ones

# Multi-run text: several character styles in one paragraph (Phase 1 AT-16 needs style boundaries).
feature text-runs '
        set base layout of s to blank
        tell s to set t1 to make new text item with properties {object text:"Plain bold italic red large small"}
        set font of word 2 of object text of t1 to "Helvetica-Bold"
        set font of word 3 of object text of t1 to "Helvetica-Oblique"
        set color of word 4 of object text of t1 to {65535, 0, 0}
        set size of word 5 of object text of t1 to 72
        set size of word 6 of object text of t1 to 14
        tell s to set t2 to make new text item with properties {object text:"First paragraph of a second box." & return & "Second paragraph, with a blue phrase in it." & return & "Third paragraph."}
        set color of words 5 thru 6 of paragraph 2 of object text of t2 to {0, 0, 65535}
        set position of t2 to {200, 600}
        tell d to set s2 to make new slide with properties {base layout:blank}
        tell s2 to set t3 to make new text item with properties {object text:"alpha beta gamma delta epsilon zeta eta theta iota kappa"}
        repeat with i from 1 to 10 by 2
          set color of word i of object text of t3 to {(i * 6000), 20000, 40000}
        end repeat'

# Text beyond the Basic Multilingual Plane, combining marks, CJK: UTF-16 offsets differ from
# characters (iWork indexes text in UTF-16 code units).
feature text-unicode '
        set base layout of s to blank
        tell s to make new text item with properties {object text:"Emoji: 😀 👍🏽 👩‍💻 🇨🇭 end"}
        tell s to set t2 to make new text item with properties {object text:"Combining: é ä ñ · Precomposed: é ä ñ"}
        set position of t2 to {200, 500}
        tell d to set s2 to make new slide with properties {base layout:blank}
        tell s2 to make new text item with properties {object text:"中文 日本語 한국어 ไทย Ελληνικά Русский"}
        tell d to set s3 to make new slide with properties {base layout:blank}
        tell s3 to set t4 to make new text item with properties {object text:"Math 𝔸𝔹ℂ ∑∫√∞ and astral 𐍈 𓀀"}
        set color of word 2 of object text of t4 to {0, 40000, 0}'

feature text-bidi '
        set base layout of s to blank
        tell s to make new text item with properties {object text:"שלום עולם — Hebrew"}
        tell d to set s2 to make new slide with properties {base layout:blank}
        tell s2 to make new text item with properties {object text:"مرحبا بالعالم — Arabic"}
        tell d to set s3 to make new slide with properties {base layout:blank}
        tell s3 to make new text item with properties {object text:"Mixed: English עברית 123 العربية 456 English"}'

# Placeholder text: titles and bulleted bodies through the layouts that have them.
feature text-lists '
        set object text of default title item of s to "Lists"
        tell d to set s2 to make new slide
        if title showing of s2 then set object text of default title item of s2 to "Bullets"
        if body showing of s2 then set object text of default body item of s2 to "First point" & return & "Second point" & return & "Third point with more words in it" & return & "Fourth"
        tell d to set s3 to make new slide
        if body showing of s3 then set object text of default body item of s3 to "One long paragraph that wraps across several lines of the body placeholder, to give the text engine something to lay out and the offset tables more than one line of text to describe." & return & "A second paragraph."'

feature tables '
        set base layout of s to blank
        tell s to set t to make new table with properties {row count:5, column count:4}
        set value of cell "B2" of t to 10
        set value of cell "C2" of t to 32
        set value of cell "D2" of t to "=B2+C2"
        set value of cell "B3" of t to "text in a cell"
        set format of cell "C3" of t to currency
        set value of cell "C3" of t to 12.5
        set format of cell "D3" of t to percent
        set value of cell "D3" of t to 0.25
        set format of cell "B4" of t to date and time
        set value of cell "B4" of t to (current date)
        set format of cell "C4" of t to number
        set value of cell "C4" of t to 3.14159
        merge range "C5:D5" of t
        tell d to set s2 to make new slide with properties {base layout:blank}
        tell s2 to set big to make new table with properties {row count:12, column count:6}
        repeat with r from 2 to 12
          repeat with c from 2 to 6
            set value of cell c of row r of big to (r * 10 + c)
          end repeat
        end repeat
        set value of cell 6 of row 12 of big to "=SUM(B2:E11)"'

feature charts '
        set kinds to {pie_2d, vertical_bar_2d, stacked_vertical_bar_2d, horizontal_bar_2d, stacked_horizontal_bar_2d, pie_3d, vertical_bar_3d, stacked_vertical_bar_3d, horizontal_bar_3d, stacked_horizontal_bar_3d, area_2d, stacked_area_2d, line_2d, line_3d, area_3d, stacked_area_3d, scatterplot_2d}
        set base layout of s to blank
        set first_ to true
        repeat with k in kinds
          if first_ then
            set target to s
            set first_ to false
          else
            tell d to set target to make new slide with properties {base layout:blank}
          end if
          add chart target row names {"2024", "2025", "2026"} column names {"North", "South", "East", "West"} data {{3, 5, 2, 8}, {4, 6, 3, 7}, {6, 2, 5, 9}} type (contents of k) group by chart row
        end repeat'

feature shapes-lines '
        set base layout of s to blank
        tell s to set a to make new shape with properties {object text:"A shape with text"}
        tell s to set b to make new shape with properties {object text:"Second shape"}
        set position of b to {900, 300}
        set rotation of b to 15
        tell s to make new line
        tell d to set s2 to make new slide with properties {base layout:blank}
        repeat with i from 1 to 6
          tell s2 to set x to make new shape with properties {object text:("Shape " & i)}
          set position of x to {150 * i, 120 * i}
          set opacity of x to (100 - i * 10)
        end repeat'

feature images '
        set base layout of s to blank
        tell s to set i1 to make new image with properties {file:(POSIX file (assets & "/gradient.png"))}
        tell s to set i2 to make new image with properties {file:(POSIX file (assets & "/gradient.jpg"))}
        set position of i2 to {800, 100}
        tell s to set i3 to make new image with properties {file:(POSIX file (assets & "/checker.gif"))}
        set position of i3 to {400, 600}
        tell d to set s2 to make new slide with properties {base layout:blank}
        tell s2 to set i4 to make new image with properties {file:(POSIX file (assets & "/large.png"))}
        tell d to set s3 to make new slide with properties {base layout:blank}
        tell s3 to set i5 to make new image with properties {file:(POSIX file (assets & "/checker.png"))}
        set reflection showing of i5 to true
        set rotation of i5 to 20
        set opacity of i5 to 70'

# `make new movie` / `make new audio clip` report success and insert nothing; `make new image` with
# a movie or audio file makes the right object. The counts are checked so a silent no-op fails.
feature media '
        set base layout of s to blank
        tell s to make new image with properties {file:(POSIX file (assets & "/movie.m4v"))}
        tell d to set s2 to make new slide with properties {base layout:blank}
        tell s2 to make new image with properties {file:(POSIX file (assets & "/voice.m4a"))}
        if (count of movies of s) is not 1 or (count of audio clips of s2) is not 1 then error "media did not insert"'

feature notes-skipped '
        set object text of default title item of s to "Presenter notes and skipped slides"
        set presenter notes of s to "Notes on the first slide."
        repeat with i from 2 to 5
          tell d to set x to make new slide
          if title showing of x then set object text of default title item of x to ("Slide " & i)
          set presenter notes of x to ("Notes for slide " & i & ", with enough words to fill a line or two of the presenter view.")
          if i mod 2 = 0 then set skipped of x to true
        end repeat'

feature transitions '
        set effects to {magic move, shimmer, sparkle, swing, object cube, object flip, object pop, object push, object revolve, object zoom, perspective, clothesline, confetti, dissolve, drop, droplet, fade through color, grid, iris, move in, push, reveal, switch, wipe, blinds, color planes, cube, doorway, fall, flip, flop, mosaic, page flip, pivot, reflection, revolving door, scale, swap, swoosh, twirl, twist, fade and move, radial wipe}
        set object text of default title item of s to "Transitions"
        repeat with e in effects
          tell d to set x to make new slide
          if title showing of x then set object text of default title item of x to ((contents of e) as text)
          set transition properties of x to {transition effect:(contents of e), transition duration:1.0}
        end repeat'

feature many-slides '
        set object text of default title item of s to "Many slides"
        repeat with i from 2 to 80
          tell d to set x to make new slide
          if title showing of x then set object text of default title item of x to ("Slide " & i)
          if body showing of x then set object text of default body item of x to ("Body text for slide " & i)
        end repeat'

# --- Movie asset (a Keynote export of a template) and the run --------------------------------------

if wants media; then
  template="$(cd "$SCRIPT_DIR/../.." && pwd)/Corpus/templates/basic-white_standard.key"
  [[ -e "$template" ]] || { echo "media needs $template: run corpus-gen.sh first" >&2; exit 1; }
  printf '%s\n' 'on run argv
  tell application id "com.apple.Keynote"
    set d to open POSIX file (item 1 of argv)
    export d to POSIX file (item 2 of argv) as QuickTime movie with properties {movie format:format360p, movie codec:h264, movie framerate:FPS12}
    close d saving no
  end tell
end run' | osascript - "$template" "$ASSETS/movie.m4v" >/dev/null
fi

made=0; failed=0
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  wants "$name" || continue
  if run_feature "$name" "${BODIES[$i]}"; then made=$((made + 1)); else failed=$((failed + 1)); fi
done
echo "features: $made deck(s) in $OUT, $failed failed"
[[ $failed -eq 0 ]]
