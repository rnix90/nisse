#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-503: judge screenshots of the login screen (Plasma Login Manager's greeter in a VM, `vmserver.py call PORT shot`).

    login_check.py --idle  SHOT [SHOT ...]    the screen nobody has touched: the nisse wallpaper sharp (dark, with the Ember sun), the clock
    login_check.py --awake SHOT [SHOT ...]    after a key press: the greeter blurs the wallpaper, so the sun is only a soft glow
    login_check.py --logout SHOT [...]        (N-504) the logout screen with a countdown: Ink veil, Ember default circle, Cancel
    login_check.py --logout-all SHOT [...]    the logout screen with every option: also the question over the round buttons

The lock screen (N-504) has the same wallpaper, clock and colors as the login screen, so --idle and --awake judge it too.

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
MIN_CLOCK = 4000               # light pixels of the clock and date (measured 10000 to 12000)


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
    clock = int(((top[:, :, 0] > 220) & (top[:, :, 1] > 190) & (top[:, :, 2] > 140)).sum())   # the login clock is peach, the lock clock Paper
    if clock < MIN_CLOCK:
        problems.append(f"no clock at the top of the screen ({clock} light pixels, at least {MIN_CLOCK})")
    return Result(not problems, problems)


MIN_VEIL_BLUE = 8              # the nisse veil is Ink (27,35,48) at 82%: its blue runs ahead of its red; Breeze's black veil has none
MIN_VEIL_LUMINANCE = 18        # and it is not black: Ink at 82% over the desktop averages about 30; Breeze's black 85% about 8
MIN_DEFAULT_CIRCLE = 4000      # Ember pixels of the default round button (a 108 px circle is about 9000)
MIN_HEADING = 250              # light pixels of the question over the buttons


def check_logout(img, all_options):
    """The logout screen: the veil is the look's Ink (not black), the default round button is an Ember circle, Cancel is an Ember word and,
    with every option, the question is over the buttons."""
    a = np.asarray(img.convert("RGB")).astype(int)
    h, w = a.shape[:2]
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    problems = []
    # the veil, judged where nothing but the desktop is under it: the top strip
    strip = a[: h // 12]
    lum = strip.mean()
    blue = strip[:, :, 2].mean() - strip[:, :, 0].mean()
    if lum < MIN_VEIL_LUMINANCE or blue < MIN_VEIL_BLUE:
        problems.append(f"the veil is not nisse's Ink (top strip brightness {lum:.0f}, blue over red {blue:.0f}): this is Breeze's black one")
    ember = (r > 190) & (r - b > 110) & (g > 60) & (g < 130)
    centre = ember[h // 5: (h * 4) // 5, w // 5: (w * 4) // 5]
    if int(centre.sum()) < MIN_DEFAULT_CIRCLE:
        problems.append(f"no Ember circle for the default button ({int(centre.sum())} Ember pixels in the middle, at least {MIN_DEFAULT_CIRCLE})")
    low = int(ember[(h * 6) // 10:, w // 4: (w * 3) // 4].sum())
    if low < 120:
        problems.append(f"no Ember word (Cancel) under the buttons ({low} Ember pixels, at least 120)")
    if all_options:
        light = (r > 200) & (g > 200) & (b > 190)
        heading = int(light[h // 5: (h * 2) // 5, w // 5: (w * 4) // 5].sum())
        if heading < MIN_HEADING:
            problems.append(f"no question over the buttons ({heading} light pixels, at least {MIN_HEADING})")
    return Result(not problems, problems)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] not in ("--idle", "--awake", "--logout", "--logout-all") or len(argv) < 2:
        print(__doc__)
        return 64
    awake = argv[0] == "--awake"
    bad = 0
    for p in argv[1:]:
        if argv[0].startswith("--logout"):
            res = check_logout(Image.open(p), all_options=argv[0] == "--logout-all")
        else:
            res = check_login(Image.open(p), awake)
        print(("ok   " if res.ok else "FAIL ") + p)
        for problem in res.problems:
            print("       " + problem)
        bad += 0 if res.ok else 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
