#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Mock screens for the boot-to-desktop surfaces (ledger N-412): GRUB menu, Plymouth boot screen, Plasma splash, login, lock and
logout screens, drawn from the Ember palette and the nisse assets so Bert can gate the look before N-501 to N-505 build them.

Each mock is one 1920 x 1080 SVG (text in Nunito, embedded when rendered); nothing here ships. The pieces the later tasks reuse
are the same drawings: `xp_bar` (the slim track with three Ember blocks Bert asked for: "a progress bar similar to Windows XP's
boot") and the layouts. A GRUB theme can draw a countdown bar for the menu timeout but not an animation, so GRUB shows the bar as
that countdown and Plymouth animates the blocks (N-502 verifies what GRUB can do).

    python tools/art/boot_mocks.py [--out DIR]      writes DIR/<name>.png for every mock and DIR/sheet.png (needs Playwright)
"""
import base64
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import wallpaper  # noqa: E402

PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
FONT = ROOT / "assets" / "fonts" / "Nunito" / "Nunito[wght].ttf"
OUT = ROOT / "assets" / "art" / "boot"
W, H = 1920, 1080
LF = chr(10)


def d(name):
    return PALETTE["dark"][name]["hex"].lower()


def lt(name):
    return PALETTE["light"][name]["hex"].lower()


def uri(path, recolor=None):
    data = pathlib.Path(path).read_text(encoding="ascii")
    for a, b in (recolor or {}).items():
        data = data.replace(a, b)
    return "data:image/svg+xml;base64," + base64.b64encode(data.encode("ascii")).decode()


def svg_uri(svg_text):
    return "data:image/svg+xml;base64," + base64.b64encode(svg_text.encode("ascii")).decode()


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size, fill, weight=400, anchor="middle", opacity=None):
    op = f' fill-opacity="{opacity}"' if opacity is not None else ""
    return (f'<text x="{x}" y="{y}" font-family="Nunito, sans-serif" font-size="{size}" font-weight="{weight}" '
            f'text-anchor="{anchor}" fill="{fill}"{op}>{esc(s)}</text>')


def image(href, x, y, w, h, extra=""):
    return f'<image href="{href}" x="{x}" y="{y}" width="{w}" height="{h}"{extra}/>'


def rect(x, y, w, h, fill, rx=0, stroke=None, sw=0, opacity=None):
    st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    op = f' fill-opacity="{opacity}"' if opacity is not None else ""
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{st}{op}/>'


# ---- the pieces

def xp_bar(cx, cy, w, phase, h=26, mode="dark", clip_id="bar"):
    """The slim track with three flat Ember blocks sliding through it (the boot bar, N-412). phase 0..1 is how far they have gone."""
    track = d("surface") if mode == "dark" else lt("paper")
    edge = d("outline") if mode == "dark" else lt("outline")
    accent = d("accent") if mode == "dark" else lt("accent")
    x0, y0 = cx - w / 2, cy - h / 2
    pad = 6
    ix, iy, iw, ih = x0 + pad, y0 + pad, w - 2 * pad, h - 2 * pad
    bw, gap, n = 34, 7, 3
    total = n * bw + (n - 1) * gap
    left = ix - total + phase * (iw + total)
    blocks = "".join(rect(round(left + i * (bw + gap), 1), iy, bw, ih, accent, rx=3) for i in range(n))
    return (f'<clipPath id="{clip_id}"><rect x="{ix}" y="{iy}" width="{iw}" height="{ih}" rx="3"/></clipPath>'
            + rect(x0, y0, w, h, track, rx=h / 2, stroke=edge, sw=2)
            + f'<g clip-path="url(#{clip_id})">{blocks}</g>')


def countdown_bar(cx, cy, w, fraction, h=26, clip_id="cd"):
    """GRUB's timeout bar: the same track, filled from the left as the timeout runs out (a GRUB theme can draw this)."""
    x0, y0 = cx - w / 2, cy - h / 2
    pad = 6
    ix, iy, iw, ih = x0 + pad, y0 + pad, w - 2 * pad, h - 2 * pad
    return (f'<clipPath id="{clip_id}"><rect x="{ix}" y="{iy}" width="{iw}" height="{ih}" rx="3"/></clipPath>'
            + rect(x0, y0, w, h, d("surface"), rx=h / 2, stroke=d("outline"), sw=2)
            + f'<g clip-path="url(#{clip_id})">{rect(ix, iy, round(iw * fraction, 1), ih, d("accent"), rx=3)}</g>')


STACKED_REVERSE = ROOT / "assets" / "logo" / "svg" / "nisse-lockup-stacked-reverse.svg"      # 640 x 680, Paper
STACKED_INK = ROOT / "assets" / "logo" / "svg" / "nisse-lockup-stacked.svg"                  # Ink, for light screens
ICON_REVERSE = ROOT / "assets" / "logo" / "svg" / "nisse-icon-reverse.svg"
N_REVERSE = ROOT / "assets" / "logo" / "n" / "svg" / "nisse-n-reverse.svg"
N_INK = ROOT / "assets" / "logo" / "n" / "svg" / "nisse-n.svg"
COMET = ROOT / "assets" / "art" / "comet" / "svg" / "nisse-comet.svg"                        # 136 box, Paper
AVATAR = ROOT / "assets" / "art" / "avatars" / "svg" / "nisse-avatar-artist.svg"


def lockup(cx, top, width, mode="dark"):
    h = width * 680 / 640
    return image(uri(STACKED_REVERSE if mode == "dark" else STACKED_INK), cx - width / 2, top, width, round(h, 1))


def icon_power(cx, cy, size, color):
    k = size / 100
    return (f'<g transform="translate({cx - size / 2},{cy - size / 2}) scale({k})" fill="none" stroke="{color}" stroke-width="8" '
            f'stroke-linecap="round" stroke-linejoin="round"><path d="M50 18 L50 48"/><path d="M31 30 A28 28 0 1 0 69 30"/></g>')


def icon_restart(cx, cy, size, color):
    k = size / 100
    return (f'<g transform="translate({cx - size / 2},{cy - size / 2}) scale({k})" fill="none" stroke="{color}" stroke-width="8" '
            f'stroke-linecap="round" stroke-linejoin="round"><path d="M72 36 A26 26 0 1 0 76 54"/><path d="M74 20 L74 38 L56 38"/></g>')


def icon_logout(cx, cy, size, color):
    k = size / 100
    return (f'<g transform="translate({cx - size / 2},{cy - size / 2}) scale({k})" fill="none" stroke="{color}" stroke-width="8" '
            f'stroke-linecap="round" stroke-linejoin="round"><path d="M42 24 H26 V76 H42"/><path d="M40 50 H78"/><path d="M66 38 L78 50 L66 62"/></g>')


def frame(body, bg):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">' + LF
            + f'  <rect width="{W}" height="{H}" fill="{bg}"/>' + LF + f'  {body}' + LF + '</svg>' + LF)


# ---- the surfaces

def grub_menu():
    b = [lockup(W / 2, 90, 230)]
    rows = [("nisse", True), ("Earlier Versions of nisse", False), ("Computer Settings", False)]
    y = 450
    for label, selected in rows:
        if selected:
            b.append(rect(W / 2 - 380, y, 760, 68, d("accent"), rx=18))
            b.append(text(W / 2, y + 46, label, 32, d("on-accent"), 700))
        else:
            b.append(text(W / 2, y + 46, label, 32, d("text"), 400))
        y += 84
    b.append(text(W / 2, 800, "nisse starts in 4 seconds.", 26, d("text-muted")))
    b.append(countdown_bar(W / 2, 850, 560, 0.4))
    b.append(text(W / 2, 1010, "Press E to change how nisse starts.", 22, d("text-muted")))
    return frame("".join(b), d("base"))


def plymouth(phase=0.5):
    b = [lockup(W / 2, 250, 300), xp_bar(W / 2, 760, 420, phase, h=30)]
    return frame("".join(b), d("base"))


def splash(mode):
    bg = d("base") if mode == "dark" else lt("paper")
    n = N_REVERSE if mode == "dark" else N_INK
    accent = d("accent") if mode == "dark" else lt("accent")
    comet = uri(COMET, {d("text"): accent} if mode == "dark" else {d("text"): accent})
    b = [image(comet, W / 2 - 220, H / 2 - 220, 440, 440), image(uri(n), W / 2 - 130, H / 2 - 130, 260, 260)]
    return frame("".join(b), bg)


def _wall(mode):
    return image(svg_uri(wallpaper.scene(W, H, mode)), 0, 0, W, H)


def login(mode):
    dark = mode == "dark"
    ink, soft, field, edge = (d("text"), d("text-muted"), d("surface-2"), d("outline")) if dark else (lt("text"), lt("text-muted"), lt("page"), lt("outline"))
    accent, on_accent = (d("accent"), d("on-accent")) if dark else (lt("accent"), lt("on-accent"))
    scrim = rect(0, 0, W, H, d("base") if dark else lt("paper"), opacity=0.5)
    b = [_wall(mode), scrim]
    b.append(f'<clipPath id="av"><circle cx="{W / 2}" cy="420" r="110"/></clipPath>')
    b.append(f'<g clip-path="url(#av)">{image(uri(AVATAR), W / 2 - 110, 310, 220, 220)}</g>')
    b.append(text(W / 2, 595, "tester", 44, ink, 700))
    b.append(rect(W / 2 - 250, 640, 500, 70, field, rx=16, stroke=edge, sw=2))
    b.append(text(W / 2 - 220, 686, "Password", 28, soft, 400, "start"))
    b.append(rect(W / 2 - 100, 745, 200, 64, accent, rx=32))
    b.append(text(W / 2, 788, "Log In", 28, on_accent, 700))
    b.append(text(48, 1030, "us", 24, ink, 400, "start"))
    b.append(icon_restart(W - 150, 1022, 40, ink))
    b.append(icon_power(W - 80, 1022, 40, ink))
    b.append(image(uri(ICON_REVERSE if dark else ROOT / "assets/logo/svg/nisse-icon.svg"), W / 2 - 22, 1000, 44, 44))
    return frame("".join(b), d("base") if dark else lt("paper"))


def lock(mode):
    dark = mode == "dark"
    ink, soft = (d("text"), d("text-muted")) if dark else (lt("text"), lt("text-muted"))
    scrim = rect(0, 0, W, H, d("base") if dark else lt("paper"), opacity=0.5)   # calm enough that the date never fights the sun
    b = [_wall(mode), scrim]
    b.append(text(W / 2, 430, "9:41", 250, ink, 300))
    b.append(text(W / 2, 520, "Thursday, November 19", 48, ink, 400))   # above the sun, so the date never crosses it
    field, edge = (d("surface-2"), d("outline")) if dark else (lt("page"), lt("outline"))
    b.append(rect(W / 2 - 230, 840, 460, 64, field, rx=16, stroke=edge, sw=2, opacity=0.92))
    b.append(text(W / 2, 883, "Type your password to unlock.", 24, soft, 400))
    b.append(image(uri(ICON_REVERSE if dark else ROOT / "assets/logo/svg/nisse-icon.svg"), 48, 990, 44, 44))
    b.append(text(104, 1022, "nisse", 28, ink, 700, "start"))
    b.append(text(W - 48, 1022, "us", 24, ink, 400, "end"))
    return frame("".join(b), d("base") if dark else lt("paper"))


def logout(mode):
    dark = mode == "dark"
    ink, soft = (d("text"), d("text-muted")) if dark else (lt("text"), lt("text-muted"))
    circle, circle_edge = (d("surface-2"), d("outline")) if dark else (lt("page"), lt("outline"))
    accent, on_accent = (d("accent"), d("on-accent")) if dark else (lt("accent"), lt("on-accent"))
    scrim = rect(0, 0, W, H, d("base") if dark else lt("paper"), opacity=0.82)
    b = [_wall(mode), scrim, text(W / 2, 330, "What would you like to do?", 52, ink, 700)]
    items = [("Log Out", icon_logout, False), ("Restart", icon_restart, False), ("Shut Down", icon_power, True)]
    x = W / 2 - 300
    for label, icon, selected in items:
        if selected:
            b.append(f'<circle cx="{x}" cy="560" r="82" fill="{accent}"/>')
            b.append(icon(x, 560, 62, on_accent))
        else:
            b.append(f'<circle cx="{x}" cy="560" r="82" fill="{circle}" stroke="{circle_edge}" stroke-width="2"/>')
            b.append(icon(x, 560, 62, ink))
        b.append(text(x, 700, label, 30, ink, 700 if selected else 400))
        x += 300
    b.append(text(W / 2, 820, "Shutting down in 30 seconds.", 26, soft))
    b.append(text(W / 2, 900, "Cancel", 30, d("accent-text") if dark else lt("accent"), 700))
    return frame("".join(b), d("base") if dark else lt("paper"))


# name, title for the sheet, builder
SURFACES = [
    ("grub-menu", "GRUB menu (N-502): logo with the name below, plain-word entries, countdown bar", grub_menu),
    ("plymouth-boot", "Plymouth boot screen (N-501): the logo and the sliding-block bar", plymouth),
    ("plymouth-boot-early", "Plymouth, Earlier Frame", lambda: plymouth(0.15)),
    ("plymouth-boot-late", "Plymouth, Later Frame", lambda: plymouth(0.85)),
    ("splash-dark", "Plasma splash after login (N-505), dark: the n and the comet", lambda: splash("dark")),
    ("splash-light", "Plasma Splash, Light", lambda: splash("light")),
    ("login-dark", "Login Screen (N-503), Dark", lambda: login("dark")),
    ("login-light", "Login Screen, Light", lambda: login("light")),
    ("lock-dark", "Lock Screen (N-504), Dark", lambda: lock("dark")),
    ("lock-light", "Lock Screen, Light", lambda: lock("light")),
    ("logout-dark", "Logout, restart and shut down (N-504), dark", lambda: logout("dark")),
    ("logout-light", "Logout Screen, Light", lambda: logout("light")),
]


def build(name):
    for n, _title, fn in SURFACES:
        if n == name:
            return fn()
    raise KeyError(name)


def _html(inner):
    font = base64.b64encode(FONT.read_bytes()).decode()
    return (f'<html><head><style>@font-face{{font-family:"Nunito";src:url(data:font/ttf;base64,{font}) format("truetype");'
            f'font-weight:200 1000;}}body{{margin:0;background:#1b2330}}</style></head><body>{inner}</body></html>')


def render_all(out):
    from playwright.sync_api import sync_playwright
    out = pathlib.Path(out)
    out.mkdir(parents=True, exist_ok=True)
    pngs = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": W, "height": H})
        for name, _title, fn in SURFACES:
            page.set_content(_html(fn()))
            page.wait_for_timeout(300)
            png = page.screenshot(clip={"x": 0, "y": 0, "width": W, "height": H})
            (out / f"{name}.png").write_bytes(png)
            pngs[name] = png
        # the review sheet: three columns of tiles with captions
        tiles = "".join(
            f'<figure style="margin:0"><img src="data:image/png;base64,{base64.b64encode(pngs[n]).decode()}" width="610" '
            f'style="display:block;border:2px solid {d("outline")}"><figcaption style="font:600 17px Nunito;color:{d("text-muted")};'
            f'margin:6px 0 20px">{esc(t)}</figcaption></figure>' for n, t, _ in SURFACES)
        sheet = (f'<div style="width:1900px;padding:20px 20px 0;background:{d("base")}"><div style="font:800 28px Nunito;color:{d("text")};'
                 f'margin-bottom:14px">nisse boot to desktop: mock screens (N-412)</div>'
                 f'<div style="display:grid;grid-template-columns:repeat(3,610px);gap:0 25px">{tiles}</div></div>')
        page.set_viewport_size({"width": 1900, "height": 1700})
        page.set_content(_html(sheet))
        page.wait_for_timeout(500)
        (out / "sheet.png").write_bytes(page.screenshot(full_page=True))
        browser.close()
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    out = pathlib.Path(argv[argv.index("--out") + 1]) if "--out" in argv else OUT
    print(f"wrote {len(SURFACES)} mocks and the sheet to {render_all(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
