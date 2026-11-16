# SPDX-License-Identifier: GPL-2.0-or-later
"""N-402 final set: the master gnome as a head badge, standing, waving and working with the pickaxe, plus the style guide."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import mascot_final  # noqa: E402

ROOT = HERE.parents[2]
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
STYLE = ROOT / "assets" / "art" / "STYLE.md"
NAMES = ["nisse-gnome-head", "nisse-gnome-standing", "nisse-gnome-waving", "nisse-gnome-working"]


def palette_hexes():
    out = set()
    for group in ("dark", "light"):
        for entry in PALETTE[group].values():
            out.add(entry["hex"].lower())
    return out


def test_the_four_final_drawings():
    assert sorted(mascot_final.build_all()) == sorted(NAMES)


def test_every_svg_is_ascii_with_a_licence_header_and_a_view_box_and_a_lowercase_title():
    for name, svg in mascot_final.build_all().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert re.search(r'viewBox="0 0 \d+ \d+"', svg), name
        for title in re.findall(r"<title>(.*?)</title>", svg):
            assert "Nisse" not in title and title, (name, title)


def test_only_palette_colors_within_the_six_color_budget_and_no_gradients():
    allowed = palette_hexes()
    for name, svg in mascot_final.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert used <= allowed, (name, sorted(used - allowed))
        assert len(used) <= 6, (name, len(used))
        assert "Gradient" not in svg and "filter" not in svg, name


def test_every_drawing_has_the_face_two_eyes_and_a_nose():
    for name, svg in mascot_final.build_all().items():
        assert 'id="face"' in svg and 'id="nose"' in svg and svg.count('id="eye"') == 2, name


def test_only_the_working_pose_holds_the_pickaxe_and_the_wave_has_a_raised_hand():
    parts = mascot_final.build_all()
    assert 'id="pickaxe"' in parts["nisse-gnome-working"]
    for name in ("nisse-gnome-head", "nisse-gnome-standing", "nisse-gnome-waving"):
        assert 'id="pickaxe"' not in parts[name], name
    assert 'id="wave"' in parts["nisse-gnome-waving"]


def test_the_four_are_different_and_the_sheet_shows_all_four():
    parts = mascot_final.build_all()
    bodies = {n: re.sub(r"<title>.*?</title>|aria-label=\"[^\"]*\"", "", s) for n, s in parts.items()}
    assert len(set(bodies.values())) == 4
    sheet = mascot_final.build_sheet()
    sheet.encode("ascii")
    for word in ("head badge", "standing", "waving", "working"):
        assert word in sheet, word


def test_the_style_guide_exists_names_the_rules_and_uses_only_palette_colors():
    text = STYLE.read_text(encoding="ascii")
    for needle in ("one width", "six colors", "head touches the body", "hooked cap", "Ember"):
        assert needle in text, needle
    assert "Nisse" not in re.sub(r"`[^`]*`", "", text), "the name is lowercase"
    used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", text)}
    assert used <= palette_hexes(), sorted(used - palette_hexes())
