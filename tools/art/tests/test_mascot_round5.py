# SPDX-License-Identifier: GPL-2.0-or-later
"""N-402 round 5: the master (gumdrop body with the robe face) and four tool and hand options on it."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import mascot_round5  # noqa: E402

ROOT = HERE.parents[2]
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
NUMBERS = range(1, 5)
COLOR_BUDGET = 6
TOOLS = {"1": "pickaxe", "2": "pickaxe", "3": "hammer", "4": "lantern"}


def palette_hexes():
    out = set()
    for group in ("dark", "light"):
        for entry in PALETTE[group].values():
            out.add(entry["hex"].lower())
    return out


def test_the_master_badge_and_four_tool_figures():
    want = sorted(["master-head"] + [f"{n}-figure" for n in NUMBERS])
    assert sorted(mascot_round5.build_all()) == want


def test_every_svg_is_ascii_with_a_licence_header_and_a_view_box():
    for name, svg in mascot_round5.build_all().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert re.search(r'viewBox="0 0 \d+ \d+"', svg), name
        assert "<title>" in svg, name


def test_only_palette_colors_and_no_gradients_or_filters():
    allowed = palette_hexes()
    for name, svg in mascot_round5.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert used <= allowed, (name, sorted(used - allowed))
        assert "Gradient" not in svg and "filter" not in svg, name


def test_minimalism_budget_no_drawing_uses_more_than_six_colors():
    for name, svg in mascot_round5.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert len(used) <= COLOR_BUDGET, (name, len(used), sorted(used))


def test_one_width_and_the_head_touches_the_body():
    spec = mascot_round5.spec()
    assert spec["cap_w"] == spec["face_w"] == spec["beard_w"], spec
    assert spec["body_top"] <= spec["head_bottom"], spec


def test_every_drawing_has_the_robe_face_a_skin_band_two_eyes_and_a_nose():
    for name, svg in mascot_round5.build_all().items():
        assert 'id="face"' in svg and 'id="nose"' in svg, name
        assert svg.count('id="eye"') == 2, name


def test_each_figure_holds_its_own_tool_and_the_badge_holds_none():
    parts = mascot_round5.build_all()
    for n, tool in TOOLS.items():
        assert f'id="{tool}"' in parts[f"{n}-figure"], (n, tool)
    for tool in ("pickaxe", "hammer", "lantern"):
        assert f'id="{tool}"' not in parts["master-head"], tool
    assert 'id="hammer"' not in parts["1-figure"] and 'id="lantern"' not in parts["3-figure"]


def test_the_pick_head_is_big_enough_to_read():
    assert mascot_round5.PICK_HALF_SPAN * 2 >= 140


def test_the_name_is_lowercase_and_no_off_brand_hues():
    for name, svg in mascot_round5.build_all().items():
        for title in re.findall(r"<title>(.*?)</title>", svg):
            assert "Nisse" not in title, (name, title)
        low = svg.lower()
        assert "#4caf7a" not in low and "#5aa0e0" not in low and "#e5a93d" not in low, name


def test_the_four_figures_are_really_different():
    parts = mascot_round5.build_all()
    bodies = {n: re.sub(r"<title>.*?</title>|aria-label=\"[^\"]*\"", "", s) for n, s in parts.items()}
    assert len(set(bodies.values())) == len(bodies)


def test_the_sheet_numbers_all_four_and_names_the_master():
    sheet = mascot_round5.build_sheet()
    sheet.encode("ascii")
    for n in NUMBERS:
        assert f">{n}<" in sheet, n
    assert "master" in sheet
