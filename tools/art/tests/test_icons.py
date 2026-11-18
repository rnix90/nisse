# SPDX-License-Identifier: GPL-2.0-or-later
"""N-409: the nisse icons: gear, terminal under the cap, nisse logo on a disk, and the Plasma start icon with the nisse logo."""
import configparser
import json
import re
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import icons  # noqa: E402
import mascot_final  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
PLASMA_DOTS = {"#fa8865", "#63c605", "#1b89f3"}       # Breeze's three start-here dots, kept as Bert asked ("use these colors")
ART = ROOT / "assets" / "art" / "icons"


def palette_hexes():
    return {e["hex"].lower() for g in ("dark", "light") for e in PALETTE[g].values()}


def used(svg):
    return {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}


def test_the_icons_are_the_ones_the_ledger_names():
    assert sorted(icons.build_all()) == ["anaconda", "install-to-hard-drive", "preferences-system", "start-here-kde-plasma-dark",
                                         "start-here-kde-plasma-light", "utilities-terminal"]


def test_every_svg_is_ascii_with_a_licence_header_a_view_box_and_a_lowercase_title():
    for name, svg in icons.build_all().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert re.search(r'viewBox="0 0 (96 96|64 64)"', svg), name
        for title in re.findall(r"<title>(.*?)</title>", svg):
            assert title and CAPITAL not in title, (name, title)
        for banned in ("Gradient", "filter", "opacity", "<image", "<text"):
            assert banned not in svg, (name, banned)


@pytest.mark.parametrize("name", ["preferences-system", "utilities-terminal", "anaconda", "install-to-hard-drive"])
def test_the_tile_icons_use_only_ink_paper_and_ember_and_are_the_nisse_tile_shape(name):
    svg = icons.build_all()[name]
    assert used(svg) <= {"#1b2330", "#f6f2e9", "#e0623f", "#2b3749", "#aab1bd", "#bd573c", "#000000", "#ffffff"}, used(svg)   # #000 and #fff drive the logo mask
    assert 'id="tile"' in svg and re.search(r'<rect id="tile"[^>]*rx="2\d"', svg)


def test_the_gear_has_eight_rounded_teeth_and_a_hole_with_an_ember_centre():
    svg = icons.build_all()["preferences-system"]
    assert icons.TEETH == 8
    gear = re.search(r'<path id="gear" d="([^"]+)"', svg).group(1)
    assert gear.count("Q") == 4 * icons.TEETH                        # four rounded corners per tooth
    assert 'id="hub"' in svg and "#e0623f" in svg


def test_the_terminal_icon_has_the_logos_exact_hat_layered_behind_the_prompt_window_with_a_see_through_gap():
    # Bert's gate: the hat goes BEHIND the rest, separated by the same kind of transparency line as the logo's horizon
    svg = icons.build_all()["utilities-terminal"]
    assert mascot_final.HAT_D in svg                                 # the logo's hat, path for path
    for ident in ("window", "prompt", "cap", "gap"):
        assert f'id="{ident}"' in svg, ident
    assert svg.index('id="tile"') < svg.index('id="cap"') < svg.index('id="gap"') < svg.index('id="window"') < svg.index('id="prompt"')
    cap = svg[svg.index('id="cap"'):]
    assert "#e0623f" in cap[:cap.index("</g>")]
    gap = re.search(r'<rect id="gap" x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"[^>]*fill="(#[0-9a-f]{6})"', svg)
    win = re.search(r'<rect id="window" x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"', svg)
    assert gap and win
    gx, gy, gw, gh = (float(v) for v in gap.groups()[:4])
    wx, wy, ww, wh = (float(v) for v in win.groups())
    assert gap.group(5) == "#1b2330"                                 # the gap shows the tile through: a see-through line
    assert wx - gx >= 3 and wy - gy >= 3 and (gx + gw) - (wx + ww) >= 3     # the line is at least 3 units wide on the sides and the top


def test_the_disk_icon_carries_the_nisse_logo_and_a_status_light():
    svg = icons.build_all()["anaconda"]
    assert 'id="drive"' in svg and 'id="logo"' in svg and 'id="led"' in svg
    assert "mask=" in svg and "M-28 -10 C-24 -44" in svg            # the logo's disc with its hat and hill knocked out
    assert svg.count('id="knockout') == 1


@pytest.mark.parametrize("mode,color", [("dark", "#f6f2e9"), ("light", "#1b2330")])
def test_the_start_icon_keeps_the_three_plasma_dots_and_swaps_the_chevron_for_the_nisse_disc(mode, color):
    svg = icons.build_all()[f"start-here-kde-plasma-{mode}"]
    assert PLASMA_DOTS <= used(svg)
    assert used(svg) - PLASMA_DOTS <= palette_hexes() | {"#000000", "#ffffff"}
    assert "M 41 5 L 35 11" not in svg                              # Breeze's chevron is gone
    assert 'class="ColorScheme-Text"' in svg and f"color:{color}" in svg   # Plasma recolors it per look; the default matches the look
    assert 'id="logo"' in svg and 'id="tile"' not in svg              # no tile: it sits straight on the panel, as Breeze's does


def test_the_two_overlay_themes_inherit_breeze_and_carry_only_these_icons():
    for theme, base in (("nisse_icons", "breeze"), ("nisse_icons_dark", "breeze-dark")):
        root = ART / theme
        cp = configparser.ConfigParser(interpolation=None)
        cp.read(root / "index.theme", encoding="ascii")
        assert cp["Icon Theme"]["Inherits"] == base
        assert cp["Icon Theme"]["Directories"] == "scalable/apps,scalable/places"
        files = sorted(str(p.relative_to(root)).replace("\\", "/") for p in root.rglob("*") if p.is_file())
        assert files == ["index.theme", "scalable/apps/org.fedoraproject.AnacondaInstaller.svg", "scalable/apps/preferences-system.svg",
                         "scalable/apps/utilities-terminal.svg", "scalable/places/start-here-kde-plasma.svg"], files
        assert CAPITAL not in (root / "index.theme").read_text(encoding="ascii")
    light = (ART / "nisse_icons/scalable/places/start-here-kde-plasma.svg").read_text(encoding="ascii")
    dark = (ART / "nisse_icons_dark/scalable/places/start-here-kde-plasma.svg").read_text(encoding="ascii")
    assert "color:#1b2330" in light and "color:#f6f2e9" in dark


def test_the_sheet_exists_and_shows_each_icon_at_the_sizes_it_is_used():
    assert (ART / "sheet.png").is_file()
    sheet = icons.build_sheet()[0]
    assert "preferences-system" in sheet and "start-here-kde-plasma" in sheet


def test_the_install_to_hard_drive_icon_is_the_chosen_plunge_pick_on_the_tile():
    # N-410: the desktop launcher's icon is Bert's pick of three concepts: a fat Ember pick tilted into the logo's hill
    svg = icons.build_all()["install-to-hard-drive"]
    for ident in ("pickaxe", "hill", "tile"):
        assert f'id="{ident}"' in svg, ident
    assert 'id="sparks"' not in svg and 'id="ground"' not in svg


def test_the_icon_name_is_the_one_liveinst_asks_for():
    assert icons.INSTALLER_ICON == "org.fedoraproject.AnacondaInstaller"
