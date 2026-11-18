#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-409a: the AI panel app's icon: Bert's three-star sparkle, flat and in the nisse colors.

Bert's call (2026-11-18): for the AI app, "a version of the three stars icon we use for our custom Claude Code link in Windows,
colored to match our nisse themes". That launcher icon (T:\\Claude Code Creations\\claude-launcher\\make_icon.py) is one big 4-point
sparkle (an astroid: concave edges, cusped tips) with two small companions, violet to cyan with a glow. Here the same shapes, in the
same places (so it is recognisably the same icon), but flat: a big Ember star and two Paper companions on the Ink tile, no glow and no
gradient, as the rest of the nisse art. As in the original, sizes of 32 px and smaller use one fatter star with no companions so the
spikes do not disappear at taskbar scale.

    python tools/art/assistant_icon.py     writes assets/art/assistant/hicolor/ (PNGs at 10 sizes and the scalable SVG)
"""
import math
import sys
from io import BytesIO
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import icons  # noqa: E402

OUT = ROOT / "assets" / "art" / "assistant" / "hicolor"
LF = chr(10)
INK, PAPER, EMBER = "#1b2330", "#f6f2e9", "#e0623f"
# (centre as a fraction of the square, radius as a fraction, power): the launcher's make_icon.py values
MAIN = ((0.5, 0.5), 0.47, 5.0)
COMPANIONS = (((0.795, 0.22), 0.145, 4.5), ((0.205, 0.785), 0.10, 4.5))
SMALL_MAIN = ((0.5, 0.5), 0.45, 3.2)
SMALL_CUTOFF = 32
SIZES = (16, 22, 24, 32, 48, 64, 96, 128, 256, 512)
SCALE = 0.84          # the launcher's star fills its square; on the tile it is drawn at this fraction, about the centre


def astroid(center, radius, power, samples=140):
    """Points of a 4-point sparkle: x = r sign(cos t) |cos t|^p, y = r sign(sin t) |sin t|^p (concave edges, cusped tips)."""
    cx, cy = center
    pts = []
    for i in range(samples):
        t = 2 * math.pi * i / samples
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + radius * math.copysign(abs(c) ** power, c), cy + radius * math.copysign(abs(s) ** power, s)))
    return pts


def _poly(ident, spec, fill):
    (fx, fy), fr, power = spec
    cx = 256 + (fx * 512 - 256) * SCALE
    cy = 256 + (fy * 512 - 256) * SCALE
    pts = " ".join(f"{x:.1f},{y:.1f}" for x, y in astroid((cx, cy), fr * 512 * SCALE, power))
    return f'<polygon id="{ident}" points="{pts}" fill="{fill}"/>'


def form(detailed):
    """The icon as an SVG document: the Ink tile and the Ember star; the two Paper companions too when `detailed`."""
    body = f'<rect id="tile" width="512" height="512" rx="112" fill="{INK}"/>'
    if detailed:
        body += _poly("sparkle-main", MAIN, EMBER) + _poly("sparkle-a", COMPANIONS[0], PAPER) + _poly("sparkle-b", COMPANIONS[1], PAPER)
    else:
        body += _poly("sparkle-main", SMALL_MAIN, EMBER)
    title = "nisse assistant icon"
    return (icons.HEADER.replace("tools/art/icons.py (N-409)", "tools/art/assistant_icon.py (N-409a)")
            + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512" role="img" aria-label="{title}">'
            + LF + f"  <title>{title}</title>" + LF + f"  {body}" + LF + "</svg>" + LF)


def main():
    from playwright.sync_api import sync_playwright
    (OUT / "scalable" / "apps").mkdir(parents=True, exist_ok=True)
    (OUT / "scalable" / "apps" / "nisse-assistant.svg").write_text(form(True), encoding="ascii", newline=LF)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        for px in SIZES:
            d = OUT / f"{px}x{px}" / "apps"
            d.mkdir(parents=True, exist_ok=True)
            (d / "nisse-assistant.png").write_bytes(icons.render_png(form(px > SMALL_CUTOFF), px, page))
        browser.close()
    print(f"wrote the assistant icon at {len(SIZES)} sizes and the scalable svg to {OUT}")


if __name__ == "__main__":
    sys.exit(main())
