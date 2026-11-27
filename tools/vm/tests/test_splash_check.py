# SPDX-License-Identifier: GPL-2.0-or-later
"""N-505: the checker that judges a screenshot of nisse's Plasma splash. The approved mocks (assets/art/boot/splash-*.png) stand in for good
pictures; damaged copies must be refused, so the checker is known to be able to say no."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import splash_check as sc  # noqa: E402

BOOT = HERE.parents[2] / "assets" / "art" / "boot"
SHOTS = HERE.parents[2] / "docs" / "screenshots"


def mock(look):
    return Image.open(BOOT / f"splash-{look}.png").convert("RGB")


def test_the_approved_mocks_pass_their_own_check():
    for look in ("dark", "light"):
        r = sc.check_splash(mock(look), look)
        assert r.ok, (look, r.problems)


def test_the_dark_mock_is_refused_as_a_light_splash_and_the_other_way_round():
    assert not sc.check_splash(mock("dark"), "light").ok
    assert not sc.check_splash(mock("light"), "dark").ok


def test_text_or_a_logo_outside_the_middle_is_refused():
    img = mock("dark")
    ImageDraw.Draw(img).rectangle((1500, 950, 1860, 1040), fill=sc.PAPER)      # "Plasma made by KDE" in the corner
    r = sc.check_splash(img, "dark")
    assert not r.ok and any("no text" in p for p in r.problems), r.problems


def test_a_splash_without_the_ring_or_without_the_n_is_refused():
    img = mock("dark")
    ImageDraw.Draw(img).ellipse((700, 300, 1220, 780), outline=sc.INK, width=60)       # paint the ring out
    r = sc.check_splash(img, "dark")
    assert not r.ok and any("ring" in p for p in r.problems), r.problems
    img = mock("dark")
    ImageDraw.Draw(img).rectangle((880, 420, 1040, 660), fill=sc.INK)                  # paint the n out
    r = sc.check_splash(img, "dark")
    assert not r.ok and any("no n" in p for p in r.problems), r.problems


def test_an_n_that_is_not_centered_is_refused():
    img = Image.new("RGB", (1920, 1080), sc.INK)
    n = mock("dark").crop((860, 400, 1060, 680))
    img.paste(n, (1160, 400))
    r = sc.check_splash(img, "dark")
    assert not r.ok, r.problems


def test_the_command_line_exits_1_on_a_bad_picture_and_0_on_a_good_one():
    assert sc.main(["--dark", str(BOOT / "splash-dark.png")]) == 0
    assert sc.main(["--light", str(BOOT / "splash-dark.png")]) == 1
    assert sc.main([]) == 64


# ---- the real photos of N-505 (the live VM with the real ksplashqml)

def test_the_real_photos_of_the_splash_pass():
    assert sc.check_splash(Image.open(SHOTS / "n505-splash-nisse-dark.png"), "dark").ok
    assert sc.check_splash(Image.open(SHOTS / "n505-splash-nisse-light.png"), "light").ok


def test_the_real_photos_are_refused_as_the_other_look():
    assert not sc.check_splash(Image.open(SHOTS / "n505-splash-nisse-dark.png"), "light").ok
    assert not sc.check_splash(Image.open(SHOTS / "n505-splash-nisse-light.png"), "dark").ok


def test_the_desktop_with_no_splash_is_refused():
    r = sc.check_splash(Image.open(SHOTS / "n504-lock-before-fedora.png"), "dark")
    assert not r.ok, r.problems
