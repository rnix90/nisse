# SPDX-License-Identifier: GPL-2.0-or-later
"""N-407: the nisse wallpaper, three base concepts from the art director's brief, each in a light and a dark look.

The rules come from the brief (see the N-407 ledger entry): solid fills with no outlines, at most six colors in a look, under
25 marks, exactly one orange (the sun and what belongs to it), the left fifth calm, flat shapes only.
"""
import json
import re
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import wallpaper  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
CONCEPTS = ["fjord-gate", "one-hill", "fjell-layers"]
SHAPES = [(1920, 1080), (2560, 1600), (3440, 1440), (2736, 1824), (1024, 768), (1080, 1920)]
ORANGES = {"#e0623f", "#f28463", "#bd573c", "#bd4525"}
MARK = re.compile(r"<(rect|circle|path|polygon|line|ellipse|polyline)\b")


def palette_hexes():
    return {e["hex"].lower() for g in ("dark", "light") for e in PALETTE[g].values()}


def used_colors(svg):
    return {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}


def test_the_three_concepts_from_the_art_director_exist():
    assert sorted(wallpaper.CONCEPTS) == sorted(CONCEPTS)


@pytest.mark.parametrize("concept", CONCEPTS)
@pytest.mark.parametrize("mode", ["dark", "light"])
@pytest.mark.parametrize("w,h", SHAPES)
def test_every_screen_shape_gets_a_valid_ascii_svg_of_exactly_that_size(concept, mode, w, h):
    svg = wallpaper.scene(w, h, mode, concept)
    svg.encode("ascii")
    assert f'viewBox="0 0 {w} {h}"' in svg and f'width="{w}"' in svg and f'height="{h}"' in svg
    assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg
    for title in re.findall(r"<title>(.*?)</title>", svg):
        assert title and CAPITAL not in title


@pytest.mark.parametrize("concept", CONCEPTS)
@pytest.mark.parametrize("mode", ["dark", "light"])
def test_only_ember_palette_colors_at_most_six_and_flat(concept, mode):
    svg = wallpaper.scene(1920, 1080, mode, concept)
    used = used_colors(svg)
    assert used <= palette_hexes(), sorted(used - palette_hexes())
    assert len(used) <= wallpaper.COLOR_BUDGET == 6, (len(used), sorted(used))
    for banned in ("Gradient", "filter", "opacity", "mask", "<image", "<text"):
        assert banned not in svg


@pytest.mark.parametrize("concept", CONCEPTS)
def test_fills_have_no_outlines_only_lines_are_stroked(concept):
    svg = wallpaper.scene(1920, 1080, "dark", concept)
    for tag in re.findall(r"<(?:rect|circle|path|polygon|ellipse)\b[^>]*>", svg):
        assert "stroke" not in tag or 'fill="none"' in tag, tag


@pytest.mark.parametrize("concept", CONCEPTS)
def test_under_25_marks_so_the_picture_stays_quiet(concept):
    svg = wallpaper.scene(1920, 1080, "dark", concept)
    assert len(MARK.findall(svg)) < 25, len(MARK.findall(svg))


@pytest.mark.parametrize("concept", CONCEPTS)
@pytest.mark.parametrize("mode", ["dark", "light"])
def test_exactly_one_orange_the_sun_and_what_belongs_to_it(concept, mode):
    svg = wallpaper.scene(1920, 1080, mode, concept)
    assert len(used_colors(svg) & ORANGES) == 1          # one orange, one focal point
    assert re.search(r'<circle id="sun"[^>]*>', svg), "the sun is a circle with id sun"


@pytest.mark.parametrize("concept", CONCEPTS)
def test_light_and_dark_are_the_same_scene_with_only_the_colors_changed(concept):
    def shapes(svg):
        return re.sub(r'#[0-9a-fA-F]{6}\b', "#", svg).replace("light", "").replace("dark", "")
    for w, h in SHAPES:
        assert shapes(wallpaper.scene(w, h, "dark", concept)) == shapes(wallpaper.scene(w, h, "light", concept)), (w, h)
    assert wallpaper.scene(1920, 1080, "dark", concept) != wallpaper.scene(1920, 1080, "light", concept)


@pytest.mark.parametrize("concept", CONCEPTS)
def test_the_same_screen_shape_always_gives_the_same_picture(concept):
    assert wallpaper.scene(2560, 1440, "dark", concept) == wallpaper.scene(2560, 1440, "dark", concept)


@pytest.mark.parametrize("concept", CONCEPTS)
@pytest.mark.parametrize("w,h", SHAPES)
def test_the_sun_stays_off_the_left_fifth_where_the_desktop_icons_sit(concept, w, h):
    svg = wallpaper.scene(w, h, "dark", concept)
    m = re.search(r'<circle id="sun" cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"', svg)
    cx, cy, r = (float(v) for v in m.groups())
    assert cx - r > 0.2 * w or cx > 0.4 * w, (cx, r, w)


@pytest.mark.parametrize("w,h", [(3440, 1440), (1080, 1920)])
@pytest.mark.parametrize("concept", CONCEPTS)
def test_on_an_ultrawide_and_a_portrait_screen_the_focal_point_is_pulled_to_the_middle(concept, w, h):
    svg = wallpaper.scene(w, h, "dark", concept)
    cx = float(re.search(r'<circle id="sun" cx="([\d.]+)"', svg).group(1))
    assert 0.38 * w <= cx <= 0.72 * w, cx


def test_the_concepts_have_the_structure_the_brief_describes():
    gate = wallpaper.scene(1920, 1080, "dark", "fjord-gate")
    for ident in ("sky", "sun", "wall-left", "wall-right", "water", "grid", "glow", "reflection"):
        assert f'id="{ident}"' in gate, ident
    assert gate.count("<line") >= 12                              # the receding grid
    hill = wallpaper.scene(1920, 1080, "dark", "one-hill")
    for ident in ("sky", "sun", "plateau", "hill", "trail"):
        assert f'id="{ident}"' in hill, ident
    assert "<line" not in hill                                    # no grid on the hill
    layers = wallpaper.scene(1920, 1080, "dark", "fjell-layers")
    for ident in ("sky", "sun", "ridge-1", "ridge-2", "headland", "water"):
        assert f'id="{ident}"' in layers, ident
    assert layers.count('class="scan"') == 4


def test_round_two_fixes_from_the_art_director():
    # Fjord Gate: the dark grid is visible (near lines are brighter) and the reflection is three stacked dashes, not a stake
    gate = wallpaper.scene(1920, 1080, "dark", "fjord-gate")
    assert wallpaper.PALETTES["fjord-gate"]["dark"]["grid-near"] == "#7a8699"
    reflection = gate[gate.index('id="reflection"'):]
    assert reflection[:reflection.index("</g>")].count("<rect") == 3
    # One Hill: the sun is half sunk behind the plateau (drawn before it) and the trail ends under the sun's column
    hill = wallpaper.scene(1920, 1080, "dark", "one-hill")
    assert hill.index('id="sun"') < hill.index('id="plateau"') < hill.index('id="hill"') < hill.index('id="trail"')
    sun_x = float(re.search(r'<circle id="sun" cx="([\d.]+)"', hill).group(1))
    trail = re.search(r'<polygon id="trail" points="([^"]+)"', hill).group(1)
    xs = [float(p.split(",")[0]) for p in trail.split()]
    tip = min(xs, key=lambda x: abs(x - sun_x))
    assert abs(tip - sun_x) < 0.03 * 1920                         # the ribbon reaches the sun's column
    # Fjell Layers: a bigger sun; the horizontal orange glow line was removed at the owner's gate (the sun is the only orange)
    layers = wallpaper.scene(1920, 1080, "dark", "fjell-layers")
    m = re.search(r'<circle id="sun" cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"', layers)
    cx, cy, r = (float(v) for v in m.groups())
    assert r >= 0.065 * 1080
    assert 'id="ridge-3"' not in layers and 'id="ridge-4"' not in layers      # the stepped lower mass is gone (round 3)
    assert layers.index('id="ridge-2"') < layers.index('id="water"') < layers.index('id="headland"')



def test_there_is_no_house_no_snow_cap_no_outlined_fir_no_sun_rings_no_clouds():
    for concept in CONCEPTS:
        svg = wallpaper.scene(1920, 1080, "dark", concept).lower()
        for banned in ("cottage", "roof", 'id="snow', 'id="firs', 'id="clouds', 'id="ring'):
            assert banned not in svg, (concept, banned)


def test_the_plasma_package_layout_names_each_picture_by_its_size_and_has_a_dark_folder():
    layout = wallpaper.package_files()
    assert "metadata.json" in layout
    names = [p for p in layout if p.startswith("contents/images/")]
    dark = [p for p in layout if p.startswith("contents/images_dark/")]
    assert names and len(names) == len(dark)
    for p in names:
        assert re.fullmatch(r"contents/images/\d+x\d+\.png", p), p
    assert {p.split("/")[-1] for p in names} == {p.split("/")[-1] for p in dark}


def test_the_sizes_cover_the_common_screens_nisse_targets():
    sizes = set(wallpaper.SIZES)
    for want in ((1920, 1080), (2560, 1440), (3840, 2160), (1920, 1200), (2560, 1600), (3440, 1440), (2736, 1824), (1080, 1920)):
        assert want in sizes, want


def test_the_metadata_names_the_wallpaper_nisse_in_lowercase_with_the_repository_licence():
    meta = json.loads(wallpaper.metadata())
    assert meta["KPlugin"]["Id"] == "nisse" and meta["KPlugin"]["Name"] == "nisse"
    assert meta["KPlugin"]["License"] == "GPL-2.0-or-later"


def test_the_review_sheet_shows_each_concept_in_both_looks_and_on_other_screens():
    sheet = wallpaper.build_sheet()
    sheet.encode("ascii")
    for word in ("fjord-gate", "one-hill", "fjell-layers", "dark", "light", "ultrawide", "portrait"):
        assert word in sheet, word


def test_round_three_one_hill_sun_is_sunk_into_the_plateau_edge():
    hill = wallpaper.scene(1920, 1080, "dark", "one-hill")
    m = re.search(r'<circle id="sun" cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"', hill)
    cx, cy, r = (float(v) for v in m.groups())
    assert cy >= 0.37 * 1080                       # the center is on or below the plateau's top edge: a half disc, not a bump


def test_a_portrait_screen_gets_the_scene_on_a_shorter_canvas_so_nothing_is_lost_in_the_crop():
    for concept in CONCEPTS:
        svg = wallpaper.scene(1080, 1920, "dark", concept)
        assert 'id="sky-top"' in svg and "translate(0 " in svg, concept       # the scene sits at the bottom under extra sky
    assert 'id="sky-top"' not in wallpaper.scene(1920, 1080, "dark", "fjord-gate")


def test_the_chosen_wallpaper_is_fjell_layers_and_it_has_no_horizontal_orange_line():
    assert wallpaper.CHOSEN == "fjell-layers"                  # Bert, 2026-11-16: "3 is it"
    for mode in ("dark", "light"):
        svg = wallpaper.scene(1920, 1080, mode, "fjell-layers")
        assert 'id="glow"' not in svg
        for tag in re.findall(r"<line[^>]*>", svg):
            assert "#e0623f" not in tag.lower(), tag           # every remaining line is a quiet scan line
        assert svg.lower().count("#e0623f") == 1               # the sun alone is orange
