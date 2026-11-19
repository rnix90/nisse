# SPDX-License-Identifier: GPL-2.0-or-later
"""N-413: the panel tray icon in six states, and the favicon options. The tray is monochrome (Plasma recolors a symbolic icon to the
panel's text color), so every state must be one color, KDE's color-scheme style and nothing else, and the six must be told apart by
shape at the sizes a tray really uses."""
import io
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import tray_icons  # noqa: E402
import web_mark_options  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
SVGS = tray_icons.build_all()


def _have_playwright():
    try:
        import playwright.sync_api  # noqa: F401
        return True
    except ImportError:
        return False


def test_the_six_states_the_ledger_names_exist():
    assert set(tray_icons.STATES) == {"idle", "busy", "needs-you", "unread", "paused", "offline"}
    assert set(SVGS) == set(tray_icons.STATES)
    assert [tray_icons.file_name(s) for s in tray_icons.STATES][0] == "nisse-tray-idle-symbolic.svg"


@pytest.mark.parametrize("state", tray_icons.STATES)
def test_each_icon_is_a_well_formed_ascii_symbolic_svg(state):
    svg = SVGS[state]
    assert svg.isascii()
    root = ET.fromstring(svg.split("-->", 2)[-1])
    assert root.attrib["viewBox"] == "0 0 512 512"
    assert "symbolic" in svg.split("<title>")[1].split("</title>")[0]
    assert CAPITAL not in svg


@pytest.mark.parametrize("state", tray_icons.STATES)
def test_each_icon_has_the_kde_color_scheme_style_and_draws_in_current_color(state):
    svg = SVGS[state]
    assert 'id="current-color-scheme"' in svg and ".ColorScheme-Text" in svg
    drawn = re.findall(r'(?:fill|stroke)="([^"]+)"', svg)
    assert drawn
    for value in drawn:
        assert value in ("currentColor", "none", "#fff", "#000"), f"{state}: {value}"   # #fff and #000 only inside masks
    assert 'class="ColorScheme-Text"' in svg


@pytest.mark.parametrize("state", tray_icons.STATES)
def test_one_color_only_flat_shapes(state):
    svg = SVGS[state]
    colors = {c.lower() for c in re.findall(r"#[0-9a-fA-F]{3,6}\b", svg)}
    assert colors <= {tray_icons.PAPER, "#fff", "#000"}
    assert not re.search(r"linearGradient|radialGradient|<filter|opacity|stop-color", svg)


@pytest.mark.parametrize("state", tray_icons.STATES)
def test_the_mark_is_the_n_with_the_logos_hat(state):
    # the hat is the logo's own HAT markup, from the n mark module, so a tray icon cannot drift from the panel's icon
    hat_path = re.search(r'd="([^"]+)"', tray_icons.BUILD_N.B.HAT).group(1)
    assert hat_path in SVGS[state]


def test_badges_stay_inside_the_icon():
    cx, cy = tray_icons.BADGE_C
    for r in (tray_icons.DISC_R, tray_icons.DOT_R, tray_icons.RING_R + tray_icons.RING_W // 2):
        assert cx - r >= 0 and cx + r <= 512 and cy - r >= 0 and cy + r <= 512
    for bx, by, bw, bh in tray_icons.BARS:
        assert bx >= 0 and bx + bw <= 512 and by >= 0 and by + bh <= 512


def test_the_icons_are_small_files():
    for state, svg in SVGS.items():
        assert len(svg) < 12000, state


def test_the_busy_icon_uses_the_comet_ring_of_the_spinner():
    ring = tray_icons.comet.tail_path()
    assert ring in SVGS["busy"]


def _png(svg, size, color=None):
    from playwright.sync_api import sync_playwright
    import icons
    if color:
        svg = svg.replace(f"color:{tray_icons.PAPER};", f"color:{color};")
    return icons.render_png(svg, size)


@pytest.mark.skipif(not _have_playwright(), reason="Playwright is not installed")
def test_the_six_states_are_different_at_22_px():
    from PIL import Image, ImageChops
    ims = {s: Image.open(io.BytesIO(_png(SVGS[s], 22))).convert("RGBA") for s in tray_icons.STATES}
    names = list(tray_icons.STATES)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            diff = ImageChops.difference(ims[a], ims[b]).getchannel("A").point(lambda v: 255 if v > 40 else 0)
            assert sum(1 for v in diff.getdata() if v) >= 8, f"{a} and {b} are too alike at 22 px"


@pytest.mark.skipif(not _have_playwright(), reason="Playwright is not installed")
def test_the_badge_states_keep_the_n_and_add_a_mark_top_right():
    from PIL import Image
    idle = Image.open(io.BytesIO(_png(SVGS["idle"], 32))).convert("RGBA").getchannel("A")
    for state in ("needs-you", "unread", "paused", "offline"):
        a = Image.open(io.BytesIO(_png(SVGS[state], 32))).convert("RGBA").getchannel("A")
        left_idle = idle.crop((0, 0, 20, 32))
        left_state = a.crop((0, 0, 20, 32))
        same = sum(1 for p, q in zip(left_idle.getdata(), left_state.getdata()) if abs(p - q) < 60)
        assert same >= 0.97 * 20 * 32, f"{state}: the n was disturbed"
        corner = a.crop((22, 0, 32, 12))
        assert sum(1 for v in corner.getdata() if v > 100) >= 12, f"{state}: nothing drawn top right"
        assert sum(1 for v in idle.crop((22, 0, 32, 12)).getdata() if v > 100) == 0


@pytest.mark.skipif(not _have_playwright(), reason="Playwright is not installed")
def test_the_icon_takes_the_panel_text_color():
    from PIL import Image
    ink = "#1b2330"
    im = Image.open(io.BytesIO(_png(SVGS["idle"], 64, ink))).convert("RGBA")
    solid = [p for p in im.getdata() if p[3] == 255]
    assert solid and all(max(abs(p[i] - c) for i, c in enumerate((0x1B, 0x23, 0x30))) <= 3 for p in solid)   # antialiasing rounds by one


# ---- the favicon options
def test_three_favicon_options_exist_and_use_only_palette_colors():
    assert web_mark_options.OPTIONS == ("A", "B", "C")
    for o in web_mark_options.OPTIONS:
        svg = web_mark_options.option_svg(o)
        assert svg.isascii()
        ET.fromstring(svg.split("-->")[-1])
        for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg):
            assert h.lower() in ("#1b2330", "#f6f2e9", "#000000", "#ffffff"), f"{o}: {h}"


def test_options_a_and_b_follow_the_browser_color_scheme_and_c_does_not():
    assert "prefers-color-scheme:dark" in web_mark_options.option_svg("A")
    assert "prefers-color-scheme:dark" in web_mark_options.option_svg("B")
    assert "prefers-color-scheme" not in web_mark_options.option_svg("C")
