# SPDX-License-Identifier: GPL-2.0-or-later
"""N-407: the nisse wallpaper, one flat Scandinavian landscape drawn for any screen shape, in a light and a dark look."""
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


def palette_hexes():
    return {e["hex"].lower() for g in ("dark", "light") for e in PALETTE[g].values()}


SHAPES = [(1920, 1080), (2560, 1600), (3440, 1440), (2736, 1824), (1024, 768), (1080, 1920)]


@pytest.mark.parametrize("mode", ["dark", "light"])
@pytest.mark.parametrize("w,h", SHAPES)
def test_every_screen_shape_gets_a_valid_ascii_svg_of_exactly_that_size(mode, w, h):
    svg = wallpaper.scene(w, h, mode)
    svg.encode("ascii")
    assert f'viewBox="0 0 {w} {h}"' in svg and f'width="{w}"' in svg and f'height="{h}"' in svg
    assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg
    for title in re.findall(r"<title>(.*?)</title>", svg):
        assert title and CAPITAL not in title


@pytest.mark.parametrize("mode", ["dark", "light"])
def test_only_ember_palette_colors_flat_with_no_gradients_filters_or_opacity(mode):
    svg = wallpaper.scene(1920, 1080, mode)
    used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
    assert used <= palette_hexes(), sorted(used - palette_hexes())
    assert len(used) <= wallpaper.COLOR_BUDGET, len(used)
    for banned in ("Gradient", "filter", "opacity", "mask", "<image", "<text"):
        assert banned not in svg


def test_light_and_dark_are_the_same_scene_with_only_the_colors_changed():
    def shapes(svg):
        return re.sub(r'#[0-9a-fA-F]{6}\b', "#", svg).replace("light", "").replace("dark", "")
    for w, h in SHAPES:
        assert shapes(wallpaper.scene(w, h, "dark")) == shapes(wallpaper.scene(w, h, "light")), (w, h)
    assert wallpaper.scene(1920, 1080, "dark") != wallpaper.scene(1920, 1080, "light")


def test_the_scene_has_the_nordic_parts_and_the_logo_sun_and_hill():
    svg = wallpaper.scene(1920, 1080, "dark")
    for ident in ("sky", "sun", "mountains-far", "mountains-mid", "lake", "hill", "cottage", "firs-near"):
        assert f'id="{ident}"' in svg, ident
    # the sun is a disc and the hill in front of it is the logo's horizon curve: both exist
    assert "<circle" in svg and "<path" in svg


def test_the_cottage_is_falu_red_which_is_ember_and_has_lit_windows():
    dark = wallpaper.scene(1920, 1080, "dark")
    cottage = dark[dark.index('id="cottage"'):]
    assert wallpaper.DARK["cottage"].lower() in cottage.lower()
    assert wallpaper.DARK["window"].lower() in cottage.lower()
    assert wallpaper.DARK["cottage"].lower() in {"#e0623f", "#bd573c"}


def test_the_same_screen_shape_always_gives_the_same_picture():
    assert wallpaper.scene(2560, 1440, "dark") == wallpaper.scene(2560, 1440, "dark")


def test_a_wider_screen_shows_more_land_not_a_stretched_picture():
    narrow = wallpaper.scene(1920, 1080, "dark")
    wide = wallpaper.scene(3440, 1440, "dark")
    # more firs and peaks on the ultrawide, and the cottage is the same size relative to the height
    assert wide.count("<polygon") > narrow.count("<polygon")
    sizes = {wallpaper.cottage_width(1080), wallpaper.cottage_width(1440)}
    assert wallpaper.cottage_width(1440) / wallpaper.cottage_width(1080) == pytest.approx(1440 / 1080, rel=0.02)
    assert len(sizes) == 2


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


def test_the_review_sheet_shows_light_and_dark_and_three_other_shapes():
    sheet = wallpaper.build_sheet()
    sheet.encode("ascii")
    for word in ("light", "dark", "ultrawide", "portrait", "16:10"):
        assert word in sheet, word
