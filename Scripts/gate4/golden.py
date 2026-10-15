#!/usr/bin/env python3
"""golden.py — Gate 4 (AT-24) reference decks: Keynote builds a deck plan itself.

usage: Scripts/gate4/golden.py <plan.json> <template.key> <out.key>

The plan is what `deckmonkey from-ir --plan-out` writes: for every slide its master, the text of
its placeholders and of the master's free text box, its notes, and its new shapes and text boxes
with frames in points. Keynote opens a tokened copy of the template, adds one slide per plan slide
on that master, sets the text and makes the drawables through its own AppleScript dictionary,
deletes the template's sample slides and saves. The golden is Keynote's own rendering of the same
content: DeckMonkey's output must match it at 0 mismatched pixels.

AppleScript cannot set a paragraph's list level (exit 3 for a plan that has one: those fixtures
need hand-built reference decks). Geometry: a shape's position and size are stored as given; a
text box keeps an automatic height, and AppleScript rounds the position it is given to whole points
before storing y + height / 2, so it is placed at y - height / 2, and a plan whose text box that
cannot reach exactly exits 4 (it needs a hand-built golden too).
"""
import json, os, shutil, subprocess, sys, tempfile, uuid


def q(paragraphs):
    """Paragraphs as an AppleScript string expression, joined with `return`."""
    parts = [p["text"].replace("\\", "\\\\").replace('"', '\\"') for p in paragraphs]
    return " & return & ".join(f'"{p}"' for p in parts) if parts else '""'


def slide_lines(slide):
    out = []
    every = [slide.get(k) or [] for k in ("title", "body", "box", "notes")] + [d["paragraphs"] for d in slide.get("drawables", [])]
    if any(p.get("level", 0) > 0 for ps in every for p in ps): raise SystemExit(3)
    out.append(f'set l to (first slide layout of d whose name is "{slide["master"]}")')
    out.append("tell d to set s to make new slide at end of slides with properties {base layout:l}")
    if slide.get("title") is not None: out.append(f"set object text of default title item of s to {q(slide['title'])}")
    if slide.get("body") is not None: out.append(f"set object text of default body item of s to {q(slide['body'])}")
    if slide.get("box") is not None:
        # Text items include the placeholders (the body twice, a hidden title at width 0): the free
        # text box is the first item still empty, with a width, once the body is set.
        out += ["set box to missing value",
                "repeat with i from 1 to count of text items of s",
                '  if box is missing value and (object text of text item i of s) is "" and (width of text item i of s) > 0 then set box to text item i of s',
                "end repeat",
                'if box is missing value then error "no free text box on this master"',
                f"set object text of box to {q(slide['box'])}"]
    if slide.get("notes") is not None: out.append(f"set presenter notes of s to {q(slide['notes'])}")
    if slide.get("table") is not None:
        cells = slide["table"]
        out.append(f"tell s to set t to make new table with properties {{row count:{len(cells)}, column count:{len(cells[0])}}}")
        if slide.get("tableFrame"):
            x, y, w, h = slide["tableFrame"]
            out += [f"set width of t to {w!r}", f"set height of t to {h!r}", f"set position of t to {{{x!r}, {y!r}}}"]
        for r, row in enumerate(cells, 1):
            for c, value in enumerate(row, 1):
                v = value.replace("\\", "\\\\").replace('"', '\\"')
                out.append(f'set value of cell {c} of row {r} of t to "{v}"')
    def strings(xs): return "{" + ", ".join('"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"' for x in xs) + "}"
    for d in slide.get("drawables", []):
        if d["kind"] == "chart":
            c = d["chart"]
            data = "{" + ", ".join("{" + ", ".join(repr(v) for v in row) + "}" for row in c["values"]) + "}"
            out += [f"add chart s row names {strings(c['rows'])} column names {strings(c['columns'])} data {data} type {c['appleScriptType']} group by chart row",
                    "set n to last chart of s",
                    f"set width of n to {d['width']!r}", f"set height of n to {d['height']!r}",
                    f"set position of n to {{{d['x']!r}, {d['y']!r}}}"]
        elif d["kind"] == "shape":
            out += [f"tell s to set n to make new shape with properties {{object text:{q(d['paragraphs'])}}}",
                    f"set width of n to {d['width']!r}", f"set height of n to {d['height']!r}",
                    f"set position of n to {{{d['x']!r}, {d['y']!r}}}"]
        else:
            # An auto-height text item: AppleScript rounds the position it is given to whole
            # points, then stores y + height / 2. Exact only when y - height / 2 is whole.
            out += [f"tell s to set n to make new text item with properties {{object text:{q(d['paragraphs'])}}}",
                    f"set width of n to {d['width']!r}", "set h to height of n",
                    f"set p to {d['y']!r} - h / 2",
                    'if p mod 1 is not 0 then error "inexact text box position"',
                    f"set position of n to {{{d['x']!r}, p}}"]
    return out


def main():
    if len(sys.argv) != 4: raise SystemExit(__doc__)
    plan_path, template, out = sys.argv[1:]
    plan = json.load(open(plan_path, encoding="utf-8"))
    token = "oracle-" + uuid.uuid4().hex[:8]
    work = tempfile.mkdtemp(prefix="deckmonkey-golden.")
    copy = os.path.join(work, f"{token}-template.key")
    shutil.copytree(template, copy) if os.path.isdir(template) else shutil.copy(template, copy)
    saved = os.path.join(work, f"{token}-golden.key")
    lines = [l for s in plan["slides"] for l in slide_lines(s)]
    script = '''on run argv
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
    if "inexact text box position" in r.stderr:
        print("AppleScript cannot place this plan's text box exactly (it rounds positions): needs a hand-built golden", file=sys.stderr)
        raise SystemExit(4)
    if r.stdout.strip() != "saved" or not os.path.exists(saved):
        raise SystemExit(f"Keynote did not build the golden: {r.stderr.strip() or r.stdout.strip()}")
    if os.path.exists(out): shutil.rmtree(out) if os.path.isdir(out) else os.remove(out)
    shutil.move(saved, out)
    print(out)


if __name__ == "__main__":
    main()
