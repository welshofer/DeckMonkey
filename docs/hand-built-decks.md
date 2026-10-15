# Hand-built reference decks for Gate 4

Gate 4 (AT-24) compares every deck DeckMonkey builds from a Deck IR fixture (`Corpus/ir/*.json`)
with Keynote's own build of the same content, at 0 mismatched pixels. For most fixtures Keynote
builds the reference itself through AppleScript (`Scripts/gate4/golden.py`). Two things
AppleScript cannot do exactly, so those fixtures need a deck built by hand in Keynote:

- **Sub-bullets.** AppleScript cannot set a paragraph's indent level.
- **Text boxes at an exact position.** AppleScript rounds a text box's position before Keynote
  adjusts it, so it can't land on the exact point DeckMonkey writes. The Arrange inspector can.

Seven decks. Each takes a few minutes. Save each one **beside its fixture** as
`Corpus/ir/<fixture>.golden.key`. `Scripts/gate4/gate4.py` picks it up instead of building one.
These files are git-ignored: like every deck, they never go to GitHub.

## How to build one (applies to all six)

1. **Start from the template copy, not from a theme.** In Finder, duplicate the template deck
   named for the fixture (`Corpus/templates/<theme>_wide.key`), rename the copy to
   `<fixture>.golden.key`, move it into `Corpus/ir/`, and open it in Keynote.
2. **Add the slides listed, in order, at the end:** Slide ▸ New Slide, then pick the named
   layout from the layout button in the Format sidebar (Slide Layout tab).
3. **Type the text exactly as listed.** Return starts a new paragraph. For a level-1 bullet,
   put the cursor in that paragraph and press **Tab** (Shift-Tab goes back to level 0).
4. **Leave every style alone.** No font, size, colour, alignment, spacing or fill changes.
   Everything must be the theme's defaults, because DeckMonkey only uses theme styles.
5. **Delete all the template's original sample slides**, so the deck holds only the slides listed.
6. **Leave placeholders not listed empty.** Don't type into them or delete them.
7. **Save** (⌘S). Keep the default single-file format.

**Text boxes** (cases 4–7): Insert ▸ Text Box, type the text, then in the Format sidebar's
**Arrange** tab type the exact **X**, **Y** and **Width** listed. Leave the height alone; it
follows the text.

**Shapes** (cases 4, 6 and 7): the Shape button in the toolbar ▸ Basic ▸ the plain square (first
one). In the **Arrange** tab, type the exact **X**, **Y**, **Width** and **Height**, then
double-click the shape and type its text.

Type positions as whole numbers, exactly as listed.

---

## 1. `23-subbullets.golden.key` — template `basic-color_wide.key`

One slide, layout **Title & Bullets**.

- Title: `What went well`
- Body (level in brackets):
  - `Revenue up 12%` (0)
  - `Strongest in EMEA` (1)
  - `Two new partners` (1)
  - `Churn down to 3%` (0)

## 2. `24-subbullets-deep.golden.key` — template `academy_wide.key`

One slide, layout **Title & Bullets**.

- Title: `Plan`
- Body:
  - `Phase one` (0)
  - `Discovery` (1)
  - `Design` (1)
  - `Phase two` (0)
  - `Build` (1)
  - `Ship` (1)

## 3. `25-subbullets-mixed.golden.key` — template `bold-color_wide.key`

Two slides.

Slide 1, layout **Title**:
- Title: `Roadmap`
- Subtitle (the body placeholder): `2027`

Slide 2, layout **Title & Bullets**:
- Title: `Priorities`
- Body:
  - `Customers` (0)
  - `Retention` (1)
  - `Platform` (0)
  - `People` (0)
  - `Hiring` (1)
  - `Growth` (1)

## 4. `32-cycle.golden.key` — template `minimalist-light_wide.key`

One slide, layout **Title Only**. Title: `Cycle`.

Four shapes (plain square, theme default style), each holding one word:

| Text | X | Y | Width | Height |
| --- | --- | --- | --- | --- |
| `Plan` | 95 | 335 | 857 | 317 |
| `Do` | 968 | 335 | 857 | 317 |
| `Check` | 968 | 668 | 857 | 317 |
| `Act` | 95 | 668 | 857 | 317 |

Three text boxes, each holding one arrow character (copy them from here), width 16:

| Text | X | Y | Width |
| --- | --- | --- | --- |
| `→` | 952 | 481 | 16 |
| `↓` | 1389 | 652 | 16 |
| `←` | 952 | 814 | 16 |

Make the shapes first and the text boxes after, in the order listed: z-order follows creation.

## 5. `34-two-column.golden.key` — template `color-gradient-light_wide.key`

One slide, layout **Title Only**. Title: `Before and after`.

Two text boxes, three paragraphs each:

| Text (one paragraph per line) | X | Y | Width |
| --- | --- | --- | --- |
| `Before` / `Manual` / `Slow` | 100 | 336 | 852 |
| `After` / `Automated` / `Fast` | 968 | 336 | 852 |

## 6. `35-callout.golden.key` — template `feature-story_wide.key`

One slide, layout **Title Only**. Title: `The lever`.

First a shape (plain square, theme default style):

| Text | X | Y | Width | Height |
| --- | --- | --- | --- | --- |
| `Revenue = price × volume` | 136 | 391 | 1648 | 121 |

Then a text box, two paragraphs:

| Text | X | Y | Width |
| --- | --- | --- | --- |
| `Price is fixed` / `Volume is the lever` | 136 | 536 | 1648 |

## 7. `30-process.golden.key` — template `briefing_wide.key`

One slide, layout **Title Only**. Title: `Process`.

Three shapes (plain square, theme default style), each with two paragraphs:

| Text (one paragraph per line) | X | Y | Width | Height |
| --- | --- | --- | --- | --- |
| `Collect` / `gather inputs` | 164 | 330 | 520 | 495 |
| `Analyse` / `find patterns` | 700 | 330 | 520 | 495 |
| `Decide` / `choose a path` | 1235 | 330 | 520 | 495 |

Then two text boxes, each holding `→`, width 16:

| Text | X | Y | Width |
| --- | --- | --- | --- |
| `→` | 684 | 566 | 16 |
| `→` | 1219 | 566 | 16 |

---

## Checking your work

Run `python3 -I Scripts/gate4/gate4.py` with the machine left alone (about 70 minutes for all
cases), or only these seven:

```sh
grep -E "^Corpus/ir/(23|24|25|30|32|34|35)-" Scripts/gate4/cases.tsv > /tmp/hand.tsv
python3 -I Scripts/gate4/gate4.py /tmp/hand.tsv
```

A case reports `PASS … every page identical to Keynote's own build`. If one differs, the report
gives the mismatched region. The usual causes are a typo, a style touched by accident, or a
position typed into the wrong field.
