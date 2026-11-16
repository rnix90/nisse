# SPDX-License-Identifier: GPL-2.0-or-later
"""N-402 round 2: eight gnome mascot options, scripted SVG made from the Ember palette only."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import mascot_round2  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
NUMBERS = range(1, 9)


def palette_hexes():
    out = set()
    for group in ("dark", "light"):
        for entry in PALETTE[group].values():
            out.add(entry["hex"].lower())
    return out


def test_eight_options_each_with_a_head_badge_and_a_figure():
    names = sorted(mascot_round2.build_all())
    want = sorted(f"{n}-{k}" for n in NUMBERS for k in ("head", "figure"))
    assert names == want, names


def test_every_svg_is_ascii_with_a_licence_header_and_a_view_box():
    for name, svg in mascot_round2.build_all().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert re.search(r'viewBox="0 0 \d+ \d+"', svg), name
        assert "<title>" in svg, name


def test_only_palette_colors_and_no_gradients_or_filters():
    allowed = palette_hexes()
    for name, svg in mascot_round2.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert used <= allowed, (name, sorted(used - allowed))
        assert "Gradient" not in svg and "filter" not in svg, name


def test_the_name_is_lowercase_in_every_title():
    for name, svg in mascot_round2.build_all().items():
        for title in re.findall(r"<title>(.*?)</title>", svg):
            assert CAPITAL not in title, (name, title)


def test_every_figure_has_a_pickaxe_and_the_head_badges_do_not():
    parts = mascot_round2.build_all()
    for n in NUMBERS:
        assert 'id="pickaxe"' in parts[f"{n}-figure"], n
        assert 'id="pickaxe"' not in parts[f"{n}-head"], n


def test_the_pick_head_is_big_enough_to_read():
    # round 1 critique: the pick head read as an umbrella; it must now span at least 140 units
    assert mascot_round2.PICK_HALF_SPAN * 2 >= 140


def test_the_eight_options_are_really_different():
    parts = mascot_round2.build_all()
    bodies = {name: re.sub(r"<title>.*?</title>|aria-label=\"[^\"]*\"", "", svg) for name, svg in parts.items()}
    assert len(set(bodies.values())) == len(bodies)
    for n in NUMBERS:
        assert bodies[f"{n}-head"] != bodies[f"{n}-figure"]


def test_the_sheet_numbers_all_eight():
    sheet = mascot_round2.build_sheet()
    sheet.encode("ascii")
    for n in NUMBERS:
        assert f">{n}<" in sheet, n
