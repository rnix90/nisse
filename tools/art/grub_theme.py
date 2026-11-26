#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The pictures and theme.txt of the nisse GRUB theme (ledger N-502), drawn from the same Ember pieces as the approved boot mock
(N-412): the stacked logo, an Ember row for the selected entry and the slim track of the countdown bar.

    python tools/art/grub_theme.py [--out DIR]    writes the theme to DIR (default assets/art/grub/nisse, the committed copy the
                                                  nisse-grub-theme package installs; needs Pillow and fontTools)

What GRUB can do, verified in the N-502 spike (GRUB 2.12, BIOS and UEFI, Fedora 44):
  * the first-listed component of theme.txt is drawn on top, so the countdown bar is listed before the picture of its track;
  * a progress bar is at least 28 px high, and its fill sits inside the (here invisible) border of its frame pieces;
  * menu rows cannot be centered; the selected row is a box drawn from nine pieces, and it is as tall as the item plus two borders;
  * the countdown label takes one number (%d) and cannot say "1 second", so the unit is the short "s";
  * the signed UEFI GRUB has the png reader, gfxmenu and gfxterm built in, so nothing needs insmod under Secure Boot.

One layout fits every screen from 1280 x 720 up (N-502b): GRUB cannot tell which mode it got, so the pieces keep their pixel size and every vertical position is a percentage of the screen's height; GRUB is asked for 1920 x 1080 first, then the screen's own mode. The two static Nunito instances in the folder are turned
into GRUB's .pf2 fonts when the package is built (grub2-mkfont); the names theme.txt asks for are the ones that tool makes.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / "tools" / "repo"))
from headline_case import is_headline  # noqa: E402,F401  (the naming rule, re-exported for the tests)

OUT = ROOT / "assets" / "art" / "grub" / "nisse"
NUNITO = ROOT / "assets" / "fonts" / "Nunito" / "Nunito[wght].ttf"
LOGO_SRC = ROOT / "assets" / "art" / "plymouth" / "nisse" / "logo.png"   # the stacked logo, drawn once for the Plymouth theme
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))["dark"]

SCREEN_W, SCREEN_H = 1920, 1080                            # the size the mock and the default photo are at; the layout fits every size (see layout())
SIZES = [(1920, 1080), (1366, 768), (1360, 768), (1280, 720), (1024, 768)]   # the sizes the tests and photos cover; 1280 x 720 is the smallest the layout fits
LOGO_W = 200
ROW_W, ROW_H, ROW_PITCH, ROW_BORDER = 640, 60, 72, 12      # the selected row: 640 x 60, rows 72 apart, corners 12 px
ITEM_H = ROW_H - 2 * ROW_BORDER                            # 36: the text line inside the row
ITEM_SPACING = ROW_PITCH - ITEM_H                          # 36
BAR_W, BAR_H, BAR_PAD = 490, 28, 6                         # GRUB makes a progress bar at least 28 px high
# Vertical positions are fractions of the screen's height (GRUB cannot tell which mode it got, so there is one theme: the pieces keep
# their size and the spacing between them follows the screen). The four-row menu then fits a 720-line screen with room to spare.
LOGO_TOP_F, ROWS_TOP_F, COUNTDOWN_TOP_F, BAR_TOP_F, HINT_TOP_F = 0.05, 0.36, 0.76, 0.82, 0.93
COUNTDOWN_SIZE, HINT_SIZE, ITEM_SIZE = 22, 18, 28
LABEL_H = {"countdown": 30, "hint": 24}                     # the room a label's line takes (its font size and a little)
TERMINAL_FONT = "Unifont Regular 16"                       # unicode.pf2 of grub2-common, copied into the theme folder by the package
COUNTDOWN = "nisse starts in %d s."
HINT = "Press E to change how nisse starts."
NINE = ("nw", "n", "ne", "w", "c", "e", "sw", "s", "se")
SS = 4                                                      # supersampling for smooth corners


def _hex(name):
    return PALETTE[name]["hex"].lower()


def _rgb(name):
    h = _hex(name)
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def layout(width, height, rows=4):
    """name -> (left, top, right, bottom) in px of every piece of the menu on a width x height screen, as the theme puts them."""
    def top(f):
        return int(f * height)          # GRUB works in fixed point and drops the fraction (measured: 36% of 1080 is row 388)
    logo_h = round(LOGO_W * 680 / 640)
    cx = width / 2
    rows_h = (rows - 1) * ROW_PITCH + ROW_H
    return {
        "logo": (cx - LOGO_W / 2, top(LOGO_TOP_F), cx + LOGO_W / 2, top(LOGO_TOP_F) + logo_h),
        "rows": (cx - ROW_W / 2, top(ROWS_TOP_F), cx + ROW_W / 2, top(ROWS_TOP_F) + rows_h),
        "countdown": (0, top(COUNTDOWN_TOP_F), width, top(COUNTDOWN_TOP_F) + LABEL_H["countdown"]),
        "bar": (cx - BAR_W / 2, top(BAR_TOP_F), cx + BAR_W / 2, top(BAR_TOP_F) + BAR_H),
        "hint": (0, top(HINT_TOP_F), width, top(HINT_TOP_F) + LABEL_H["hint"]),
    }


def font_names():
    """The font names theme.txt asks for (grub2-mkfont names a font '<family> <style> <size>')."""
    return [f"Nunito Regular {ITEM_SIZE}", f"Nunito SemiBold Regular {ITEM_SIZE}", f"Nunito Regular {COUNTDOWN_SIZE}", f"Nunito Regular {HINT_SIZE}"]


TEXT_W = ROW_W - 2 * ROW_BORDER      # the room for a row's words: GRUB starts the text one border in from the row's left edge
_ADV = {}


def advance(text, weight="Regular"):
    """The width in px of text at the menu's font size (32), from the static Nunito file's advance widths (the model N-502c checked
    against what FreeType draws and what GRUB's .pf2 shows, to within the glyph side bearings)."""
    from fontTools.ttLib import TTFont
    if weight not in _ADV:
        f = TTFont(str(OUT / f"Nunito-{weight}.ttf"))
        _ADV[weight] = (f.getBestCmap(), f["hmtx"], f["head"].unitsPerEm)
    cmap, hmtx, upm = _ADV[weight]
    # grub2-mkfont stores every glyph's advance as a whole number of px (checked on photos: a Regular and a SemiBold space are 8, a Bold one is 9, which made a padded Bold row sit 20 px off)
    return sum(round(hmtx[cmap[ord(c)]][0] * ITEM_SIZE / upm) for c in text)


def pad_count(title):
    """How many spaces in front of title center it in the row. GRUB's boot_menu has no alignment property, so a row's words are
    centered by padding the title. The selected row is SemiBold and the others Regular (a bit narrower; SemiBold is the heaviest weight whose space is still 8 px, as Regular's, so the padding means the same in both), so the count is the one whose
    worst miss over both weights is the smallest (a space is about 8 px, so a row is never off by more than about 8 px)."""
    ideal = [(TEXT_W - advance(title, w)) / 2 / advance(" ", w) for w in ("Regular", "SemiBold")]
    start = round(sum(ideal) / 2)
    best = min(range(max(0, start - 3), start + 4), key=lambda n: max(abs(_miss(n, title, w)) for w in ("Regular", "SemiBold")))
    return best


def _miss(n, title, weight):
    return advance(" " * n, weight) + advance(title, weight) / 2 - TEXT_W / 2


def padded(title):
    return " " * pad_count(title) + title


def center_error(title, weight="Regular"):
    """How far (px, positive is right) the padded title's center is from the row's center, in the given weight."""
    return _miss(pad_count(title), title, weight)


def theme_files():
    """Every file of the theme folder."""
    files = ["theme.txt", "Nunito-Regular.ttf", "Nunito-SemiBold.ttf", "logo.png", "bartrack.png"]
    for prefix in ("select", "bar", "barhl"):
        files += [f"{prefix}_{p}.png" for p in NINE]
    return files


def theme_text():
    """theme.txt. The countdown bar comes before its track because the first-listed component is drawn on top."""
    return f'''# SPDX-License-Identifier: GPL-2.0-or-later
# The nisse GRUB theme (N-502). Written by tools/art/grub_theme.py: change it there.
title-text: ""
desktop-color: "{_hex("base")}"
terminal-font: "{TERMINAL_FONT}"

+ image {{
    left = 50%-{LOGO_W // 2}
    top = {round(LOGO_TOP_F * 100)}%
    file = "logo.png"
}}

+ boot_menu {{
    left = 50%-{ROW_W // 2}
    top = {round(ROWS_TOP_F * 100)}%
    width = {ROW_W}
    height = {4 * ROW_PITCH}
    item_font = "{font_names()[0]}"
    selected_item_font = "{font_names()[1]}"
    item_color = "{_hex("text")}"
    selected_item_color = "{_hex("on-accent")}"
    icon_width = 0
    icon_height = 0
    item_height = {ITEM_H}
    item_padding = 0
    item_icon_space = 0
    item_spacing = {ITEM_SPACING}
    selected_item_pixmap_style = "select_*.png"
    scrollbar = false
}}

+ label {{
    id = "__timeout__"
    left = 0
    top = {round(COUNTDOWN_TOP_F * 100)}%
    width = 100%
    align = "center"
    font = "{font_names()[2]}"
    color = "{_hex("text-muted")}"
    text = "{COUNTDOWN}"
}}

+ progress_bar {{
    id = "__timeout__"
    left = 50%-{BAR_W // 2}
    top = {round(BAR_TOP_F * 100)}%
    width = {BAR_W}
    height = {BAR_H}
    bar_style = "bar_*.png"
    highlight_style = "barhl_*.png"
}}

+ image {{
    left = 50%-{BAR_W // 2}
    top = {round(BAR_TOP_F * 100)}%
    file = "bartrack.png"
}}

+ label {{
    left = 0
    top = {round(HINT_TOP_F * 100)}%
    width = 100%
    align = "center"
    font = "{font_names()[3]}"
    color = "{_hex("text-muted")}"
    text = "{HINT}"
}}
'''


def _layer(size, color, mask):
    from PIL import Image
    img = Image.new("RGBA", size, color + (0,))
    img.putalpha(mask)
    return img


def _rounded_mask(w, h, r, inset=0):
    from PIL import Image, ImageDraw
    m = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset * SS, inset * SS, (w - inset) * SS - 1, (h - inset) * SS - 1), max(r - inset, 0) * SS, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def rounded(w, h, r, fill, outline=None, outline_w=0):
    """A rounded rectangle: the color comes from the layer, only the edge is smoothed (no dark fringe)."""
    from PIL import Image
    if outline:
        base = _layer((w, h), outline, _rounded_mask(w, h, r))
        inner = _layer((w, h), fill, _rounded_mask(w, h, r, outline_w))
        return Image.alpha_composite(base, inner)
    return _layer((w, h), fill, _rounded_mask(w, h, r))


def nine(prefix, size, r, fill):
    """The nine pieces of a box (a GRUB pixmap style), cut from a rounded square so the corners are r x r."""
    big = rounded(size, size, r, fill)
    cuts = [(0, r), (r, size - r), (size - r, size)]
    names = [["nw", "n", "ne"], ["w", "c", "e"], ["sw", "s", "se"]]
    return {f"{prefix}_{names[ri][ci]}.png": big.crop((x0, y0, x1, y1))
            for ri, (y0, y1) in enumerate(cuts) for ci, (x0, x1) in enumerate(cuts)}


def pictures():
    """name -> PIL image for every picture this tool draws."""
    from PIL import Image
    out = {}
    out.update(nine("select", 2 * ROW_BORDER + 4, ROW_BORDER, _rgb("accent")))
    out.update(nine("barhl", 8, 3, _rgb("accent")))                       # the fill: Ember, corners 3 px as on the mock
    out["bartrack.png"] = rounded(BAR_W, BAR_H, BAR_H // 2, _rgb("surface"), _rgb("outline"), 2)
    sizes = {"nw": (BAR_PAD, BAR_PAD), "n": (1, BAR_PAD), "ne": (BAR_PAD, BAR_PAD), "w": (BAR_PAD, 1), "c": (1, 1), "e": (BAR_PAD, 1),
             "sw": (BAR_PAD, BAR_PAD), "s": (1, BAR_PAD), "se": (BAR_PAD, BAR_PAD)}
    for p, size in sizes.items():                                         # the frame is invisible: it only keeps the fill 6 px inside
        out[f"bar_{p}.png"] = Image.new("RGBA", size, (0, 0, 0, 0))
    logo = Image.open(LOGO_SRC).convert("RGBA")
    out["logo.png"] = logo.resize((LOGO_W, round(logo.height * LOGO_W / logo.width)), Image.LANCZOS)
    return out


def static_font(out, weight, style):
    """A static instance of the Nunito variable font (GRUB cannot pick a weight). Nunito declares no Reserved Font Name, so a derived
    instance is allowed; the license (OFL.txt) ships with the package."""
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
    font = instancer.instantiateVariableFont(TTFont(str(NUNITO)), {"wght": weight}, updateFontNames=True)
    # GRUB names a font from its family and style: 'Nunito' and the style, whatever the weight's own naming says
    name = font["name"]
    for nid in (16, 17, 21, 22, 25):
        name.removeNames(nameID=nid)
    for nid, value in ((1, "Nunito"), (2, style), (4, f"Nunito {style}"), (6, f"Nunito-{style}")):
        name.setName(value, nid, 3, 1, 0x409)
        name.setName(value, nid, 1, 0, 0)
    path = pathlib.Path(out) / f"Nunito-{style}.ttf"
    font.save(str(path))
    return path


def render_all(out):
    out = pathlib.Path(out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "theme.txt").write_text(theme_text(), encoding="ascii", newline="\n")
    for name, img in pictures().items():
        img.save(out / name, optimize=False)
    static_font(out, 400, "Regular")
    static_font(out, 600, "SemiBold")
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    out = pathlib.Path(argv[argv.index("--out") + 1]) if "--out" in argv else OUT
    print(f"wrote {len(theme_files())} files to {render_all(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
