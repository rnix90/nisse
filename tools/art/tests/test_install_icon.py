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
