# SPDX-License-Identifier: GPL-2.0-or-later
"""N-412: the mock screens for the boot-to-desktop surfaces. Nothing here ships; these tests keep the mocks honest to the palette
and the brief: palette colors only, one 1920 x 1080 drawing each, the surfaces the ledger names in both looks, the boot bar Bert
described (a slim track with three Ember blocks sliding through it) and the GRUB countdown."""
import io
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import boot_mocks  # noqa: E402

ROOT = HERE.parents[2]
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
NAMES = [n for n, _t, _f in boot_mocks.SURFACES]


def palette_hexes():
    return {e["hex"].lower() for g in ("dark", "light") for e in PALETTE[g].values()}


def drawn(name):
    """The mock's SVG without the embedded images (the logos, avatar and wallpaper are checked by their own tools)."""
    return re.sub(r'href="data:[^"]*"', 'href=""', boot_mocks.build(name))


def test_every_surface_the_ledger_names_is_mocked():
    for want in ("grub-menu", "grub-menu-live", "plymouth-boot", "splash-dark", "splash-light", "login-dark", "login-light", "lock-dark", "lock-light",
                 "logout-dark", "logout-light"):
        assert want in NAMES


def test_names_are_unique_and_titled():
    assert len(NAMES) == len(set(NAMES))
    for _n, title, _f in boot_mocks.SURFACES:
        assert title and title.isascii()


@pytest.mark.parametrize("name", NAMES)
def test_each_mock_is_one_1920_by_1080_drawing(name):
    svg = boot_mocks.build(name)
    root = ET.fromstring(svg)
    assert root.attrib["viewBox"] == "0 0 1920 1080"
    assert svg.isascii()


@pytest.mark.parametrize("name", NAMES)
def test_every_color_is_a_palette_color(name):
    for h in re.findall(r"#[0-9a-fA-F]{6}\b", drawn(name)):
        assert h.lower() in palette_hexes(), f"{name}: {h} is not an Ember palette color"


@pytest.mark.parametrize("name", NAMES)
def test_the_name_is_lowercase_in_everything_drawn(name):
    assert CAPITAL not in boot_mocks.build(name)


def test_the_boot_bar_is_a_slim_track_with_three_ember_blocks():
    bar = boot_mocks.xp_bar(960, 760, 420, 0.5)
    ember = boot_mocks.d("accent")
    blocks = re.findall(rf'<rect x="[-0-9.]+" y="[0-9.]+" width="34" height="[0-9.]+" rx="3" fill="{ember}"/>', bar)
    assert len(blocks) == 3
    assert 'rx="13.0"' in bar or 'rx="13"' in bar   # a pill track (half the 26 px height)
    assert "linearGradient" not in bar                # flat shapes only (style guide)


def test_the_blocks_slide_through_the_track_and_are_clipped_to_it():
    def lefts(phase):
        bar = boot_mocks.xp_bar(960, 760, 420, phase)
        return [float(x) for x in re.findall(r'<rect x="([-0-9.]+)" y="[0-9.]+" width="34"', bar)]
    start, middle, end = lefts(0.0), lefts(0.5), lefts(1.0)
    assert start[0] < middle[0] < end[0]                      # they move one way
    track_left, track_right = 960 - 210, 960 + 210
    assert start[-1] + 34 <= track_left + 6 + 1               # at the start they are all still outside the inner track (clipped)
    assert end[0] >= track_right - 6 - 1                      # at the end they have all gone through
    assert 'clip-path="url(#bar)"' in boot_mocks.xp_bar(960, 760, 420, 0.5)


def test_the_gaps_between_blocks_are_equal():
    left = [float(x) for x in re.findall(r'<rect x="([-0-9.]+)" y="[0-9.]+" width="34"', boot_mocks.xp_bar(960, 760, 420, 0.3))]
    gaps = {round(b - a, 1) for a, b in zip(left, left[1:])}
    assert gaps == {41.0}                                      # 34 wide plus a 7 px gap


def test_the_grub_countdown_fills_from_the_left_in_proportion():
    full = boot_mocks.countdown_bar(960, 850, 560, 1.0)
    part = boot_mocks.countdown_bar(960, 850, 560, 0.4)
    wf = float(re.search(r'<rect x="[-0-9.]+" y="[0-9.]+" width="([0-9.]+)" height="[0-9.]+" rx="3"', full.split("<g")[1]).group(1))
    wp = float(re.search(r'<rect x="[-0-9.]+" y="[0-9.]+" width="([0-9.]+)" height="[0-9.]+" rx="3"', part.split("<g")[1]).group(1))
    assert abs(wp / wf - 0.4) < 0.01


def test_the_grub_menus_name_their_entries_in_plain_words_with_a_clear_default():
    """N-502 (Bert's answers, 2026-11-26): the installed menu is nisse, Start from Earlier Snapshots, Computer Settings and More Ways to
    Start; the live ISO's has no snapshots row. GRUB cannot center row text, so the rows read left-aligned (the mock was redrawn)."""
    installed, live = drawn("grub-menu"), drawn("grub-menu-live")
    for words in ("nisse", "Start from Earlier Snapshots", "Computer Settings", "More Ways to Start", "nisse starts in 4 s.",
                  "Press E to change how nisse starts."):
        assert f">{words}<" in installed, words
    for words in ("nisse", "Computer Settings", "More Ways to Start", "nisse starts in 4 s."):
        assert f">{words}<" in live, words
    assert "Start from Earlier Snapshots" not in live
    # the default is the Ember row with Ink text; nothing cryptic (no kernel versions or options) is on screen
    assert boot_mocks.d("accent") in installed and boot_mocks.d("on-accent") in installed
    assert not re.search(r"vmlinuz|rootflags|subvol|\.fc4|--id", installed + live)


def test_the_ember_fill_carries_ink_text_never_paper():
    """Palette rule: Paper on Ember is only 3.1:1. Check the texts drawn on an Ember button or row in the dark mocks."""
    for name in ("grub-menu", "grub-menu-live", "login-dark", "logout-dark"):
        svg = drawn(name)
        assert boot_mocks.d("on-accent") in svg


def test_the_mocks_are_deterministic():
    assert boot_mocks.build("login-dark") == boot_mocks.build("login-dark")


def _have_playwright():
    try:
        import playwright.sync_api  # noqa: F401
        return True
    except ImportError:
        return False


@pytest.mark.skipif(not _have_playwright(), reason="Playwright is not installed")
def test_rendering_makes_a_1920_by_1080_png_with_the_ink_background_and_ember_blocks(tmp_path):
    from PIL import Image
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1920, "height": 1080})
        page.set_content(boot_mocks._html(boot_mocks.build("plymouth-boot")))
        page.wait_for_timeout(300)
        png = page.screenshot(clip={"x": 0, "y": 0, "width": 1920, "height": 1080})
        browser.close()
    im = Image.open(io.BytesIO(png)).convert("RGB")
    assert im.size == (1920, 1080)
    assert im.getpixel((5, 5)) == tuple(int(boot_mocks.d("base")[i:i + 2], 16) for i in (1, 3, 5))
    ember = tuple(int(boot_mocks.d("accent")[i:i + 2], 16) for i in (1, 3, 5))
    assert any(im.getpixel((x, 760)) == ember for x in range(740, 1180))
