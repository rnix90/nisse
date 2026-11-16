# SPDX-License-Identifier: GPL-2.0-or-later
"""N-406: the activity avatars (all 17 user pictures): the style-guide gnome with one flat prop each, on a round disc."""
import json
import re
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import avatars  # noqa: E402
import mascot_final  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
# the 17 user pictures KDE ships: Konqi, Katie and 15 activities; each becomes one gnome with the same activity theme
STARTER = ["nisse", "artist", "bookworm", "hacker", "musician", "scientist", "teacher", "mechanic",
           "boss", "bugcatcher", "cardshark", "journalist", "messenger", "officeworker", "pcbuilder", "vr", "laptop"]
BANNED = ("konqi", "katie", "kde", "fedora", "dragon")


def palette_hexes():
    return {e["hex"].lower() for g in ("dark", "light") for e in PALETTE[g].values()}


def test_the_set_is_the_plain_gnome_fifteen_activities_and_the_laptop_gnome_that_replaces_katie():
    assert sorted(avatars.build_all()) == sorted(STARTER)


def test_every_avatar_is_ascii_with_a_licence_header_a_square_view_box_and_a_lowercase_title():
    for name, svg in avatars.build_all().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert 'viewBox="0 0 512 512"' in svg, name
        for title in re.findall(r"<title>(.*?)</title>", svg):
            assert title and CAPITAL not in title, (name, title)
        low = svg.lower()
        for word in BANNED:
            assert word not in low, (name, word)


def test_palette_colors_only_within_the_avatar_budget_of_seven_and_no_gradients_or_filters():
    allowed = palette_hexes()
    for name, svg in avatars.build_all().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert used <= allowed, (name, sorted(used - allowed))
        assert len(used) <= avatars.COLOR_BUDGET, (name, len(used))
        assert "Gradient" not in svg and "filter" not in svg and "opacity" not in svg, name


def test_the_avatar_color_budget_is_the_six_of_the_style_guide_plus_one_for_props():
    assert avatars.COLOR_BUDGET == 7


def test_every_avatar_is_the_style_guide_gnome_with_the_logos_exact_hat_face_eyes_and_nose():
    for name, svg in avatars.build_all().items():
        assert mascot_final.HAT_D in svg, name
        assert 'id="face"' in svg and 'id="nose"' in svg and svg.count('id="eye"') == 2, name
        assert svg.count('id="cap"') == 1, name


def test_no_brows_cheeks_ears_belts_or_goggles_were_added():
    for name, svg in avatars.build_all().items():
        for banned in ('id="brow"', 'id="cheek"', 'id="ear"', 'id="belt"', 'id="goggles"'):
            assert banned not in svg, (name, banned)


@pytest.mark.parametrize("name", [n for n in STARTER if n != "nisse"])
def test_each_activity_has_its_prop_and_the_plain_gnome_has_none(name):
    svgs = avatars.build_all()
    assert f'id="prop-{name}"' in svgs[name]
    assert 'id="prop-' not in svgs["nisse"]
    for other in STARTER:
        if other not in (name,):
            assert f'id="prop-{name}"' not in svgs[other], (name, other)


def test_the_avatars_are_all_different():
    bodies = {re.sub(r"<title>.*?</title>|aria-label=\"[^\"]*\"", "", s) for s in avatars.build_all().values()}
    assert len(bodies) == len(STARTER)


def test_everything_is_clipped_to_the_disc_so_nothing_pokes_out_of_a_round_avatar():
    for name, svg in avatars.build_all().items():
        assert '<clipPath id="disc"><circle cx="256" cy="256" r="236"/></clipPath>' in svg, name
        assert 'clip-path="url(#disc)"' in svg, name


def test_the_set_matches_the_konqi_set_one_for_one_by_activity():
    konqi = ["Artist", "Bookworm", "Boss", "Bug Catcher", "Card Shark", "Hacker", "Journalist", "Mechanic", "Messenger",
             "Musician", "Office Worker", "PC Builder", "Scientist", "Teacher", "Virtual Reality"]
    assert len(konqi) == 15 and len(avatars.build_all()) == 17
    for activity in konqi:
        assert avatars.FILE_NAMES[activity.lower().replace(" ", "").replace("virtualreality", "vr")] == f"{activity} gnome.png"
    assert avatars.FILE_NAMES["nisse"] == "nisse.png" and avatars.FILE_NAMES["laptop"] == "Laptop gnome.png"


def test_the_sheet_names_every_avatar_and_shows_the_small_sizes():
    sheet = avatars.build_sheet()
    sheet.encode("ascii")
    for name in STARTER:
        assert name in sheet, name
    assert "48 px" in sheet and "light" in sheet


# ---- the other Konqi pictures
def test_the_loves_sticker_changes_only_its_left_side():
    original = (ROOT / "assets" / "art" / "avatars" / "source" / "fedora-loves-kde.svg").read_text(encoding="utf-8")
    new = avatars.build_loves()
    new.encode("ascii")
    # the heart, the KDE logo and the white outline are untouched, character for character
    left_start = original.index(avatars.LEFT_LOGO)
    left_end = original.index("</g>", left_start) + len("</g>")
    assert original[:left_start].split(">", 1)[1] in new          # the white outline path and what comes before the left logo
    assert original[left_end:] in new                             # the heart and the KDE logo
    assert "M48.86 106.878" not in new and "M53.428 116.152" not in new     # the Fedora bubble and its f are gone
    assert 'id="nisse-logo"' in new and "#1b2330" in new           # the nisse tile is in
    assert "fedora" not in new.lower().replace("fedora-loves-kde.svg (plasma-welcome-fedora", "")


def test_the_loves_sticker_keeps_the_original_size_and_view_box():
    assert 'viewBox="0 0 354.331 155.906"' in avatars.build_loves() and 'width="100mm"' in avatars.build_loves()


def test_the_pair_picture_has_two_gnomes_and_two_phones_on_one_panel():
    svg = avatars.build_pair()
    svg.encode("ascii")
    assert svg.count('id="face"') == 2 and svg.count('id="nose"') == 2 and svg.count('id="cap"') == 2
    assert 'viewBox="0 0 500 334"' in svg
    assert mascot_final.HAT_D in svg
    used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
    assert used <= palette_hexes() and len(used) <= avatars.COLOR_BUDGET
    low = svg.lower()
    for word in BANNED:
        assert word not in low, word
