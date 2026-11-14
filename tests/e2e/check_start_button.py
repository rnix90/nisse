#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check the start button in a screenshot of the live desktop (1280x800, panel at the bottom, start button first at the left).

Exit 0 when the start button region shows nisse's mark and none of the Fedora placeholder (the hot dog: saturated
orange/brown/yellow); exit 1 otherwise, saying why.

    check_start_button.py SCREENSHOT.png [--region X,Y,W,H]

The default region (12,750,48,44) is where the first panel icon sits in a 1280x800 screenshot of the Plasma live session.
Needs Pillow.
"""
import argparse
import colorsys
import sys

from PIL import Image

PAPER = (0xF6, 0xF2, 0xE9)
HOTDOG_MAX = 0.03  # fraction of the region that may be hot dog coloured
PAPER_MIN = 0.05   # fraction of the region that must be Paper (the disc of the nisse mark)


def analyse(img):
    pixels = list(img.convert("RGB").get_flattened_data()) if hasattr(img, "get_flattened_data") else list(img.convert("RGB").getdata())
    hot = paper = 0
    for r, g, b in pixels:
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if s > 0.45 and v > 0.30 and 10 <= h * 360 <= 65:
            hot += 1
        if abs(r - PAPER[0]) + abs(g - PAPER[1]) + abs(b - PAPER[2]) < 40:
            paper += 1
    n = len(pixels)
    return hot / n, paper / n


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("screenshot")
    parser.add_argument("--region", default="12,750,48,44")
    args = parser.parse_args(argv)
    x, y, w, h = (int(v) for v in args.region.split(","))
    shot = Image.open(args.screenshot)
    if shot.size != (1280, 800):
        print(f"FAIL: expected a 1280x800 screenshot, got {shot.size[0]}x{shot.size[1]}")
        return 1
    hot, paper = analyse(shot.crop((x, y, x + w, y + h)))
    print(f"start button region: {hot:.1%} hot dog coloured, {paper:.1%} Paper coloured")
    if hot >= HOTDOG_MAX:
        print("FAIL: the start button still shows the Fedora placeholder (hot dog)")
        return 1
    if paper < PAPER_MIN:
        print("FAIL: no nisse mark found in the start button region (is the icon missing?)")
        return 1
    print("PASS: the start button shows the nisse mark")
    return 0


if __name__ == "__main__":
    sys.exit(main())
