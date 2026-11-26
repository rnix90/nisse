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


def good(kind="installed", size=(1920, 1080)):
    name = "grub-menu-live" if kind == "live" else "grub-menu"
    if size != (1920, 1080):
        name = f"grub-menu-{size[0]}x{size[1]}"
    return Image.open(BOOT / f"{name}.png").convert("RGB")


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
    r = gc.check_menu(Image.new("RGB", (800, 600), INK), rows=3)
    assert not r.ok and any("800x600" in p for p in r.problems), r.problems


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


# ---- N-502c: the words of every row are centered

def test_the_mock_rows_are_centered_for_the_checker():
    img = good("installed")
    for i in range(4):
        c = gc.text_center(img, i)
        assert c is not None and abs(c - 960) <= 3, (i, c)


def test_a_row_whose_words_sit_to_the_left_is_refused():
    img = good("live")
    box = gc.row_box(1)
    strip = img.crop((box[0] + 20, box[1] + 10, box[2] - 20, box[3] - 10))
    ImageDraw.Draw(img).rectangle((box[0] + 20, box[1] + 10, box[2] - 20, box[3] - 10), fill=INK)
    img.paste(strip, (box[0] + 20 - 160, box[1] + 10))
    r = gc.check_menu(img, rows=3)
    assert not r.ok and any("centered" in p for p in r.problems), r.problems


def test_a_row_with_the_words_a_few_pixels_off_is_still_accepted():
    img = good("live")
    box = gc.row_box(1)
    strip = img.crop((box[0] + 20, box[1] + 10, box[2] - 20, box[3] - 10))
    img.paste(strip, (box[0] + 20 - 10, box[1] + 10))
    assert gc.check_menu(img, rows=3).ok



# ---- N-502b: the menu at every supported screen size

def test_the_mock_of_every_supported_size_passes_the_check_at_that_size():
    for size in [(1366, 768), (1360, 768), (1280, 720), (1024, 768)]:
        img = good("installed", size)
        assert img.size == size
        r = gc.check_menu(img, rows=4)
        assert r.ok, (size, r.problems)


def test_the_parts_are_where_the_layout_puts_them_at_each_size():
    for size in [(1920, 1080), (1366, 768), (1360, 768), (1280, 720), (1024, 768)]:
        img = good("installed", size)
        c = gc.text_center(img, 2)
        assert c is not None and abs(c - size[0] / 2) <= 3, (size, c)
        assert abs(gc.bar_fraction(img, size) - 0.6) < 0.03, size


def test_a_menu_whose_bottom_is_cut_off_is_refused_at_a_small_size():
    # the old 1080p layout drawn on a 720-line screen: the hint and the countdown fall off the bottom
    img = good("installed", (1280, 720))
    from PIL import ImageDraw
    ImageDraw.Draw(img).rectangle((0, 560, 1280, 720), fill=INK)
    r = gc.check_menu(img, rows=4)
    assert not r.ok, r.problems
