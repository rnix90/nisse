#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-502: judge photos of the GRUB menu (QEMU screendumps, see tools/vm/grub_boot.sh) against the approved mock
(assets/art/boot/grub-menu.png for an installed system, grub-menu-live.png for the live ISO). Pure Pillow, no VM needed.

    grub_check.py menu --rows N SHOT [SHOT ...]    every photo is the nisse menu with N rows: Ink all round, the logo, the first row
                                                   an Ember box with words in it, the other rows with words and no Ember, the
                                                   countdown line, the track of the countdown bar, the hint line, and no other Ember

GRUB draws its text with its own fonts, so this does not compare pixels with the mock; it checks that every part of the mock is in
the place the theme puts it (the geometry is the theme's, tools/art/grub_theme.py). Exit 0 when every check passes, 1 otherwise;
the reasons are printed.
"""
import sys
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools" / "art"))
import grub_theme as gt  # noqa: E402

SIZE = (1920, 1080)
INK = (0x1b, 0x23, 0x30)
EMBER = (0xe0, 0x62, 0x3f)
SURFACE = (0x23, 0x2d, 0x3c)
OUTLINE = (0x7a, 0x86, 0x99)
ROW_X = (SIZE[0] - gt.ROW_W) // 2
LOGO_BOX = (SIZE[0] // 2 - gt.LOGO_W // 2, gt.LOGO_TOP, SIZE[0] // 2 + gt.LOGO_W // 2, gt.LOGO_TOP + 245)
COUNTDOWN_BOX = (700, gt.COUNTDOWN_TOP + 2, 1220, gt.COUNTDOWN_TOP + 42)
TRACK_BOX = (SIZE[0] // 2 - gt.BAR_W // 2, gt.BAR_TOP, SIZE[0] // 2 + gt.BAR_W // 2, gt.BAR_TOP + gt.BAR_H)
HINT_BOX = (740, gt.HINT_TOP + 2, 1180, gt.HINT_TOP + 40)
MAX_ROWS = 4


@dataclass
class Result:
    ok: bool
    problems: list = field(default_factory=list)


def row_box(i):
    y = gt.ROWS_TOP + i * gt.ROW_PITCH
    return (ROW_X, y, ROW_X + gt.ROW_W, y + gt.ROW_H)


def _near(a, b, tol):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def _count(img, box, test):
    px = img.crop(box).load()
    w, h = box[2] - box[0], box[3] - box[1]
    return sum(1 for x in range(w) for y in range(h) if test(px[x, y]))


def _words_on_ember(p):      # Ink-ish pixels on the Ember row
    return p[0] < 90 and p[1] < 90 and p[2] < 110


def _words_on_ink(p):        # light pixels on the Ink screen
    return p[0] > 140 and p[1] > 140 and p[2] > 140


def _ember(p):
    return _near(p, EMBER, 20)


def text_center(img, i):
    """The middle (x) of the words in row i (the first row's are Ink on Ember, the others light on Ink), or None when there are none.
    Only the part inside the row's rounded ends counts, so the Ember corners and the screen's edge do not."""
    img = img.convert("RGB")
    box = row_box(i)
    inner = (box[0] + 16, box[1] + 6, box[2] - 16, box[3] - 6)
    test = _words_on_ember if i == 0 else _words_on_ink
    px = img.crop(inner).load()
    w, h = inner[2] - inner[0], inner[3] - inner[1]
    cols = [x for x in range(w) if any(test(px[x, y]) for y in range(h))]
    return (min(cols) + max(cols)) / 2 + inner[0] if cols else None


CENTER_TOLERANCE = 16     # px: a space is about 8 px and the selected row's Bold is wider than the others' Regular (N-502c)


def bar_fraction(img):
    """How much of the countdown bar is filled (0 to 1), or None when there is no Ember run in it."""
    img = img.convert("RGB")
    y = (TRACK_BOX[1] + TRACK_BOX[3]) // 2
    x0, x1 = TRACK_BOX[0] + gt.BAR_PAD, TRACK_BOX[2] - gt.BAR_PAD
    run = 0
    for x in range(x0, x1):
        if _ember(img.getpixel((x, y))):
            run += 1
        else:
            break
    return run / (x1 - x0) if run else None


def check_menu(img, rows):
    img = img.convert("RGB")
    problems = []
    if img.size != SIZE:
        return Result(False, [f"the photo is {img.size[0]}x{img.size[1]}, not {SIZE[0]}x{SIZE[1]}"])
    for corner in ((5, 5), (1914, 5), (5, 1074), (1914, 1074)):
        if not _near(img.getpixel(corner), INK, 3):
            problems.append(f"the background at {corner} is {img.getpixel(corner)}, not Ink {INK}")
    if _count(img, LOGO_BOX, lambda p: not _near(p, INK, 12)) < 3000:
        problems.append("no logo where the theme puts it")
    first = row_box(0)
    inside = (first[0] + 20, first[1] + 4, first[2] - 20, first[3] - 4)
    share = _count(img, inside, _ember) / ((inside[2] - inside[0]) * (inside[3] - inside[1]))
    if share < 0.7:
        problems.append(f"the selected row (the first) is not an Ember box ({share * 100:.0f}% Ember, expected at least 70%)")
    elif _count(img, (SIZE[0] // 2 - 150, first[1] + 4, SIZE[0] // 2 + 150, first[3] - 4), _words_on_ember) < 150:
        problems.append("the selected row has no words in it (Ink on Ember)")
    if _ember(img.getpixel((first[0] + 1, first[1] + 1))):
        problems.append("the corners of the selected row are not rounded")
    for i in range(1, MAX_ROWS):
        words = _count(img, row_box(i), _words_on_ink)
        if i < rows and words < 150:
            problems.append(f"row {i + 1} has no words in it ({words} light pixels, expected at least 150)")
        if i >= rows and words > 60:
            problems.append(f"row {i + 1} is drawn but the menu should have {rows} rows")
    if rows >= 1 and _count(img, row_box(rows - 1), lambda p: True) == 0:
        problems.append("the row count is wrong")
    for i in range(1, MAX_ROWS):
        if _count(img, row_box(i), _ember) > 40:
            problems.append(f"row {i + 1} is Ember, but only the first row may be selected")
    for i in range(min(rows, MAX_ROWS)):
        c = text_center(img, i)
        if c is not None and abs(c - SIZE[0] / 2) > CENTER_TOLERANCE:
            problems.append(f"the words of row {i + 1} are not centered (their middle is at x={c:.0f}, the screen's is {SIZE[0] // 2})")
    outside = 0
    full = img.load()
    boxes = [row_box(0), (TRACK_BOX[0], TRACK_BOX[1], TRACK_BOX[2], TRACK_BOX[3])]
    for y in range(0, SIZE[1], 2):
        for x in range(0, SIZE[0], 2):
            if _ember(full[x, y]) and not any(b[0] <= x < b[2] and b[1] <= y < b[3] for b in boxes):
                outside += 1
    if outside > 12:
        problems.append(f"Ember outside the selected row and the countdown bar ({outside} sampled pixels): something else is drawn")
    if _count(img, COUNTDOWN_BOX, _words_on_ink) < 100:
        problems.append("no countdown line above the bar")
    mid = (TRACK_BOX[1] + TRACK_BOX[3]) // 2
    left = [img.getpixel((x, mid)) for x in range(TRACK_BOX[0], TRACK_BOX[0] + 4)]
    right = [img.getpixel((x, mid)) for x in range(TRACK_BOX[2] - 4, TRACK_BOX[2])]
    if not (any(_near(p, OUTLINE, 30) for p in left) and any(_near(p, OUTLINE, 30) for p in right)):
        problems.append("no track for the countdown bar (the pill's edge is not where the theme puts it)")
    if _count(img, HINT_BOX, _words_on_ink) < 100:
        problems.append("no hint line at the bottom")
    return Result(not problems, problems)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) < 4 or argv[0] != "menu" or "--rows" not in argv:
        print(__doc__)
        return 64
    rows = int(argv[argv.index("--rows") + 1])
    paths = [a for i, a in enumerate(argv[1:], 1) if not a.startswith("--") and argv[i - 1] != "--rows"]
    bad = 0
    for p in paths:
        r = check_menu(Image.open(p), rows)
        print(("ok   " if r.ok else "FAIL ") + p)
        for problem in r.problems:
            print("       " + problem)
        bad += 0 if r.ok else 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
