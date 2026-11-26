# SPDX-License-Identifier: GPL-2.0-or-later
"""N-501: the checker that judges a photo of the boot screen against the approved mock (assets/art/boot/plymouth-boot.png). The
mock stands in for a good photo here; damaged copies of it must be refused, so the checker is known to be able to say no."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import plymouth_check as pc  # noqa: E402

ROOT = HERE.parents[2]
MOCK = ROOT / "assets" / "art" / "boot" / "plymouth-boot.png"
INK = (0x1b, 0x23, 0x30)
EMBER = (0xe0, 0x62, 0x3f)


def good():
    return Image.open(MOCK).convert("RGB")


def test_the_approved_mock_passes_its_own_check():
    r = pc.check_boot_screen(good())
    assert r.ok, r.problems


def test_a_screen_without_the_logo_is_refused():
    img = good()
    ImageDraw.Draw(img).rectangle(pc.LOGO_BOX, fill=INK)
    r = pc.check_boot_screen(img)
    assert not r.ok and any("logo" in p or "differs" in p for p in r.problems), r.problems


def test_a_wrong_background_is_refused():
    img = Image.new("RGB", (1920, 1080), (0, 0, 0))
    r = pc.check_boot_screen(img)
    assert not r.ok


def test_a_screen_of_the_wrong_size_is_refused_with_its_size_in_the_message():
    r = pc.check_boot_screen(Image.new("RGB", (1280, 800), INK))
    assert not r.ok and any("1280x800" in p for p in r.problems), r.problems


def test_more_than_three_blocks_are_refused_and_fewer_are_fine():
    img = good()
    d = ImageDraw.Draw(img)
    x0, y0, y1 = 760, pc.BAR_INNER[1], pc.BAR_INNER[3] - 1
    for i in range(5):
        d.rectangle((x0 + i * 41, y0, x0 + i * 41 + 33, y1), fill=EMBER)
    assert not pc.check_boot_screen(img).ok
    empty = good()
    ImageDraw.Draw(empty).rectangle(pc.BAR_INNER, fill=(0x22, 0x2c, 0x3b))
    assert pc.count_blocks(empty) == 0 and pc.check_boot_screen(empty).ok


def test_the_blocks_must_move_between_photos():
    a, b = good(), good()
    assert pc.blocks_moved([a, b]) is False
    shifted = good()
    d = ImageDraw.Draw(shifted)
    d.rectangle(pc.BAR_INNER, fill=(0x22, 0x2c, 0x3b))
    d.rectangle((1000, pc.BAR_INNER[1], 1033, pc.BAR_INNER[3] - 1), fill=EMBER)
    assert pc.blocks_moved([a, shifted]) is True


def password_screen(prompt=True, bullets=3, field=True):
    img = Image.new("RGB", (1920, 1080), INK)
    d = ImageDraw.Draw(img)
    img.paste(Image.open(MOCK).convert("RGB").crop(pc.LOGO_BOX), pc.LOGO_BOX[:2])
    if field:
        d.rounded_rectangle((749, 740, 1171, 780), radius=20, fill=(0x22, 0x2c, 0x3b), outline=(0x7a, 0x86, 0x99), width=2)
    if prompt:
        d.rectangle((830, 690, 1090, 712), fill=(0xf6, 0xf2, 0xe9))
    for i in range(bullets):
        cx = 960 + (i - (bullets - 1) / 2) * 26
        d.ellipse((cx - 7, 753, cx + 7, 767), fill=EMBER)
    return img


def test_a_password_screen_shows_the_prompt_the_field_and_one_dot_per_character():
    r = pc.check_password_screen(password_screen(bullets=4), typed=4)
    assert r.ok, r.problems


def test_a_password_screen_with_no_prompt_or_no_field_or_wrong_dots_is_refused():
    assert not pc.check_password_screen(password_screen(prompt=False), typed=3).ok
    assert not pc.check_password_screen(password_screen(field=False), typed=3).ok
    assert not pc.check_password_screen(password_screen(bullets=2), typed=3).ok
