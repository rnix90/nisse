#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The pictures of the nisse Plymouth boot theme (ledger N-501), drawn from the same pieces as the approved boot mock (N-412):
the stacked logo and the slim track with three flat Ember blocks sliding through it (`boot_mocks.xp_bar`).

Plymouth's script module has no clipping, so the bar is drawn ahead of time as a loop of frames and the script swaps them; that
keeps the blocks inside the pill exactly as the mock shows them. Everything is drawn at twice the 1080p size and the script
scales it to the screen (a 4K screen gets the picture at full size). The bar is an animation, not a measure: nothing here says how
far boot has got.

    python tools/art/plymouth_theme.py [--out DIR]    writes the pictures to DIR (default assets/art/plymouth/nisse, the committed
                                                      copy the nisse-plymouth package installs; needs Playwright)

The theme file (nisse.plymouth) and the script (nisse.script) are written by hand in the same folder; this tool does not touch them.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import boot_mocks  # noqa: E402

OUT = ROOT / "assets" / "art" / "plymouth" / "nisse"
SCALE = 2                       # the pictures are drawn at 2x the 1080p size; the script scales them to the screen
FRAMES = 48                     # one loop of the blocks; the script shows them at 24 frames a second, so a loop is two seconds
BAR_W, BAR_H, BAR_PAD = 420, 30, 4          # the track of the approved mock (1920 x 1080), and the room its 2 px edge needs
BAR_SIZE = ((BAR_W + 2 * BAR_PAD) * SCALE, (BAR_H + 2 * BAR_PAD) * SCALE)
LOGO_W = 300                    # the stacked logo's width on the 1080p mock
LOGO_SIZE = (LOGO_W * SCALE, round(LOGO_W * 680 / 640) * SCALE)
FIELD_W, FIELD_H = 420, 40      # the password field (the same pill as the bar, for an encrypted disk's prompt)
FIELD_SIZE = ((FIELD_W + 2 * BAR_PAD) * SCALE, (FIELD_H + 2 * BAR_PAD) * SCALE)
BULLET = 14                     # one typed character of the password
BULLET_SIZE = (BULLET * SCALE, BULLET * SCALE)

LF = chr(10)


def theme_files():
    """Every file the theme folder holds: the two written by hand and the pictures this tool draws."""
    return (["nisse.plymouth", "nisse.script", "Nunito-Regular.ttf", "logo.png", "field.png", "bullet.png"]
            + [f"bar-{i:02d}.png" for i in range(FRAMES)])


NUNITO = ROOT / "assets" / "fonts" / "Nunito" / "Nunito[wght].ttf"


def static_font(out):
    """The Regular (400) instance of the Nunito variable font, for the boot screen's words (N-501a). Plymouth's text plugin loads
    one font file and cannot choose a weight; the variable file's own default is ExtraLight (200). Nunito declares no Reserved Font
    Name, so a derived instance is allowed; the license (OFL.txt) ships with the package."""
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
    font = instancer.instantiateVariableFont(TTFont(str(NUNITO)), {"wght": 400}, updateFontNames=True)
    out = pathlib.Path(out)
    out.mkdir(parents=True, exist_ok=True)
    font.save(str(out / "Nunito-Regular.ttf"))
    return out / "Nunito-Regular.ttf"


def _svg(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">' + LF + body + LF + '</svg>')


def bar_frame(i):
    """Frame i of the loop: the first frame has the blocks just out of sight on the left and the last has them out on the right, so
    the loop shows an empty track for a moment (two frames) before the next three blocks come in."""
    w, h = BAR_W + 2 * BAR_PAD, BAR_H + 2 * BAR_PAD
    return _svg(w, h, boot_mocks.xp_bar(w / 2, h / 2, BAR_W, i / (FRAMES - 1), h=BAR_H, clip_id=f"bar{i}"))


def field():
    w, h = FIELD_W + 2 * BAR_PAD, FIELD_H + 2 * BAR_PAD
    return _svg(w, h, boot_mocks.rect(BAR_PAD, BAR_PAD, FIELD_W, FIELD_H, boot_mocks.d("surface"), rx=FIELD_H / 2,
                                      stroke=boot_mocks.d("outline"), sw=2))


def bullet():
    r = BULLET / 2
    return _svg(BULLET, BULLET, f'<circle cx="{r}" cy="{r}" r="{r}" fill="{boot_mocks.d("accent")}"/>')


def logo():
    return _svg(LOGO_W, LOGO_SIZE[1] // SCALE, boot_mocks.lockup(LOGO_W / 2, 0, LOGO_W))


def pictures():
    """name -> (svg, size in pixels) for every picture this tool draws."""
    out = {"logo.png": (logo(), LOGO_SIZE), "field.png": (field(), FIELD_SIZE), "bullet.png": (bullet(), BULLET_SIZE)}
    for i in range(FRAMES):
        out[f"bar-{i:02d}.png"] = (bar_frame(i), BAR_SIZE)
    return out


def render_all(out):
    from playwright.sync_api import sync_playwright
    out = pathlib.Path(out)
    out.mkdir(parents=True, exist_ok=True)
    static_font(out)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for name, (svg, (pw, ph)) in pictures().items():
            page = browser.new_page(viewport={"width": pw // SCALE, "height": ph // SCALE}, device_scale_factor=SCALE)
            page.set_content(f'<html><body style="margin:0;background:transparent">{svg}</body></html>')
            page.wait_for_timeout(100)
            (out / name).write_bytes(page.screenshot(omit_background=True, clip={"x": 0, "y": 0, "width": pw // SCALE, "height": ph // SCALE}))
            page.close()
        browser.close()
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    out = pathlib.Path(argv[argv.index("--out") + 1]) if "--out" in argv else OUT
    print(f"wrote {len(pictures())} pictures to {render_all(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
