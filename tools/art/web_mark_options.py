#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The website and favicon mark (ledger N-413): three favicon options at tab size, beside the rest of the web set.

The logo build already made a web set (assets/logo/favicon, assets/logo/social). The submission asks for "the website and favicon
mark" with no comment, so this shows what a tab will really look like (16 and 32 px, on a light and a dark browser, enlarged to show the
pixels) for three marks, so Bert picks one:

    A  the logo disc (what favicon.svg is today): Ink on a light tab, Paper on a dark one
    B  the nisse n with its tipped hat (the panel app's icon and the tray mark): the same two colors
    C  the Ink app tile (a rounded square with the Paper logo): the same on every tab

    python tools/art/web_mark_options.py [--out DIR]       writes DIR/sheet.png (Playwright)
"""
import base64
import importlib.util
import io
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "assets" / "art" / "web"
INK, PAPER = "#1b2330", "#f6f2e9"

_spec = importlib.util.spec_from_file_location("nisse_build_n", ROOT / "tools" / "logo" / "build_n.py")
BUILD_N = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(BUILD_N)

OPTIONS = ("A", "B", "C")
TITLES = {
    "A": "A. the logo disc (today's favicon.svg)",
    "B": "B. the n with its tipped hat (the panel and tray mark)",
    "C": "C. the Ink app tile",
}


def _scheme_style(cls="m"):
    return f'<style>.{cls}{{fill:{INK}}}@media (prefers-color-scheme:dark){{.{cls}{{fill:{PAPER}}}}}</style>'


def option_svg(option):
    if option == "A":
        return (ROOT / "assets" / "logo" / "favicon" / "favicon.svg").read_text(encoding="ascii")
    if option == "B":
        mark = BUILD_N.mark("#000000").replace('fill="#000000"', 'class="m"')
        return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">' + _scheme_style()
                + f'<g transform="translate(256 256) scale(1.12) translate(-256 -256)">{mark}</g></svg>')
    if option == "C":
        return (ROOT / "assets" / "logo" / "svg" / "nisse-app-tile.svg").read_text(encoding="ascii")
    raise KeyError(option)


def _uri(data, mime):
    return f"data:{mime};base64," + base64.b64encode(data).decode()


def render_icon(page, svg, size):
    page.set_viewport_size({"width": size, "height": size})
    page.set_content(f'<html><body style="margin:0;background:transparent"><img src="{_uri(svg.encode("ascii"), "image/svg+xml")}" '
                     f'width="{size}" height="{size}" style="display:block"></body></html>')
    page.wait_for_function("document.images[0].complete")
    return page.screenshot(clip={"x": 0, "y": 0, "width": size, "height": size}, omit_background=True)


def _page(inner):
    font = base64.b64encode((ROOT / "assets" / "fonts" / "Nunito" / "Nunito[wght].ttf").read_bytes()).decode()
    return (f'<html><head><style>@font-face{{font-family:"Nunito";src:url(data:font/ttf;base64,{font}) format("truetype");font-weight:200 1000;}}'
            f'body{{margin:0}}</style></head><body>{inner}</body></html>')


def tab(png16, dark):
    chrome, text, bar = ("#2b3749", "#f6f2e9", "#1b2330") if dark else ("#ffffff", "#1b2330", "#dfe3ea")
    return (f'<div style="background:{bar};padding:8px 8px 0;width:230px;border-radius:8px 8px 0 0">'
            f'<div style="background:{chrome};border-radius:8px 8px 0 0;padding:9px 12px;display:flex;gap:9px;align-items:center;'
            f'font:600 14px Nunito;color:{text}"><img src="{_uri(png16, "image/png")}" width="16" height="16" style="display:block">nisse</div></div>')


def sheet(pngs):
    rows = []
    for o in OPTIONS:
        cells = []
        for scheme in ("light", "dark"):
            dark = scheme == "dark"
            p16, p32 = pngs[(o, scheme, 16)], pngs[(o, scheme, 32)]
            bg = "#1b2330" if dark else "#f6f2e9"
            cells.append(
                f'<div style="background:{bg};padding:14px;border-radius:10px;display:flex;gap:18px;align-items:center">'
                f'{tab(p16, dark)}'
                f'<img src="{_uri(p16, "image/png")}" width="96" height="96" style="image-rendering:pixelated;display:block">'
                f'<img src="{_uri(p32, "image/png")}" width="96" height="96" style="image-rendering:pixelated;display:block"></div>')
        rows.append(f'<div style="margin:0 0 22px"><div style="font:700 21px Nunito;color:{PAPER};margin-bottom:8px">{TITLES[o]}</div>'
                    f'<div style="display:grid;grid-template-columns:1fr 1fr;gap:20px">{"".join(cells)}</div></div>')
    social = ROOT / "assets" / "logo" / "social"
    fav = ROOT / "assets" / "logo" / "favicon"
    extra = "".join(
        f'<figure style="margin:0"><img src="{_uri(path.read_bytes(), "image/png")}" height="{h}" style="display:block;border-radius:6px;border:2px solid #7a8699">'
        f'<figcaption style="font:600 15px Nunito;color:#aab1bd;margin:6px 0 0">{cap}</figcaption></figure>'
        for path, h, cap in ((social / "og-image-1200x630.png", 210, "link preview card, 1200x630 (as built)"),
                             (social / "github-social-preview-1280x640.png", 210, "GitHub social preview, 1280x640 (as built)"),
                             (fav / "apple-touch-icon.png", 120, "apple-touch-icon, 180x180 (as built)")))
    head = (f'<div style="font:800 30px Nunito;color:{PAPER};margin-bottom:4px">nisse website and favicon mark (N-413)</div>'
            f'<div style="font:400 18px Nunito;color:#aab1bd;margin-bottom:20px">Each option as a browser tab on a light and a dark browser, then the 16 px and 32 px icon enlarged six times to show the pixels.</div>')
    return (f'<div style="width:1500px;padding:24px;background:{INK}">{head}{"".join(rows)}'
            f'<div style="font:700 21px Nunito;color:{PAPER};margin:8px 0">The rest of the web set (already built, unchanged)</div>'
            f'<div style="display:flex;gap:22px;align-items:flex-start">{extra}</div></div>')


def main(argv=None):
    from playwright.sync_api import sync_playwright
    argv = sys.argv[1:] if argv is None else argv
    out = pathlib.Path(argv[argv.index("--out") + 1]) if "--out" in argv else OUT
    out.mkdir(parents=True, exist_ok=True)
    pngs = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for scheme in ("light", "dark"):
            ctx = browser.new_context(color_scheme=scheme)
            page = ctx.new_page()
            for o in OPTIONS:
                for size in (16, 32):
                    pngs[(o, scheme, size)] = render_icon(page, option_svg(o), size)
            ctx.close()
        page = browser.new_page(viewport={"width": 1550, "height": 200})
        page.set_content(_page(sheet(pngs)))
        page.wait_for_timeout(500)
        (out / "sheet.png").write_bytes(page.screenshot(full_page=True))
        browser.close()
    print(f"wrote the favicon options sheet to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
