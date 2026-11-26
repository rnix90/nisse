#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-503: judge screenshots of the login screen (Plasma Login Manager's greeter in a VM, `vmserver.py call PORT shot`).

    login_check.py --idle  SHOT [SHOT ...]    the screen nobody has touched: the nisse wallpaper sharp (dark, with the Ember sun), the clock
    login_check.py --awake SHOT [SHOT ...]    after a key press: the greeter blurs the wallpaper, so the sun is only a soft glow

The greeter's own layout (clock, avatar, password box) is Plasma's, so this judges what nisse sets: the wallpaper and the colors. It
refuses Fedora's cityscape (bright blue-violet), a bright screen, a missing sun and a missing clock. Exit 0 when every picture passes,
1 otherwise (the reasons are printed), 64 for a wrong command line.
"""
import sys
from dataclasses import dataclass, field

import numpy as np
from PIL import Image


@dataclass
class Result:
    ok: bool
    problems: list = field(default_factory=list)


MAX_MEAN_LUMINANCE = 55        # the nisse wallpaper is dark (measured 42); Fedora's cityscape is 63 to 76
MAX_BLUE_SHARE = 0.02          # pixels clearly blue (Fedora's cityscape: more than a quarter of the screen, nisse: none)
MIN_SUN_IDLE = 1500            # Ember pixels of the sharp sun (measured 5780)
MIN_SUN_AWAKE = 300            # the blurred sun still glows (measured 674)
MIN_CLOCK = 4000               # light peach pixels of the clock and date (measured 10000 to 12000)


def check_login(img, awake):
    a = np.asarray(img.convert("RGB")).astype(int)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    problems = []
    if a.mean() > MAX_MEAN_LUMINANCE:
        problems.append(f"the screen is not dark enough (mean brightness {a.mean():.0f}, at most {MAX_MEAN_LUMINANCE}): not the nisse wallpaper")
    blue = ((b - r > 60) & (b > 100)).mean()
    if blue > MAX_BLUE_SHARE:
        problems.append(f"{blue * 100:.0f}% of the screen is blue: this is Fedora's cityscape, not the nisse wallpaper")
    sun = int(((r > 150) & (r - b > 90) & (g > 40) & (g < 130)).sum())
    need = MIN_SUN_AWAKE if awake else MIN_SUN_IDLE
    if sun < need:
        problems.append(f"no Ember sun in the wallpaper ({sun} Ember pixels, at least {need})")
    top = a[: a.shape[0] // 3]
    clock = int(((top[:, :, 0] > 220) & (top[:, :, 1] > 180) & (top[:, :, 1] < 235) & (top[:, :, 2] > 130) & (top[:, :, 2] < 200)).sum())
    if clock < MIN_CLOCK:
        problems.append(f"no clock at the top of the screen ({clock} light peach pixels, at least {MIN_CLOCK})")
    return Result(not problems, problems)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] not in ("--idle", "--awake") or len(argv) < 2:
        print(__doc__)
        return 64
    awake = argv[0] == "--awake"
    bad = 0
    for p in argv[1:]:
        res = check_login(Image.open(p), awake)
        print(("ok   " if res.ok else "FAIL ") + p)
        for problem in res.problems:
            print("       " + problem)
        bad += 0 if res.ok else 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
