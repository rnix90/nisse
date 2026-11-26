# SPDX-License-Identifier: GPL-2.0-or-later
"""N-502: the checker that judges a photo of the GRUB menu (QEMU screendump, tools/vm/grub_boot.sh) against the approved mock
(assets/art/boot/grub-menu*.png). The mock stands in for a good photo here; damaged copies of it must be refused, so the checker is
known to be able to say no."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import grub_check as gc  # noqa: E402

ROOT = HERE.parents[2]
BOOT = ROOT / "assets" / "art" / "boot"
INK = (0x1b, 0x23, 0x30)
EMBER = (0xe0, 0x62, 0x3f)


def good(kind="installed"):
    return Image.open(BOOT / ("grub-menu.png" if kind == "installed" else "grub-menu-live.png")).convert("RGB")


def test_the_approved_mocks_pass_their_own_check():
    for kind, rows in (("installed", 4), ("live", 3)):
        r = gc.check_menu(good(kind), rows=rows)
        assert r.ok, (kind, r.problems)


def test_the_number_of_rows_is_checked():
    r = gc.check_menu(good("live"), rows=4)
    assert not r.ok and any("row" in p for p in r.problems), r.problems
    r = gc.check_menu(good("installed"), rows=3)
    assert not r.ok and any("row" in p for p in r.problems), r.problems


def test_a_wrong_background_is_refused():
    r = gc.check_menu(Image.new("RGB", (1920, 1080), (0, 0, 0)), rows=3)
    assert not r.ok


def test_a_photo_of_the_wrong_size_is_refused():
    r = gc.check_menu(Image.new("RGB", (1024, 768), INK), rows=3)
    assert not r.ok and any("1024x768" in p for p in r.problems), r.problems


def test_no_ember_row_is_refused():
    img = good("live")
    ImageDraw.Draw(img).rectangle(gc.row_box(0), fill=INK)
    r = gc.check_menu(img, rows=3)
    assert not r.ok and any("selected row" in p for p in r.problems), r.problems


def test_the_selected_row_in_the_wrong_place_is_refused():
    img = good("live")
    ImageDraw.Draw(img).rectangle(gc.row_box(0), fill=INK)
    box = gc.row_box(1)
    ImageDraw.Draw(img).rounded_rectangle(box, 14, fill=EMBER)
    r = gc.check_menu(img, rows=3)
    assert not r.ok and any("selected row" in p or "first row" in p for p in r.problems), r.problems


def test_a_second_ember_shape_is_refused():
    img = good("live")
    ImageDraw.Draw(img).rectangle((100, 600, 300, 640), fill=EMBER)
    r = gc.check_menu(img, rows=3)
    assert not r.ok and any("Ember" in p for p in r.problems), r.problems


def test_a_missing_logo_is_refused():
    img = good("live")
    ImageDraw.Draw(img).rectangle(gc.LOGO_BOX, fill=INK)
    r = gc.check_menu(img, rows=3)
    assert not r.ok and any("logo" in p for p in r.problems), r.problems


def test_a_missing_countdown_line_or_track_or_hint_is_refused():
    for box, word in ((gc.COUNTDOWN_BOX, "countdown"), (gc.TRACK_BOX, "track"), (gc.HINT_BOX, "hint")):
        img = good("live")
        ImageDraw.Draw(img).rectangle(box, fill=INK)
        r = gc.check_menu(img, rows=3)
        assert not r.ok and any(word in p for p in r.problems), (word, r.problems)


def test_an_unlabelled_row_is_refused():
    img = good("live")
    ImageDraw.Draw(img).rectangle(gc.row_box(2), fill=INK)
    r = gc.check_menu(img, rows=3)
    assert not r.ok and any("row 3" in p or "row" in p for p in r.problems), r.problems


def test_the_countdown_fill_is_measured():
    img = good("live")
    f = gc.bar_fraction(img)
    assert abs(f - 0.6) < 0.03, f          # the mock: 4 seconds left of 10, so 6 of 10 have gone (the bar fills as the time runs out)
    full = Image.new("RGB", img.size, INK)
    assert gc.bar_fraction(full) is None


def test_the_command_line_wants_a_photo_or_two():
    assert gc.main([]) == 64
