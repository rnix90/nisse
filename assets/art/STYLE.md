# nisse mascot style guide

The nisse mascot is a gnome (a tomte): a tall hooked cap over one round white beard-body, a small skin band with two
eyes, and a nose. It is made by scripts (`tools/art/mascot_final.py`, built on `mascot_round5.py` and `mascot_round4.py`)
from the Ember palette (`assets/palette/ember.json`). The review history is in `assets/art/MASCOT-REVIEWS.md`.

The master was chosen in rounds: Bert picked the round-4 "gumdrop" body with the face of the round-4 "robe", and the
pickaxe carried across the body in two hands as the working pose.

## The rules

1. **One width.** The mascot keeps to one width: the cap base, the face and the top of the beard are the same width
   (180 units on the figure canvas). A beard that is wider or narrower than the head is a defect.
2. **The head touches the body.** There is no neck gap. The beard IS the body, so nothing floats.
3. **Flat shapes only.** The hooked cap, circles, rounded rectangles and one curved crescent. No outlines, no
   gradients, no filters, no shading, no highlights.
4. **At most six colors in any drawing**, all from the Ember palette (tested).
5. **The hooked cap is the brand atom.** It is the same hooked shape as the logo, one flat Ember shape, with no band
   and no shading. It is always the largest Ember mass; nothing else big is Ember.
6. **Leave out detail on purpose.** No brows, cheeks, ears, belts, hems, buttons, pockets or goggles. No blue, green or
   mustard robes (the reviews found them off-brand). The gnome wears no robe: the beard is the body.

## Colors by role (dark set tokens)

| Part | Token | Hex |
|---|---|---|
| Cap and nose | accent (Ember) | `#e0623f` |
| Face band and hands and arms | accent-text | `#f28463` |
| Beard and body | text (Paper) | `#f6f2e9` |
| Eyes | base (Ink) | `#1b2330` |
| Boots and the pickaxe handle | accent-pressed | `#bd573c` |
| Steel, the pick head | text-muted | `#aab1bd` |
| Motion arcs of the wave | outline | `#7a8699` |
| Head badge disc | surface | `#222c3b` |
| Head badge hill | surface-2 | `#2b3749` |

A light-mode set is an open follow-up (the badge disc and hill would use the light surfaces).

## Proportions (figure canvas 400 x 600, centered on x = 200)

| Part | Value |
|---|---|
| Cap | the logo's hooked path scaled to 180 wide, 203 tall, base line y = 300 |
| Face band | 180 wide, 78 tall, corner radius 24, top at y = 292 (the cap covers its first 8) |
| Eyes | two circles, radius 9, 38 left and right of center, 28 below the cap base |
| Nose | one circle, radius 20, centered on the skin and beard line (y = 356) |
| Beard-body | 180 wide, a scooped top edge, straight sides, a round bottom at y = 534 |
| Boots | two ellipses, radius 28 by 13, centers 34 either side of center, y = 538 |
| Hands | circles, radius 15 (18 for a waving hand), no outline |
| Strokes | arm 20, pickaxe and hammer handle 15, motion arcs 5, round caps; nothing else is stroked |
| Pick head | one crescent that tapers to a point at each end, 146 wide, steel |

## The head badge (avatar)

A 512 x 512 disc (radius 236) on the surface color with the hill of the logo behind. The art is scaled 1.3 and
placed so the cap tip lands near the top of the disc; the beard crops at the bottom edge. The face must stay readable
at 48 px and the cap and nose at 24 px; the final sheet shows 128, 96, 64, 48 and 24 px on dark and on Paper.

## The poses

| Pose | File | What it shows |
|---|---|---|
| Head badge | `nisse-gnome-head.svg` | the avatar crop |
| Standing | `nisse-gnome-standing.svg` | hands at the sides |
| Waving | `nisse-gnome-waving.svg` | the right arm raised, an open round hand, two arcs |
| Working | `nisse-gnome-working.svg` | the pickaxe carried flat across the body in two hands, the head to the right |

Other tools are parked as activity poses for later (the round-5 sheet has a leaning pickaxe, a raised hammer and a
hanging lantern). Any new pose follows the six rules above.

## How the files are made

`python tools/art/mascot_final.py` writes the four SVGs and a review sheet to `assets/art/mascot/`. Each SVG keeps its
master under `assets/art/` for Pocket nisse (N-D08). The tests in `tools/art/tests/` check ASCII, the licence header,
palette-only colors, the six-color budget, the one-width rule and that the head touches the body.
