#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-501: judge photos of the Plymouth boot screen (QEMU screendumps, see tools/vm/plymouth_boot.sh) against the approved mock
(assets/art/boot/plymouth-boot.png, N-412). Pure Pillow, no VM needed.

    plymouth_check.py boot SHOT [SHOT ...]          every photo is the boot screen of the mock (the bar's inside excepted, the blocks
                                                    move) with at most three Ember blocks; with two or more photos the blocks must
                                                    also have moved between them
    plymouth_check.py password SHOT --typed N       the password screen: the prompt, the field and N Ember dots, and no bar

Exit 0 when every check passes, 1 otherwise; the reasons are printed.
"""
import sys
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import imgdiff  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
MOCK = ROOT / "assets" / "art" / "boot" / "plymouth-boot.png"
SIZE = (1920, 1080)
INK = (0x1b, 0x23, 0x30)
EMBER = (0xe0, 0x62, 0x3f)
OUTLINE = (0x7a, 0x86, 0x99)
LOGO_BOX = (830, 250, 1090, 570)       # the stacked logo of the 1080p mock
BAR_BOX = (749, 744, 1171, 776)        # the track
BAR_INNER = (756, 751, 1164, 769)      # where the blocks slide
PROMPT_BAND = (800, 680, 1120, 730)    # where a password prompt's words go
DIFF_TOLERANCE = 0.002                 # share of the screen that may differ from the mock outside the bar's inside


@dataclass
class Result:
    ok: bool
    problems: list = field(default_factory=list)


def _near(a, b, tol):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def _runs(pixels, want, tol=28, min_len=5):
    """Lengths of the runs of a color in a row of pixels."""
    runs, n = [], 0
    for p in pixels:
        if _near(p, want, tol):
            n += 1
        else:
            if n >= min_len:
                runs.append(n)
            n = 0
    if n >= min_len:
        runs.append(n)
    return runs


def _mid_row(img, box):
    y = (box[1] + box[3]) // 2
    return [img.getpixel((x, y)) for x in range(box[0], box[2])]


def count_blocks(img):
    """How many Ember blocks are in the bar (a block cut off by the track's end still counts)."""
    return len(_runs(_mid_row(img.convert("RGB"), BAR_INNER), EMBER))


def _block_center(img):
    img = img.convert("RGB")
    xs = []
    for y in range(BAR_INNER[1], BAR_INNER[3], 4):
        for x in range(BAR_INNER[0], BAR_INNER[2]):
            if _near(img.getpixel((x, y)), EMBER, 28):
                xs.append(x)
    return sum(xs) / len(xs) if xs else None


def blocks_moved(imgs):
    """True when the blocks are in at least two different places across the photos."""
    centers = [c for c in (_block_center(i) for i in imgs) if c is not None]
    return len(centers) >= 2 and max(centers) - min(centers) > 5


def check_boot_screen(img, mock=None):
    img = img.convert("RGB")
    problems = []
    if img.size != SIZE:
        return Result(False, [f"the photo is {img.size[0]}x{img.size[1]}, not {SIZE[0]}x{SIZE[1]}"])
    for corner in ((5, 5), (1914, 5), (5, 1074), (1914, 1074)):
        if not _near(img.getpixel(corner), INK, 3):
            problems.append(f"the background at {corner} is {img.getpixel(corner)}, not Ink {INK}")
    mock = mock if mock is not None else Image.open(MOCK)
    diff = imgdiff.compare(img, mock, tolerance=DIFF_TOLERANCE, masks=[BAR_INNER])
    if not diff.ok:
        problems.append(f"the screen differs from the approved mock in {diff.fraction * 100:.2f}% of its pixels (the logo or the track is wrong)")
    n = count_blocks(img)
    if n > 3:
        problems.append(f"{n} Ember blocks in the bar, at most 3 expected")
    return Result(not problems, problems)


def check_password_screen(img, typed):
    img = img.convert("RGB")
    problems = []
    if img.size != SIZE:
        return Result(False, [f"the photo is {img.size[0]}x{img.size[1]}, not {SIZE[0]}x{SIZE[1]}"])
    y = (BAR_BOX[1] + BAR_BOX[3]) // 2
    left = [img.getpixel((x, y)) for x in range(BAR_BOX[0] - 2, BAR_BOX[0] + 5)]
    right = [img.getpixel((x, y)) for x in range(BAR_BOX[2] - 5, BAR_BOX[2] + 2)]
    if not (any(_near(p, OUTLINE, 24) for p in left) and any(_near(p, OUTLINE, 24) for p in right)):
        problems.append("no password field (the pill's edge is not where the bar's track is)")
    band = img.crop(PROMPT_BAND)
    px = band.load()
    words = sum(1 for x in range(band.width) for y in range(band.height) if not _near(px[x, y], INK, 10))
    if words < 150:
        problems.append(f"no prompt above the field ({words} pixels of words in the band, expected at least 150)")
    dots = len(_runs(_mid_row(img, (BAR_BOX[0] + 8, BAR_BOX[1], BAR_BOX[2] - 8, BAR_BOX[3])), EMBER, min_len=6))
    if dots != typed:
        problems.append(f"{dots} Ember dots in the field, {typed} characters were typed")
    return Result(not problems, problems)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) < 2 or argv[0] not in ("boot", "password"):
        print(__doc__)
        return 64
    mode = argv[0]
    typed = int(argv[argv.index("--typed") + 1]) if "--typed" in argv else 0
    paths = [a for i, a in enumerate(argv[1:], 1) if not a.startswith("--") and argv[i - 1] != "--typed"]
    imgs = [Image.open(p) for p in paths]
    bad = 0
    for p, im in zip(paths, imgs):
        r = check_boot_screen(im) if mode == "boot" else check_password_screen(im, typed)
        print(("ok   " if r.ok else "FAIL ") + p)
        for problem in r.problems:
            print("       " + problem)
        bad += 0 if r.ok else 1
    if mode == "boot" and len(imgs) >= 2:
        if blocks_moved(imgs):
            print("ok   the blocks move between the photos")
        else:
            print("FAIL the blocks are in the same place in every photo: the bar is not animating")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
