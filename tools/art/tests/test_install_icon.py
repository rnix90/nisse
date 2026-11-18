# SPDX-License-Identifier: GPL-2.0-or-later
"""N-410: the Install to Hard Drive launcher icon, three concepts from the art director's brief (stand-alone on the desktop)."""
import json
import re
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import install_icon  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
CONCEPTS = ["hat-pick", "plunge", "shoulder-pick"]


def palette_hexes():
    return {e["hex"].lower() for g in ("dark", "light") for e in PALETTE[g].values()}


def used(svg):
    return {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}


def test_the_three_concepts_exist():
    assert sorted(install_icon.CONCEPTS) == sorted(CONCEPTS)


@pytest.mark.parametrize("concept", CONCEPTS)
@pytest.mark.parametrize("mode", ["dark", "light"])
def test_every_concept_in_both_looks_is_a_clean_flat_ascii_svg_in_palette_colors(concept, mode):
    svg = install_icon.build(concept, mode)
    svg.encode("ascii")
    assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg and 'viewBox="0 0 96 96"' in svg
    assert used(svg) <= palette_hexes() | {"#000000", "#ffffff"}, used(svg)          # #000 and #fff drive a mask
    for banned in ("Gradient", "filter", "opacity", "<image", "<text", "stroke-dasharray"):
        assert banned not in svg
    assert CAPITAL not in svg
    for title in re.findall(r"<title>(.*?)</title>", svg):
        assert title and CAPITAL not in title


@pytest.mark.parametrize("concept", ["hat-pick", "plunge"])
def test_the_two_bold_concepts_use_at_most_three_colors_and_no_sparks(concept):
    for mode in ("dark", "light"):
        svg = install_icon.build(concept, mode)
        colors = used(svg) - {"#000000", "#ffffff"}
        assert len(colors) <= 3, (concept, mode, colors)
        assert 'id="sparks"' not in svg
    assert "#e0623f" in install_icon.build(concept, "dark")                           # Ember carries the main mass


def test_tile_less_on_dark_and_an_ink_tile_on_light_where_the_concept_needs_one():
    for concept, tile_on_light in (("hat-pick", False), ("plunge", True), ("shoulder-pick", True)):
        assert 'id="tile"' not in install_icon.build(concept, "dark"), concept
        assert ('id="tile"' in install_icon.build(concept, "light")) == tile_on_light, concept


def test_hat_pick_is_the_logo_disc_with_a_pick_showing_through_and_the_horizon_gap():
    svg = install_icon.build("hat-pick", "dark")
    for ident in ("disc", "pickaxe"):
        assert f'id="{ident}"' in svg
    assert "mask=" in svg and 'stroke-width="2.4"' in svg                             # the pick is a cutout; the horizon is a see-through line
    disc = re.search(r'<circle id="disc" cx="48" cy="48" r="([\d.]+)"', svg)
    assert disc and 2 * float(disc.group(1)) >= 0.84 * 96                             # the disc fills at least 84% of the canvas
    assert re.search(r'<circle id="disc"[^>]*fill="#f6f2e9"', svg)                    # Paper on dark ...
    assert re.search(r'<circle id="disc"[^>]*fill="#1b2330"', install_icon.build("hat-pick", "light"))    # ... Ink on light


def test_plunge_is_a_fat_upright_ember_pick_driven_into_the_logos_hill_which_is_in_front_of_its_foot():
    svg = install_icon.build("plunge", "dark")
    for ident in ("pickaxe", "hill"):
        assert f'id="{ident}"' in svg
    assert svg.index('id="pickaxe"') < svg.index('id="hill"')                         # the foot is buried
    handle = re.search(r'<rect id="handle" x="(-?[\d.]+)" y="[\d.]+" width="([\d.]+)"', svg)
    assert handle and float(handle.group(2)) >= 0.11 * 96                             # a fat handle, about 0.12 of the canvas
    assert re.search(r'<path id="head" d="M-[\d.]+ [\d.]+ Q', svg)                    # the head is a crescent (two quadratic arcs)
    assert "rotate(20" in svg                                                         # tilted 20 degrees about its buried foot (no symmetric T)


def test_shoulder_pick_is_the_gnome_head_with_the_pick_resting_behind_it():
    svg = install_icon.build("shoulder-pick", "dark")
    for ident in ("pickaxe", "cap", "face", "nose"):
        assert f'id="{ident}"' in svg, ident
    assert svg.index('id="pickaxe"') < svg.index('id="face"')                         # the pick is behind the head
    import mascot_final
    assert mascot_final.HAT_D in svg                                                  # the logo's exact hat


def test_the_sheet_shows_all_three_in_both_looks_at_the_desktop_size():
    sheet = install_icon.build_sheet()
    sheet.encode("ascii")
    for word in ("hat-pick", "plunge", "shoulder-pick", "dark", "light"):
        assert word in sheet


def test_the_pick_head_is_a_real_crescent_not_a_dome_round_two_fix():
    # art director, round 1: a plano-convex dome reads as a mushroom; a pick head is a thin crescent that droops to points
    assert install_icon.HEAD_W == pytest.approx(0.66 * 96)
    assert install_icon.HEAD_T == pytest.approx(0.09 * 96) and install_icon.HEAD_DROP == pytest.approx(0.18 * 96)
    d = install_icon.crescent_d(install_icon.HEAD_W, install_icon.HEAD_T, install_icon.HEAD_DROP)
    nums = [float(v) for v in re.findall(r"-?\d+\.?\d*", d)]
    assert d.startswith("M-") and d.count("Q") == 2 and d.endswith("Z")
    tip_x, tip_y = nums[0], nums[1]
    assert tip_y > install_icon.HEAD_T * 1.5                                         # the tips drop well below the centre thickness
    assert abs(tip_x) == pytest.approx(install_icon.HEAD_W / 2, abs=0.1)


def test_hat_pick_fills_most_of_the_disc_with_the_big_crescent_head():
    svg = install_icon.build("hat-pick", "dark")
    assert "translate(48 " in svg and f'{install_icon.crescent_d(install_icon.HEAD_W, install_icon.HEAD_T, install_icon.HEAD_DROP)}' in svg


def test_shoulder_pick_has_the_bigger_head_round_two_fix():
    assert install_icon.SHOULDER_HEAD_SCALE >= 0.33


def test_the_chosen_concept_is_plunge_and_on_the_tile_it_is_smaller_so_the_hill_clears_the_tile_edge():
    assert install_icon.CHOSEN == "plunge"                                            # Bert, 2026-11-18
    light = install_icon.build("plunge", "light")
    m = re.search(r'<g id="scaled" transform="translate\(48 48\) scale\(([\d.]+)\) translate\(-48 -48\)">', light)
    assert m and float(m.group(1)) <= 0.88
    s = float(m.group(1))
    left = 48 + (4 - 48) * s                                                           # the hill's left edge after scaling
    right = 48 + (92 - 48) * s
    bottom = 48 + (92 - 48) * s
    assert left >= 8 and 96 - right >= 8 and 96 - bottom >= 8                         # at least 8 units of tile all round
    assert 'id="scaled"' not in install_icon.build("plunge", "dark")                  # tile-less: the full size


def test_the_installer_icon_in_the_overlay_themes_is_plunge_dark_and_light_and_the_hicolor_one_is_the_tile_version():
    import icons
    root = ROOT / "assets" / "art" / "icons"
    name = icons.INSTALLER_ICON
    assert (root / "nisse_icons_dark" / "scalable" / "apps" / f"{name}.svg").read_text(encoding="ascii") == install_icon.build("plunge", "dark")
    assert (root / "nisse_icons" / "scalable" / "apps" / f"{name}.svg").read_text(encoding="ascii") == install_icon.build("plunge", "light")
    assert icons.build_all()["install-to-hard-drive"] == install_icon.build("plunge", "light")
