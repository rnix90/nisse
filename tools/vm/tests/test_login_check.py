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


# ---- N-504: the lock screen (the same judge as the login screen) and nisse's logout screen

def test_the_nisse_lock_screen_passes_idle_and_awake():
    assert lc.check_login(shot("n504-lock-nisse-idle.png"), awake=False).ok
    r = lc.check_login(shot("n504-lock-nisse-awake.png"), awake=True)
    assert r.ok, r.problems


def test_fedoras_cityscape_on_the_lock_screen_is_refused():
    r = lc.check_login(shot("n504-lock-before-fedora.png"), awake=False)
    assert not r.ok and any("blue" in p for p in r.problems), r.problems


def test_nisses_logout_screens_pass_in_all_three_forms():
    assert lc.check_logout(shot("n504-logout-nisse-all.png"), all_options=True).ok
    assert lc.check_logout(shot("n504-logout-nisse-shutdown.png"), all_options=False).ok
    assert lc.check_logout(shot("n504-logout-nisse-logout.png"), all_options=False).ok


def test_breezes_black_logout_screen_is_refused():
    for name in ("n504-logout-before-breeze-shutdown.png", "n504-logout-before-breeze-logout.png"):
        r = lc.check_logout(shot(name), all_options=False)
        assert not r.ok, name
        assert any("black" in p for p in r.problems), r.problems


def test_a_logout_screen_without_the_question_or_the_default_circle_is_refused():
    img = shot("n504-logout-nisse-all.png")
    ImageDraw.Draw(img).rectangle((380, 215, 900, 280), fill=(0x1a, 0x22, 0x2e))
    r = lc.check_logout(img, all_options=True)
    assert not r.ok and any("question" in p for p in r.problems), r.problems
    img = shot("n504-logout-nisse-all.png")
    ImageDraw.Draw(img).ellipse((640, 300, 780, 440), fill=(0x2a, 0x35, 0x48))
    r = lc.check_logout(img, all_options=True)
    assert not r.ok and any("circle" in p for p in r.problems), r.problems


def test_a_logout_screen_without_cancel_is_refused():
    img = shot("n504-logout-nisse-all.png")
    ImageDraw.Draw(img).rectangle((560, 525, 720, 575), fill=(0x1a, 0x22, 0x2e))
    r = lc.check_logout(img, all_options=True)
    assert not r.ok and any("Cancel" in p for p in r.problems), r.problems


def test_the_command_line_judges_the_logout_screens():
    assert lc.main(["--logout-all", str(SHOTS / "n504-logout-nisse-all.png")]) == 0
    assert lc.main(["--logout", str(SHOTS / "n504-logout-before-breeze-shutdown.png")]) == 1
