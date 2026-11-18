#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-408: the nisse cursor theme: a plain W and a plain X in the nisse font, as round badges.

Breeze ships two logo cursors that are looked up by name: `x-cursor` (the X.Org logo, a round badge with an X; libXcursor and the
bare X root use it) and `wayland-cursor` (the Wayland logo, a round badge with a W; Qt's Wayland client, SDL and libdecor name it).
Bert's call (2026-11-17): replace just those two, with a simple W and a simple X in the nisse font, and keep every other pointer
as Breeze draws it. So this makes a tiny theme `nisse_cursors` that inherits `breeze_cursors` and carries only those two files,
at the same eleven sizes (nominal 12 to 72, pictures 16 to 96 pixels) with the hotspot at the centre.

The badge: a Paper outline ring (so it shows on dark backgrounds), an Ember disc, and the letter in Ink (Ember fills carry Ink,
the palette rule for text on an accent), the letter outlined from Nunito by tools/logo/build.py.

    python tools/art/cursors.py        writes assets/art/cursors/nisse_cursors/ and sheet.png
"""
import base64
import importlib.util
import sys
from io import BytesIO
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import xcursor  # noqa: E402

OUT = ROOT / "assets" / "art" / "cursors"
THEME = OUT / "nisse_cursors"
LETTERS = {"wayland-cursor": "W", "x-cursor": "X"}
NOMINALS = [12, 18, 24, 30, 36, 42, 48, 54, 60, 66, 72]       # Breeze's sizes: the picture is nominal * 4 / 3 pixels square
EMBER, INK, PAPER = "#e0623f", "#1b2330", "#f6f2e9"
CAP_HEIGHT = 40.0                                              # the letter's height in a 96 unit badge
INDEX = """# SPDX-License-Identifier: GPL-2.0-or-later
[Icon Theme]
Name=nisse cursors
Comment=A plain W and X in the nisse font for the two logo cursors; every other pointer is Breeze's
Inherits=breeze_cursors
"""


def _logo_build():
    spec = importlib.util.spec_from_file_location("nisse_logo_build", ROOT / "tools" / "logo" / "build.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def badge_svg(letter, size):
    """The badge as an SVG document at `size` pixels: a Paper ring, an Ember disc and the Ink letter, centred."""
    B = _logo_build()
    d, left, right, _ = B.layout(letter, 1.0, 0.0, 0.0)
    # the glyph's own height at scale 1 (font units): take it from a bounding pass of the outline
    from fontTools.pens.boundsPen import BoundsPen
    bp = BoundsPen(B.GS)
    B.GS[B.CMAP[ord(letter)]].draw(bp)
    glyph_h = bp.bounds[3] - bp.bounds[1]
    s = CAP_HEIGHT / glyph_h
    d, left, right, _ = B.layout(letter, s, 0.0, 0.0)
    cx = 48 - (left + right) / 2
    base = 48 + CAP_HEIGHT / 2 - bp.bounds[1] * s
    d, *_ = B.layout(letter, s, cx, base)
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" width="%d" height="%d">'
            '<circle cx="48" cy="48" r="46" fill="%s"/><circle cx="48" cy="48" r="41" fill="%s"/>'
            '<path d="%s" fill="%s"/></svg>' % (size, size, PAPER, EMBER, d, INK))


def frames_for(letter, page):
    out = []
    for nominal in NOMINALS:
        px = nominal * 4 // 3
        page.set_viewport_size({"width": px, "height": px})
        uri = "data:image/svg+xml;base64," + base64.b64encode(badge_svg(letter, px).encode("ascii")).decode()
        page.set_content(f'<html><body style="margin:0;background:transparent"><img src="{uri}" width="{px}" height="{px}" style="display:block"></body></html>')
        page.wait_for_function("document.images[0].complete")
        png = page.screenshot(clip={"x": 0, "y": 0, "width": px, "height": px}, omit_background=True)
        out.append(xcursor.Frame(nominal, Image.open(BytesIO(png)).convert("RGBA"), px // 2, px // 2))
    return out


def build_sheet(frames_by_name):
    """A preview: each cursor at 96, 48 and 24 pixels on a dark and a light page."""
    sheet = Image.new("RGBA", (760, 330), (27, 35, 48, 255))
    light = Image.new("RGBA", (380, 330), (255, 253, 248, 255))
    sheet.paste(light, (380, 0))
    for col, (name, frames) in enumerate(frames_by_name.items()):
        by = {f.image.size[0]: f.image for f in frames}
        for page_x in (0, 380):
            x0 = page_x + 30 + col * 170
            sheet.alpha_composite(by[96], (x0, 40))
            sheet.alpha_composite(by[48], (x0 + 24, 160))
            sheet.alpha_composite(by[24], (x0 + 38, 230))
    return sheet


def main():
    from playwright.sync_api import sync_playwright
    (THEME / "cursors").mkdir(parents=True, exist_ok=True)
    (THEME / "index.theme").write_text(INDEX, encoding="ascii", newline=chr(10))
    done = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        for name, letter in LETTERS.items():
            frames = frames_for(letter, page)
            (THEME / "cursors" / name).write_bytes(xcursor.encode(frames))
            done[name] = frames
        browser.close()
    build_sheet(done).convert("RGB").save(OUT / "sheet.png")
    print(f"wrote {len(done)} cursors ({len(NOMINALS)} sizes each), index.theme and sheet.png to {OUT}")


if __name__ == "__main__":
    sys.exit(main())
