# SPDX-License-Identifier: GPL-2.0-or-later
"""N-402: the first round of gnome mascot options. Each option is scripted SVG made from the Ember palette only."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import mascot_options  # noqa: E402

ROOT = HERE.parents[2]
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))


def palette_hexes():
    out = set()
    for group in ("dark", "light"):
        for entry in PALETTE[group].values():
            out.add(entry["hex"].lower())
    return out


def test_four_options_each_with_a_head_badge_and_a_figure():
    parts = mascot_options.build_all()
    names = sorted(parts)
    assert names == sorted(f"{o}-{k}" for o in ("a", "b", "c", "d") for k in ("head", "figure")), names


def test_every_svg_is_ascii_with_a_licence_header_and_a_view_box():
    for name, svg in mascot_options.build_all().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert re.search(r'viewBox="0 0 \d+ \d+"', svg), name
        assert "<title>" in svg, name


def test_only_palette_colors_and_no_gradients():
    allowed = palette_hexes()
    for name, svg in mascot_options.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert used <= allowed, (name, sorted(used - allowed))
        assert "Gradient" not in svg and "filter" not in svg, name


def test_the_name_is_lowercase_in_every_title():
    for name, svg in mascot_options.build_all().items():
        for title in re.findall(r"<title>(.*?)</title>", svg):
            assert "Nisse" not in title, (name, title)


def test_every_figure_has_a_pickaxe_and_the_head_badges_do_not():
    parts = mascot_options.build_all()
    for opt in ("a", "b", "c", "d"):
        assert 'id="pickaxe"' in parts[f"{opt}-figure"], opt
        assert 'id="pickaxe"' not in parts[f"{opt}-head"], opt


def test_the_sheet_holds_all_eight_drawings_and_numbers_them():
    sheet = mascot_options.build_sheet()
    sheet.encode("ascii")
    for n in range(1, 5):
        assert f">{n}<" in sheet, n
