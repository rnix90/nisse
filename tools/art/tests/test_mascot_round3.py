# SPDX-License-Identifier: GPL-2.0-or-later
"""N-402 round 3: four tomte variants built from the two critique reviews, plus a waving pose."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import mascot_round3  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
NUMBERS = range(1, 5)
GREEN, BLUE = "#4caf7a", "#5aa0e0"


def palette_hexes():
    out = set()
    for group in ("dark", "light"):
        for entry in PALETTE[group].values():
            out.add(entry["hex"].lower())
    return out


def test_four_options_each_with_a_badge_and_a_figure_and_one_waving_pose():
    want = sorted([f"{n}-{k}" for n in NUMBERS for k in ("head", "figure")] + ["1-wave"])
    assert sorted(mascot_round3.build_all()) == want


def test_every_svg_is_ascii_with_a_licence_header_and_a_view_box():
    for name, svg in mascot_round3.build_all().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert re.search(r'viewBox="0 0 \d+ \d+"', svg), name
        assert "<title>" in svg, name


def test_only_palette_colors_and_no_gradients_or_filters():
    allowed = palette_hexes()
    for name, svg in mascot_round3.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert used <= allowed, (name, sorted(used - allowed))
        assert "Gradient" not in svg and "filter" not in svg, name


def test_the_name_is_lowercase_in_every_title():
    for name, svg in mascot_round3.build_all().items():
        for title in re.findall(r"<title>(.*?)</title>", svg):
            assert CAPITAL not in title, (name, title)


def test_working_figures_have_a_pickaxe_and_badges_and_the_wave_do_not():
    parts = mascot_round3.build_all()
    for n in NUMBERS:
        assert 'id="pickaxe"' in parts[f"{n}-figure"], n
        assert 'id="pickaxe"' not in parts[f"{n}-head"], n
    assert 'id="pickaxe"' not in parts["1-wave"]


def test_the_pick_head_is_big_and_has_two_different_sides():
    assert mascot_round3.PICK_HALF_SPAN * 2 >= 140
    svg = mascot_round3.build_all()["1-figure"]
    assert 'id="pick-spike"' in svg and 'id="pick-adze"' in svg


def test_review_findings_are_kept_no_green_robes_and_blue_only_on_the_goggles():
    parts = mascot_round3.build_all()
    for name, svg in parts.items():
        assert GREEN not in svg.lower(), name
    for name, svg in parts.items():
        if not name.startswith("3-"):
            assert BLUE not in svg.lower(), name
    assert BLUE in parts["3-figure"].lower()


def test_no_pointed_ears_the_review_called_them_elf_not_tomte():
    for name, svg in mascot_round3.build_all().items():
        assert 'id="ear"' not in svg, name


def test_the_four_are_really_different():
    parts = mascot_round3.build_all()
    bodies = {n: re.sub(r"<title>.*?</title>|aria-label=\"[^\"]*\"", "", s) for n, s in parts.items()}
    assert len(set(bodies.values())) == len(bodies)


def test_the_sheet_numbers_all_four_and_marks_the_wave():
    sheet = mascot_round3.build_sheet()
    sheet.encode("ascii")
    for n in NUMBERS:
        assert f">{n}<" in sheet, n
    assert "waving" in sheet
