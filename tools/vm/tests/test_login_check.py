# SPDX-License-Identifier: GPL-2.0-or-later
"""N-503: the checker that judges a screenshot of the login screen (Plasma Login Manager's greeter in the VM). The real screenshots of the
screen before and after the nisse wallpaper stand in as the good and the bad pictures, and damaged copies must be refused, so the
checker is known to be able to say no."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import login_check as lc  # noqa: E402

SHOTS = HERE.parents[2] / "docs" / "screenshots"


def shot(name):
    return Image.open(SHOTS / name).convert("RGB")


def test_the_nisse_login_screen_passes_idle_and_awake():
    assert lc.check_login(shot("n503-login-nisse-idle.png"), awake=False).ok
    r = lc.check_login(shot("n503-login-nisse-awake.png"), awake=True)
    assert r.ok, r.problems


def test_fedoras_own_cityscape_is_refused_idle_and_awake():
    r = lc.check_login(shot("n503-login-before-fedora-idle.png"), awake=False)
    assert not r.ok and any("blue" in p for p in r.problems), r.problems
    r = lc.check_login(shot("n503-login-before-fedora-awake.png"), awake=True)
    assert not r.ok and any("blue" in p for p in r.problems), r.problems


def test_an_idle_screen_without_the_sun_is_refused():
    img = shot("n503-login-nisse-idle.png")
    ImageDraw.Draw(img).rectangle((300, 380, 560, 480), fill=(0x1e, 0x20, 0x24))
    r = lc.check_login(img, awake=False)
    assert not r.ok and any("sun" in p for p in r.problems), r.problems


def test_a_screen_without_the_clock_is_refused():
    img = shot("n503-login-nisse-idle.png")
    ImageDraw.Draw(img).rectangle((380, 40, 900, 270), fill=(0x1e, 0x20, 0x24))
    r = lc.check_login(img, awake=False)
    assert not r.ok and any("clock" in p for p in r.problems), r.problems


def test_a_bright_screen_is_refused():
    img = Image.new("RGB", (1280, 800), (200, 200, 200))
    r = lc.check_login(img, awake=False)
    assert not r.ok and any("dark" in p for p in r.problems), r.problems


def test_the_command_line_exits_1_on_a_bad_picture_and_0_on_a_good_one(capsys):
    assert lc.main(["--idle", str(SHOTS / "n503-login-nisse-idle.png")]) == 0
    assert lc.main(["--awake", str(SHOTS / "n503-login-before-fedora-awake.png")]) == 1
    assert lc.main([]) == 64
