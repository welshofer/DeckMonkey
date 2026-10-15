#!/usr/bin/env python3
"""golden.py — Gate 4 (AT-24) reference decks: Keynote builds a Deck IR fixture itself.

usage: Scripts/gate4/golden.py <fixture.json> <template.key> <out.key>

Keynote opens a tokened copy of the template, adds one slide per IR slide on the master the IR
layout maps to (the same table as DeckIRWriter), sets the placeholder text through its own
AppleScript dictionary, deletes the template's sample slides and saves. The golden is Keynote's
own rendering of the same content: DeckMonkey's output must match it at 0 mismatched pixels.

AppleScript cannot set a paragraph's list level, so a fixture with sub-bullets cannot be built
here (exit 3): those fixtures need hand-built reference decks.
"""
import json, os, shutil, subprocess, sys, tempfile, uuid

MASTERS = {"title": ["Title"], "sectionHeader": ["Section"], "bullets": ["Title & Bullets"],
           "agenda": ["Agenda", "Title & Bullets"], "statement": ["Statement"], "bigNumber": ["Big Fact"],
           "quote": ["Quote"], "closing": ["Title"]}


def q(s):
    """An AppleScript string literal; paragraphs joined with `return` (AppleScript has no escapes for it)."""
    parts = [p.replace("\\", "\\\\").replace('"', '\\"') for p in s.split("\n")]
    return " & return & ".join(f'"{p}"' for p in parts) if parts else '""'


def slide_script(slide, meta):
    layout, body = slide["layout"], slide.get("body") or {}
    title, out = slide.get("title"), []
    def title_(text):
        if text is not None: out.append(f"set object text of default title item of s to {q(text)}")
    def body_(text):
        if text is not None: out.append(f"set object text of default body item of s to {q(text)}")
    def box(text):
        # Text items include the placeholders (the body twice, a hidden title at width 0): the free
        # text box is the first item still empty, with a width, once the body is set (called after).
        if text is None: return
        out.append("set box to missing value")
        out.append("repeat with i from 1 to count of text items of s")
        out.append("  if box is missing value and (object text of text item i of s) is \"\" and (width of text item i of s) > 0 then set box to text item i of s")
        out.append("end repeat")
        out.append('if box is missing value then error "no free text box on this master"')
        out.append(f"set object text of box to {q(text)}")
    if layout == "title":
        title_(title or meta.get("title")); body_(body.get("subtitle") or (meta.get("subtitle") if title is None else None))
    elif layout == "sectionHeader":
        title_(title); body_(body.get("kicker"))
    elif layout == "bullets":
        title_(title)
        bullets = body.get("bullets") or []
        if any(b.get("subBullets") for b in bullets): raise SystemExit(3)
        body_("\n".join(b["text"] for b in bullets))
    elif layout == "agenda":
        title_(title); body_("\n".join(body.get("items") or []))
    elif layout == "statement":
        body_(body.get("claim") or title)
    elif layout == "bigNumber":
        body_(body.get("value")); box(body.get("label"))
    elif layout == "quote":
        body_(body.get("quote")); box(body.get("attribution"))
    elif layout == "closing":
        title_(body.get("callToAction") or title); body_(body.get("contact"))
    else:
        raise SystemExit(f"unsupported layout {layout}")
    if slide.get("notes") is not None:
        out.append(f"set presenter notes of s to {q(slide['notes'])}")
    return out


def main():
    if len(sys.argv) != 4: raise SystemExit(__doc__)
    fixture, template, out = sys.argv[1:]
    ir = json.load(open(fixture, encoding="utf-8"))
    token = "oracle-" + uuid.uuid4().hex[:8]
    work = tempfile.mkdtemp(prefix="deckmonkey-golden.")
    copy = os.path.join(work, f"{token}-template.key")
    shutil.copytree(template, copy) if os.path.isdir(template) else shutil.copy(template, copy)
    saved = os.path.join(work, f"{token}-golden.key")
    lines = []
    for slide in ir["slides"]:
        masters = MASTERS.get(slide["layout"])
        if not masters: raise SystemExit(f"unsupported layout {slide['layout']}")
        # One single-line `if` per candidate, least preferred first, so the preferred master wins.
        lines.append("set l to missing value")
        for m in reversed(masters):
            lines.append(f'if exists (first slide layout of d whose name is "{m}") then set l to (first slide layout of d whose name is "{m}")')
        lines.append('if l is missing value then error "the template has no master for ' + slide["layout"] + '"')
        lines.append("tell d to set s to make new slide at end of slides with properties {base layout:l}")
        lines += slide_script(slide, ir.get("meta") or {})
    script = f'''on run argv
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
      set originals to count of slides of d
      try
''' + "\n".join("        " + l for l in lines) + '''
        repeat originals times
          delete slide 1 of d
        end repeat
        save d in out
      on error message
        close (every document whose name contains token) saving no
        error message
      end try
      close (every document whose name contains token) saving no
    end tell
  end timeout
  return "saved"
end run'''
    r = subprocess.run(["osascript", "-", copy, token, saved], input=script, capture_output=True, text=True)
    if r.stdout.strip() != "saved" or not os.path.exists(saved):
        raise SystemExit(f"Keynote did not build the golden: {r.stderr.strip() or r.stdout.strip()}")
    if os.path.exists(out): shutil.rmtree(out) if os.path.isdir(out) else os.remove(out)
    shutil.move(saved, out)
    print(out)


if __name__ == "__main__":
    main()
