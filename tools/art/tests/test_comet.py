# SPDX-License-Identifier: GPL-2.0-or-later
"""N-404: the comet busy spinner. One static Paper drawing that Plasma's splash turns with a RotationAnimator:
a round head and a tapered tail on a circle, with a thin see-through curve between them like the horizon curve of the logo."""
import gzip
import math
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import comet  # noqa: E402

PAPER = "#f6f2e9"
NAMES = ["nisse-comet", "nisse-comet-ink", "nisse-comet-black", "nisse-comet-white", "nisse-comet-symbolic", "nisse-comet-frame"]


def test_the_forms_exist():
    assert sorted(comet.build_forms()) == sorted(NAMES)


def test_every_svg_is_ascii_with_a_licence_header_a_view_box_and_a_lowercase_title():
    capital = "N" + "isse"
    for name, svg in comet.build_forms().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        want = "0 0 512 512" if name.endswith("frame") else "0 0 136 136"
        assert f'viewBox="{want}"' in svg, name
        titles = re.findall(r"<title>(.*?)</title>", svg)
        assert titles and all(capital not in t for t in titles), (name, titles)


def test_the_spinner_is_all_paper_one_flat_color_with_no_ember_masks_gradients_or_opacity():
    svg = comet.build_forms()["nisse-comet"]
    assert {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)} == {PAPER}
    for bad in ("mask", "Gradient", "filter", "opacity", "#e0623f"):
        assert bad not in svg, bad   # Qt's SVG loader (the splash uses an Image) must draw it, and Bert asked for no Ember


def test_the_other_colorways_and_the_symbolic_form():
    forms = comet.build_forms()
    assert 'fill="#1b2330"' in forms["nisse-comet-ink"]
    assert 'fill="#000000"' in forms["nisse-comet-black"] and 'fill="#ffffff"' in forms["nisse-comet-white"]
    assert "currentColor" in forms["nisse-comet-symbolic"]


def test_the_head_rides_the_orbit_and_everything_fits_with_room_in_the_square():
    g = comet.geometry()
    assert (g["cx"], g["cy"]) == (68.0, 68.0), "the orbit centre is the view box centre, so rotation is clean"
    assert abs(math.dist((g["cx"], g["cy"]), g["head"]) - g["orbit_r"]) < 1e-6
    assert g["max_extent"] <= 68 - 4, g["max_extent"]


def test_a_thin_see_through_gap_curves_round_the_head_and_separates_it_from_the_tail():
    g = comet.geometry()
    assert 3.0 <= g["gap"] <= 5.0, "thin like the logo horizon, but wide enough to survive a 36 px spinner"
    for p in g["tail_points"]:
        assert math.dist(p, g["head"]) >= g["head_r"] + g["gap"] - 0.05, p
    assert abs(g["min_tail_distance"] - (g["head_r"] + g["gap"])) < 0.05, "the gap hugs the head: it is a curve, not a straight cut"
    assert " A" in comet.tail_path(), "the tail's front edge is an arc concentric with the head"


def test_the_tail_tapers_to_a_point_and_trails_the_head():
    g = comet.geometry()
    assert g["width_at_head"] >= 12 and g["width_at_end"] == 0
    assert g["tail_end_theta"] < 0 < g["span"], "the head leads: the tail is behind it, counter-clockwise, as the image turns clockwise"


def test_the_svgz_is_the_paper_svg_gzipped():
    data = comet.build_svgz()
    assert gzip.decompress(data).decode("ascii") == comet.build_forms()["nisse-comet"]


def test_the_frame_shows_the_n_with_its_hat_inside_the_comet_ring():
    frame = comet.build_forms()["nisse-comet-frame"]
    assert comet.NMARK.HAT in frame
    assert comet.tail_path() in frame or "nisse-comet-ring" in frame
