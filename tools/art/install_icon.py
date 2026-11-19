#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-410: the Install to Hard Drive launcher icon: three concepts from an independent art director's brief.

The live desktop's launcher (`liveinst.desktop`, Icon=org.fedoraproject.AnacondaInstaller) is the ONLY icon on the desktop, about 64
pixels on the wallpaper. The first try (the mascot's thin pickaxe on a diagonal across an Ink tile, hitting a ground bar with sparks) was
rejected: "the scale of the axe is wrong for this icon where it's on its own". The art director's diagnosis: a few thin things floating in
an empty tile, the pick's steel head the dimmest part, the Ink tile the same color as the dark wallpaper's sky, and nothing that says
"install". Its brief: one bold Ember shape filling about 70% of the canvas, at most 3 colors and 3 shapes, no sparks or hairline handles,
tile-less on dark and an Ink tile on light (the siblings' pattern).

  hat-pick       the logo's disc with a pick-shaped cutout (an Ember pick shows through it) over the logo's horizon gap; no tile.
  plunge         a fat upright Ember pick driven into the logo's hill, whose Paper slab is in front of the handle's foot.
  shoulder-pick  the gnome's head (the logo's exact hat) with the pick resting behind it, on a surface disc.

    python tools/art/install_icon.py       writes assets/art/icons/install-concepts/ (the six SVGs and sheet.png)
"""
import base64
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import icons  # noqa: E402
import mascot_final  # noqa: E402

OUT = ROOT / "assets" / "art" / "icons" / "install-concepts"
LF = chr(10)
INK, PAPER, EMBER, EMBER_P, EMBER_T, STEEL, SURF2 = "#1b2330", "#f6f2e9", "#e0623f", "#bd573c", "#f28463", "#aab1bd", "#2b3749"


def f1(v):
    return f"{v:.1f}"


HEAD_W, HEAD_T, HEAD_DROP = 0.66 * 96, 0.09 * 96, 0.18 * 96    # the art director's crescent: width, thickness at the center, drop of the tips
HANDLE_W = 0.12 * 96
SHOULDER_HEAD_SCALE = 0.34                                       # the mascot's pick head, scaled (it was 0.30; round 2: bigger)


def crescent_d(w, t, drop):
    """A pick head as a thin crescent, in its own units (top center at 0,0): two quadratic arcs from tip to tip that meet in points."""
    a = w / 2
    return f"M-{f1(a)} {f1(drop)} Q0 {f1(-drop)} {f1(a)} {f1(drop)} Q0 {f1(2 * t - drop)} -{f1(a)} {f1(drop)} Z"


def pick_parts(handle_len):
    """The pick in its own units (the head's top center at 0,0, pointing up): a crescent head, a small socket and a straight handle."""
    socket = f'<rect id="socket" x="{f1(-0.08 * 96)}" y="{f1(HEAD_T - 2)}" width="{f1(0.16 * 96)}" height="{f1(0.06 * 96)}" rx="2"/>'
    handle = f'<rect id="handle" x="{f1(-HANDLE_W / 2)}" y="3" width="{f1(HANDLE_W)}" height="{f1(handle_len)}" rx="3"/>'
    return f'<path id="head" d="{crescent_d(HEAD_W, HEAD_T, HEAD_DROP)}"/>', socket, handle


def hat_pick(mode):
    """The logo disc with a pick cutout: an Ember pick behind a Paper (dark) or Ink (light) disc shows through the cutout, and the
    logo's horizon line is a see-through gap across the disc below the pick's foot. The pick is big: the head is 0.66 of the canvas."""
    disc = PAPER if mode == "dark" else INK
    head_c, socket_c, handle_cut = pick_parts(53)
    mask = ('<mask id="pickcut" maskUnits="userSpaceOnUse" x="0" y="0" width="96" height="96"><rect width="96" height="96" fill="#fff"/>'
            f'<g fill="#000" transform="translate(48 16)">{head_c}{socket_c}{handle_cut}</g>'
            '<path d="M0 70 C22 62 66 62 96 70 V96 H0 Z" fill="#fff" stroke="#000" stroke-width="2.4" stroke-linejoin="round"/></mask>')
    head_e, socket_e, handle_e = pick_parts(43.5)
    pick = f'<g id="pickaxe" fill="{EMBER}" transform="translate(48 16)">{head_e}{socket_e}{handle_e}</g>'
    return pick + f'<circle id="disc" cx="48" cy="48" r="41.5" fill="{disc}" mask="url(#pickcut)"/>', mask


def plunge(mode):
    """A fat Ember pick tilted 20 degrees about its buried foot, driven into the logo's hill: the Paper hill (high in the middle,
    falling at both sides, the logo's horizon curve) is drawn in front of the foot."""
    tile = f'<rect id="tile" width="96" height="96" rx="21" fill="{INK}"/>' if mode == "light" else ""
    head, socket, handle = pick_parts(69)
    pick = f'<g id="pickaxe" fill="{EMBER}" transform="translate(36 8) rotate(20 0 72)">{head}{socket}{handle}</g>'
    hill = f'<path id="hill" d="M4 84 C22 66 74 66 92 84 V86 Q92 92 86 92 H10 Q4 92 4 86 Z" fill="{PAPER}"/>'
    if mode == "light":      # Bert's gate: on the tile it is drawn smaller so the Paper hill does not touch the tile's edge
        return tile + f'<g id="scaled" transform="translate(48 48) scale(0.86) translate(-48 -48)">{pick}{hill}</g>', ""
    return pick + hill, ""


def shoulder_pick(mode):
    """The gnome's head (the logo's exact hat, the face band, the eyes and the nose) with the pick resting behind it."""
    back = (f'<rect id="tile" width="96" height="96" rx="21" fill="{INK}"/>' if mode == "light"
            else f'<circle id="back" cx="48" cy="48" r="42" fill="{SURF2}"/>')
    pick = (f'<g id="pickaxe"><line x1="18" y1="84" x2="74" y2="30" stroke="{EMBER_P}" stroke-width="11" stroke-linecap="round"/>'
            f'<path d="M-62 20 C-34 -44 40 -44 84 20 C40 0 -34 0 -62 20 Z" fill="{STEEL}" '
            f'transform="translate(76 30) rotate(45) scale({SHOULDER_HEAD_SCALE})"/></g>')
    base = mascot_final.spec()["cap_base"]
    head = (f'<g transform="translate(48 52) scale(0.165) translate(-200 -247)">{mascot_final.cap()}'
            f'<rect id="face" x="115" y="{base - 8}" width="170" height="74" rx="24" fill="{EMBER_T}"/>'
            + "".join(f'<circle id="eye" cx="{200 + dx}" cy="{base + 28}" r="9" fill="{INK}"/>' for dx in (-36, 36))
            + f'<circle id="nose" cx="200" cy="{mascot_final.spec()["body_top"] + 2}" r="19" fill="{EMBER}"/></g>')
    return back + pick + head, ""


CHOSEN = "plunge"      # Bert's pick of the three (N-410 gate, 2026-11-18)
CONCEPTS = {"hat-pick": hat_pick, "plunge": plunge, "shoulder-pick": shoulder_pick}


def build(concept, mode):
    body, defs = CONCEPTS[concept](mode)
    title = f"nisse installer launcher icon, {concept}, {mode}"
    d = f"<defs>{defs}</defs>" if defs else ""
    return (icons.HEADER.replace("tools/art/icons.py (N-409)", "tools/art/install_icon.py (N-410)")
            + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" width="96" height="96" role="img" aria-label="{title}">'
            + LF + f"  <title>{title}</title>" + LF + f"  {d}{body}" + LF + "</svg>" + LF)


def _uri(svg):
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode("ascii")).decode()


SHEET_W, SHEET_H = 1500, 760


def build_sheet():
    """Each concept in a row on the dark wallpaper's sky and on the light page, at 192, 64 and 48 pixels (the desktop size is 64)."""
    parts = [f'<rect width="{SHEET_W}" height="{SHEET_H}" fill="{INK}"/><rect x="750" width="750" height="{SHEET_H}" fill="#fffdf8"/>']
    for page, x0 in (("dark", 0), ("light", 750)):
        fg = "#aab1bd" if page == "dark" else "#5d6573"
        parts.append(f'<text x="{x0 + 24}" y="34" font-family="Nunito, sans-serif" font-size="24" fill="{fg}">{page} look</text>')
        for row, concept in enumerate(CONCEPTS):
            svg = build(concept, page)
            y = 56 + row * 232
            x = x0 + 30
            for size in (192, 64, 48):
                parts.append(f'<image href="{_uri(svg)}" x="{x}" y="{y + (192 - size) / 2:.0f}" width="{size}" height="{size}"/>')
                x += size + 40
            parts.append(f'<text x="{x0 + 450}" y="{y + 100}" font-family="Nunito, sans-serif" font-size="22" fill="{fg}">{row + 1}. {concept}</text>')
    body = "".join(parts)
    return (icons.HEADER + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SHEET_W} {SHEET_H}" width="{SHEET_W}" height="{SHEET_H}" role="img" '
            f'aria-label="installer icon concepts">' + LF + "  <title>installer icon concepts</title>" + LF + f"  {body}" + LF + "</svg>" + LF)


def main():
    from playwright.sync_api import sync_playwright
    OUT.mkdir(parents=True, exist_ok=True)
    for concept in CONCEPTS:
        for mode in ("dark", "light"):
            (OUT / f"{concept}-{mode}.svg").write_text(build(concept, mode), encoding="ascii", newline=LF)
    sheet = build_sheet()
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        page.set_viewport_size({"width": SHEET_W, "height": SHEET_H})
        page.set_content(f'<html><body style="margin:0"><img src="{_uri(sheet)}" width="{SHEET_W}" height="{SHEET_H}" style="display:block"></body></html>')
        page.wait_for_function("document.images[0].complete")
        (OUT / "sheet.png").write_bytes(page.screenshot(clip={"x": 0, "y": 0, "width": SHEET_W, "height": SHEET_H}))
        browser.close()
    print(f"wrote 6 icons and sheet.png to {OUT}")


if __name__ == "__main__":
    sys.exit(main())
