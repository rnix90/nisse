#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-505: judge a screenshot of nisse's Plasma splash (the real ksplashqml in a live VM, see tools/vm/splash_vm_check.py).

    splash_check.py --dark  SHOT [SHOT ...]    Ink all round, the Paper n in the middle, the Ember comet ring round it, nothing else
    splash_check.py --light SHOT [SHOT ...]    the light look: Paper all round, the Ink n, the brick comet ring

The approved mock (assets/art/boot/splash-*.png) is Ink (or Paper), the n with its tipped hat, 260 px at 1080 p, inside the comet ring, and no
text. Pure Pillow and numpy. Exit 0 when every picture passes, 1 otherwise (the reasons are printed), 64 for a wrong command line.
"""
import sys
from dataclasses import dataclass, field

import numpy as np
from PIL import Image

INK = (0x1b, 0x23, 0x30)
PAPER = (0xf6, 0xf2, 0xe9)
EMBER = (0xe0, 0x62, 0x3f)
BRICK = (0xbd, 0x45, 0x25)

LOOKS = {"dark": dict(bg=INK, fg=PAPER, ring=EMBER), "light": dict(bg=PAPER, fg=INK, ring=BRICK)}


@dataclass
class Result:
    ok: bool
    problems: list = field(default_factory=list)


def _close(a, color, tol):
    return (np.abs(a - np.array(color)).max(axis=2) <= tol)


def check_splash(img, look="dark"):
    a = np.asarray(img.convert("RGB")).astype(int)
    h, w = a.shape[:2]
    want = LOOKS[look]
    problems = []
    bg = _close(a, want["bg"], 6)
    corners = [bg[:20, :20], bg[:20, -20:], bg[-20:, :20], bg[-20:, -20:]]
    if not all(c.mean() > 0.98 for c in corners):
        problems.append(f"the screen is not {look} {want['bg']} all round (a corner is another color)")
    # everything that is not the background must sit in the middle: a disc round the centre, as wide as the ring (24 units of 18 px at most)
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.hypot(xx - w / 2, yy - h / 2)
    outside = (~bg) & (r > min(h, w) * 0.34)
    if outside.sum() > 60:
        problems.append(f"{int(outside.sum())} pixels of something else outside the middle: the splash shows only the n and the ring (no text, no logo)")
    n_px = int(_close(a, want["fg"], 22)[(r < min(h, w) * 0.16)].sum())
    if n_px < 1500:
        problems.append(f"no n in the middle ({n_px} pixels of {want['fg']}, at least 1500)")
    ring = _close(a, want["ring"], 26)
    ring_px = int(ring[(r > min(h, w) * 0.17) & (r < min(h, w) * 0.34)].sum())
    if ring_px < 1500:
        problems.append(f"no comet ring round the n ({ring_px} pixels of {want['ring']}, at least 1500)")
    inner = int(ring[r < min(h, w) * 0.12].sum())
    if inner > 80:
        problems.append("the ring runs through the n: it should sit round it")
    # centered: the n's pixels balance round the middle
    ys, xs = np.nonzero(_close(a, want["fg"], 22) & (r < min(h, w) * 0.16))
    if len(xs) and (abs(xs.mean() - w / 2) > w * 0.03 or abs(ys.mean() - h / 2) > h * 0.04):
        problems.append(f"the n is not centered (its middle is at {xs.mean():.0f},{ys.mean():.0f}, the screen's at {w // 2},{h // 2})")
    return Result(not problems, problems)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) < 2 or argv[0] not in ("--dark", "--light"):
        print(__doc__)
        return 64
    look = argv[0][2:]
    bad = 0
    for p in argv[1:]:
        res = check_splash(Image.open(p), look)
        print(("ok   " if res.ok else "FAIL ") + p)
        for problem in res.problems:
            print("       " + problem)
        bad += 0 if res.ok else 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
