#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build the Nisse logo package into assets/logo/.

Wordmark text is outlined from Nunito (SIL OFL 1.1, bundled in assets/fonts/Nunito),
so no output file needs the font installed.

Needs: fontTools, Pillow, playwright (Chromium) for the PNG step.
Run from anywhere:  python tools/logo/build.py
Change WEIGHT or FONT below to re-cut every file with a different face.
"""
import base64
import io
import pathlib
import shutil
import struct

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
LOGO = ROOT / "assets" / "logo"
FONT = ROOT / "assets" / "fonts" / "Nunito" / "Nunito[wght].ttf"
WEIGHT = 800

INK, PAPER = "#1b2330", "#f6f2e9"
COLORWAYS = (("", INK), ("-reverse", PAPER), ("-black", "#000000"), ("-white", "#ffffff"))

# ---------------------------------------------------------------- font outlines
_font = instancer.instantiateVariableFont(TTFont(str(FONT)), {"wght": WEIGHT})
GS = _font.getGlyphSet()
CMAP = _font.getBestCmap()
HMTX = _font["hmtx"]
XH = _font["OS/2"].sxHeight


def num(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def layout(chars, scale, x0, base, track=0.0):
    """Outline `chars` left to right. Returns (path_d, ink_left, ink_right, glyphs)."""
    pen_x, d, glyphs = x0, [], []
    left, right = 1e9, -1e9
    for ch in chars:
        name = CMAP[ord(ch)]
        t = (scale, 0, 0, -scale, pen_x, base)
        sp = SVGPathPen(GS, num)
        GS[name].draw(TransformPen(sp, t))
        bp = BoundsPen(GS)
        GS[name].draw(TransformPen(bp, t))
        d.append(sp.getCommands())
        if bp.bounds:
            left, right = min(left, bp.bounds[0]), max(right, bp.bounds[2])
        glyphs.append((ch, pen_x, bp.bounds))
        pen_x += HMTX[name][0] * scale + track
    return " ".join(d), left, right, glyphs


# ---------------------------------------------------------------- shapes
HAT = ('<path d="M-28 -10 C-24 -44 -16 -76 0 -102 C8 -116 30 -116 38 -102 C26 -106 18 -98 18 -88 '
       'C24 -66 28 -38 28 -10 Z"/><rect x="-34" y="-18" width="68" height="18" rx="9"/>')
HAT_H = 116.0          # hat height at scale 1 (cuff bottom at y=0)
HILL = "M0 380 C120 330 200 320 256 322 C320 324 400 330 512 372 V512 H0 Z"


def icon_parts(fill, cls=None):
    """Round icon: disc with the cap and hill line knocked out (real transparency)."""
    defs = ('<mask id="knockout" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">'
            '<rect width="512" height="512" fill="#fff"/>'
            f'<g transform="translate(251 392) scale(2.4)" fill="#000">{HAT}</g>'
            f'<path d="{HILL}" fill="#fff" stroke="#000" stroke-width="10" stroke-linejoin="round"/>'
            '</mask>')
    paint = f'class="{cls}"' if cls else f'fill="{fill}"'
    return defs, f'<circle cx="256" cy="256" r="236" {paint} mask="url(#knockout)"/>'


# ---------------------------------------------------------------- forms
# Each form returns (view_w, view_h, defs, body) for a fill colour.
def form_icon(fill):
    defs, body = icon_parts(fill)
    return 512, 512, defs, body


def form_lockup_h(fill):
    """Disc icon + wordmark with a plain dotted i (the icon carries the cap)."""
    xh_world = 174.0
    s = xh_world / XH
    base = 343.0
    # place so the n's ink edge starts at x=530
    _, l0, _, _ = layout("nisse", s, 0, base)
    d, l, r, _ = layout("nisse", s, 530 - l0, base)
    defs, body = icon_parts(fill)
    return int(r + 20 + 0.5), 512, defs, body + f'<path d="{d}" fill="{fill}"/>'


def form_lockup_v(fill):
    """Icon above the wordmark."""
    s = 104.0 / XH
    base = 640.0
    _, l0, r0, _ = layout("nisse", s, 0, base)
    d, _, _, _ = layout("nisse", s, 320 - (l0 + r0) / 2, base)
    defs, body = icon_parts(fill)
    return 640, 680, defs, (f'<g transform="translate(100 0) scale(.86)">{body}</g>'
                            f'<path d="{d}" fill="{fill}"/>')


HAT_SCALE = 1.1        # hat height as a fraction of the x-height


def form_wordmark(fill):
    """Wordmark alone, the cap sitting on a dotless i (the one you loved in round 1)."""
    H = 200.0
    s = H / XH
    k = HAT_SCALE * H / HAT_H
    gap = 0.04 * H
    pad = 28.0
    base = pad + HAT_SCALE * H + gap + H
    chars = "n" + chr(0x131) + "sse"    # U+0131 is the dotless i
    _, l0, _, _ = layout(chars, s, 0, base)
    d, l, r, glyphs = layout(chars, s, pad - l0, base)
    bl, bt, br, bb = glyphs[1][2]
    cx = (bl + br) / 2
    top_y = base - XH * s
    hat = f'<g transform="translate({num(cx)} {num(top_y - gap)}) scale({num(k)})" fill="{fill}">{HAT}</g>'
    return int(r + pad + 0.5), int(base + pad + 0.5), "", f'<path d="{d}" fill="{fill}"/>{hat}'


def form_tile(_fill):
    """Ink rounded-square app tile with the light icon inside."""
    defs, body = icon_parts(PAPER)
    return 512, 512, defs, (f'<rect width="512" height="512" rx="112" fill="{INK}"/>'
                            f'<g transform="translate(256 256) scale(.74) translate(-256 -256)">{body}</g>')


FORMS = {
    "icon": (form_icon, "Nisse icon (1:1 round)"),
    "lockup-horizontal": (form_lockup_h, "Nisse lockup, horizontal"),
    "lockup-stacked": (form_lockup_v, "Nisse lockup, stacked"),
    "wordmark": (form_wordmark, "Nisse wordmark with cap"),
}

HEAD = ('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!-- SPDX-License-Identifier: GPL-2.0-or-later -->\n'
        '<!-- Generated by tools/logo/build.py. Wordmark outlined from Nunito (SIL OFL 1.1); no font needed. -->\n')


def svg_doc(w, h, defs, body, label, style=""):
    d = f"  <defs>{defs}{style}</defs>\n" if (defs or style) else ""
    return (HEAD + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
            f'role="img" aria-label="Nisse">\n  <title>{label}</title>\n{d}  {body}\n</svg>\n')


# ---------------------------------------------------------------- raster
class Raster:
    def __enter__(self):
        self.p = sync_playwright().start()
        self.b = self.p.chromium.launch()
        self.pg = self.b.new_page()
        return self

    def __exit__(self, *a):
        self.b.close()
        self.p.stop()

    def png(self, svg_text, w, h):
        uri = "data:image/svg+xml;base64," + base64.b64encode(svg_text.encode("ascii")).decode()
        self.pg.set_viewport_size({"width": w, "height": h})
        self.pg.set_content('<html><body style="margin:0;background:transparent">'
                            f'<img src="{uri}" style="display:block" width="{w}" height="{h}"></body></html>')
        self.pg.wait_for_function("document.images[0].complete")
        return self.pg.screenshot(omit_background=True, clip={"x": 0, "y": 0, "width": w, "height": h})


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        data.encode("ascii")           # fail loudly on any non-ASCII
        path.write_text(data, encoding="ascii", newline="\n")
    else:
        path.write_bytes(data)


def write_ico(path, entries):
    n = len(entries)
    out = struct.pack("<HHH", 0, 1, n)
    off = 6 + 16 * n
    blob = b""
    for size, data in entries:
        dim = 0 if size >= 256 else size
        out += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), off + len(blob))
        blob += data
    write(path, out + blob)


def ascii_art(png_bytes, cols=60, rows=28):
    im = Image.open(io.BytesIO(png_bytes)).convert("RGBA").getchannel("A").resize((cols, rows), Image.LANCZOS)
    lines = []
    for y in range(rows):
        row = ""
        for x in range(cols):
            a = im.getpixel((x, y))
            row += "#" if a > 150 else ("+" if a > 70 else " ")
        lines.append(row.rstrip())
    return "\n".join(lines) + "\n"


def doc(form_name, fill, label=None):
    fn, lab = FORMS[form_name]
    w, h, defs, body = fn(fill)
    return w, h, svg_doc(w, h, defs, body, label or lab)


def main():
    for sub in ("svg", "png", "favicon", "linux", "boot", "social", "ascii"):
        shutil.rmtree(LOGO / sub, ignore_errors=True)
    for old in LOGO.glob("nisse-*.svg"):
        old.unlink()

    # ---- SVG: every form x colourway
    for form in FORMS:
        for suffix, fill in COLORWAYS:
            _, _, text = doc(form, fill)
            write(LOGO / "svg" / f"nisse-{form}{suffix}.svg", text)
    w, h, defs, body = form_tile(None)
    write(LOGO / "svg" / "nisse-app-tile.svg", svg_doc(w, h, defs, body, "Nisse app tile"))
    # symbolic (inherits text colour) for panels and toolbars
    w, h, defs, body = form_icon("currentColor")
    write(LOGO / "svg" / "nisse-icon-symbolic.svg", svg_doc(w, h, defs, body, "Nisse icon, symbolic"))

    # ---- favicon.svg that follows the browser colour scheme
    defs, body = icon_parts(INK, cls="m")
    style = ('<style>.m{fill:%s}@media (prefers-color-scheme:dark){.m{fill:%s}}</style>' % (INK, PAPER))
    write(LOGO / "favicon" / "favicon.svg", svg_doc(512, 512, defs, body, "Nisse", style))

    with Raster() as R:
        def render(form, fill, width, path):
            w, h, text = doc(form, fill)
            hh = round(width * h / w)
            write(path, R.png(text, width, hh))

        # ---- PNG: icon and tile sizes
        for suffix, fill in COLORWAYS[:2]:
            for px in (16, 24, 32, 48, 64, 128, 256, 512, 1024):
                render("icon", fill, px, LOGO / "png" / f"nisse-icon{suffix}-{px}.png")
            for form in ("lockup-horizontal", "lockup-stacked", "wordmark"):
                for px in (600, 1200, 2400) if form != "lockup-stacked" else (320, 640, 1280):
                    render(form, fill, px, LOGO / "png" / f"nisse-{form}{suffix}-{px}w.png")
        w, h, defs, body = form_tile(None)
        tile = svg_doc(w, h, defs, body, "Nisse app tile")
        for px in (256, 512, 1024):
            write(LOGO / "png" / f"nisse-app-tile-{px}.png", R.png(tile, px, px))

        # ---- favicon set
        ico = [(px, R.png(doc("icon", INK)[2], px, px)) for px in (16, 32, 48, 64)]
        write_ico(LOGO / "favicon" / "favicon.ico", ico)
        write(LOGO / "favicon" / "favicon-16.png", ico[0][1])
        write(LOGO / "favicon" / "favicon-32.png", ico[1][1])
        for px, name in ((180, "apple-touch-icon.png"), (192, "android-chrome-192.png"), (512, "android-chrome-512.png")):
            write(LOGO / "favicon" / name, R.png(tile, px, px))

        # ---- freedesktop icon theme: distributor-logo-nisse (tile, so it reads on any panel)
        hic = LOGO / "linux" / "hicolor"
        for px in (16, 22, 24, 32, 48, 64, 96, 128, 192, 256, 512):
            write(hic / f"{px}x{px}" / "apps" / "distributor-logo-nisse.png", R.png(tile, px, px))
        write(hic / "scalable" / "apps" / "distributor-logo-nisse.svg", tile)
        w, h, defs, body = form_icon("currentColor")
        write(hic / "symbolic" / "apps" / "distributor-logo-nisse-symbolic.svg",
              svg_doc(w, h, defs, body, "Nisse icon, symbolic"))

        # ---- boot and splash
        rev = PAPER
        write(LOGO / "boot" / "boot-logo-reverse-256.png", R.png(doc("icon", rev)[2], 256, 256))
        for bw, bh in ((1920, 1080), (3840, 2160)):
            lw, lh, ldefs, lbody = form_lockup_v(rev)
            th = bh * 0.40
            tw = th * lw / lh
            inner = (f'<rect width="{bw}" height="{bh}" fill="{INK}"/>'
                     f'<svg x="{num((bw - tw) / 2)}" y="{num((bh - th) / 2)}" width="{num(tw)}" height="{num(th)}" '
                     f'viewBox="0 0 {lw} {lh}"><defs>{ldefs}</defs>{lbody}</svg>')
            write(LOGO / "boot" / f"splash-{bw}x{bh}.png", R.png(svg_doc(bw, bh, "", inner, "Nisse splash"), bw, bh))

        # ---- social
        for name, bw, bh in (("github-social-preview-1280x640", 1280, 640), ("og-image-1200x630", 1200, 630)):
            lw, lh, ldefs, lbody = form_lockup_h(rev)
            tw = bw * 0.62
            th = tw * lh / lw
            inner = (f'<rect width="{bw}" height="{bh}" fill="{INK}"/>'
                     f'<svg x="{num((bw - tw) / 2)}" y="{num((bh - th) / 2)}" width="{num(tw)}" height="{num(th)}" '
                     f'viewBox="0 0 {lw} {lh}"><defs>{ldefs}</defs>{lbody}</svg>')
            write(LOGO / "social" / f"{name}.png", R.png(svg_doc(bw, bh, "", inner, "Nisse"), bw, bh))

        # ---- ASCII art for MOTD / fetch tools
        write(LOGO / "ascii" / "nisse-icon.txt", ascii_art(R.png(doc("icon", INK)[2], 256, 256)))

    print("done")


if __name__ == "__main__":
    main()
