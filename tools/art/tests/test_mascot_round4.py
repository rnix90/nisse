# SPDX-License-Identifier: GPL-2.0-or-later
"""N-402 round 4: four minimalist tomte, simplified to the logo's language after Bert's round-3 verdict
(heads too far from bodies, beards not matching head widths, keep it minimal like the logo)."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import mascot_round4  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
NUMBERS = range(1, 5)
COLOR_BUDGET = 6


def palette_hexes():
    out = set()
    for group in ("dark", "light"):
        for entry in PALETTE[group].values():
            out.add(entry["hex"].lower())
    return out


def test_four_options_each_with_a_badge_and_a_figure_and_one_waving_pose():
    want = sorted([f"{n}-{k}" for n in NUMBERS for k in ("head", "figure")] + ["1-wave"])
    assert sorted(mascot_round4.build_all()) == want


def test_every_svg_is_ascii_with_a_licence_header_and_a_view_box():
    for name, svg in mascot_round4.build_all().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert re.search(r'viewBox="0 0 \d+ \d+"', svg), name
        assert "<title>" in svg, name


def test_only_palette_colors_and_no_gradients_or_filters():
    allowed = palette_hexes()
    for name, svg in mascot_round4.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert used <= allowed, (name, sorted(used - allowed))
        assert "Gradient" not in svg and "filter" not in svg, name


def test_minimalism_budget_no_drawing_uses_more_than_six_colors():
    for name, svg in mascot_round4.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert len(used) <= COLOR_BUDGET, (name, len(used), sorted(used))


def test_one_width_cap_face_and_beard_match_and_the_head_touches_the_body():
    for n, spec in mascot_round4.specs().items():
        assert spec["cap_w"] == spec["face_w"] == spec["beard_w"], (n, spec)
        assert spec["body_top"] <= spec["head_bottom"], (n, "gap between head and body", spec)


def test_the_name_is_lowercase_in_every_title():
    for name, svg in mascot_round4.build_all().items():
        for title in re.findall(r"<title>(.*?)</title>", svg):
            assert CAPITAL not in title, (name, title)


def test_working_figures_have_a_pickaxe_and_badges_and_the_wave_do_not():
    parts = mascot_round4.build_all()
    for n in NUMBERS:
        assert 'id="pickaxe"' in parts[f"{n}-figure"], n
        assert 'id="pickaxe"' not in parts[f"{n}-head"], n
    assert 'id="pickaxe"' not in parts["1-wave"]


def test_the_pick_head_is_big_enough_to_read():
    assert mascot_round4.PICK_HALF_SPAN * 2 >= 140


def test_no_off_brand_hues_no_green_no_blue_and_no_ears_no_details_the_reviews_flagged():
    for name, svg in mascot_round4.build_all().items():
        low = svg.lower()
        assert "#4caf7a" not in low and "#5aa0e0" not in low and "#e5a93d" not in low, name
        assert 'id="ear"' not in low, name


def test_the_four_are_really_different():
    parts = mascot_round4.build_all()
    bodies = {n: re.sub(r"<title>.*?</title>|aria-label=\"[^\"]*\"", "", s) for n, s in parts.items()}
    assert len(set(bodies.values())) == len(bodies)


def test_the_sheet_numbers_all_four_and_marks_the_wave():
    sheet = mascot_round4.build_sheet()
    sheet.encode("ascii")
    for n in NUMBERS:
        assert f">{n}<" in sheet, n
    assert "waving" in sheet
