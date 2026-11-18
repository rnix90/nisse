# SPDX-License-Identifier: GPL-2.0-or-later
"""N-408: the nisse cursor theme: a W and an X in the nisse font as round badges, replacing Breeze's two logo cursors."""
import configparser
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import cursors  # noqa: E402
import xcursor  # noqa: E402

ROOT = HERE.parents[2]
THEME = ROOT / "assets" / "art" / "cursors" / "nisse_cursors"
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
EMBER, INK = (0xe0, 0x62, 0x3f), (0x1b, 0x23, 0x30)


def test_the_theme_replaces_exactly_the_two_breeze_logo_cursors_and_inherits_the_rest():
    names = sorted(p.name for p in (THEME / "cursors").iterdir())
    assert names == ["wayland-cursor", "x-cursor"]
    cp = configparser.ConfigParser(interpolation=None)
    cp.read(THEME / "index.theme", encoding="ascii")
    assert cp["Icon Theme"]["Inherits"] == "breeze_cursors"
    assert cp["Icon Theme"]["Name"] == "nisse cursors"
    assert CAPITAL not in (THEME / "index.theme").read_text(encoding="ascii")


def test_the_frames_cover_the_same_eleven_sizes_breeze_ships_with_the_hotspot_at_the_centre():
    for name in ("wayland-cursor", "x-cursor"):
        frames = xcursor.decode((THEME / "cursors" / name).read_bytes())
        assert [f.nominal for f in frames] == [12, 18, 24, 30, 36, 42, 48, 54, 60, 66, 72]
        for f in frames:
            w, h = f.image.size
            assert w == h and w == round(f.nominal * 4 / 3)          # 12 -> 16 px ... 72 -> 96 px, as Breeze
            assert abs(f.xhot - w / 2) <= 1 and abs(f.yhot - h / 2) <= 1


def test_each_cursor_is_a_round_ember_badge_with_an_ink_letter_and_a_paper_outline():
    for name in ("wayland-cursor", "x-cursor"):
        big = xcursor.decode((THEME / "cursors" / name).read_bytes())[-1].image          # the 96 px frame
        assert big.getpixel((0, 0))[3] == 0 and big.getpixel((95, 95))[3] == 0            # transparent corners: round, not square
        px = list(big.getdata())
        near = lambda c, t: all(abs(a - b) <= 12 for a, b in zip(c[:3], t))              # noqa: E731
        ember = sum(1 for p in px if p[3] == 255 and near(p, EMBER))
        ink = sum(1 for p in px if p[3] == 255 and near(p, INK))
        paper = sum(1 for p in px if p[3] == 255 and near(p, (0xf6, 0xf2, 0xe9)))
        assert ember > 1800 and ink > 250 and paper > 250, (name, ember, ink, paper)     # a disc, a letter, an outline ring


def test_the_w_and_the_x_are_different_pictures_and_the_hot_spot_is_inside_the_disc():
    w = xcursor.decode((THEME / "cursors" / "wayland-cursor").read_bytes())[-1]
    x = xcursor.decode((THEME / "cursors" / "x-cursor").read_bytes())[-1]
    assert w.image.tobytes() != x.image.tobytes()
    for f in (w, x):
        assert f.image.getpixel((f.xhot, f.yhot))[3] == 255


def test_the_generator_names_its_letters_and_the_sheet_shows_both():
    assert set(cursors.LETTERS) == {"wayland-cursor": "W", "x-cursor": "X"}.keys()
    assert cursors.LETTERS["wayland-cursor"] == "W" and cursors.LETTERS["x-cursor"] == "X"
    assert (ROOT / "assets" / "art" / "cursors" / "sheet.png").is_file()


def test_every_text_file_is_ascii():
    for p in (THEME / "index.theme", Path(cursors.__file__), Path(xcursor.__file__)):
        p.read_text(encoding="utf-8").encode("ascii")
    assert re.search(r"SPDX-License-Identifier: GPL-2.0-or-later", Path(cursors.__file__).read_text(encoding="ascii"))
