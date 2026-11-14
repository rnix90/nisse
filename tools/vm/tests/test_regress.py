# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the screenshot regression harness (ledger N-113) that need no VM: screens, checking, accepting."""
import sys
from pathlib import Path

import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import imgdiff  # noqa: E402
import regress  # noqa: E402

SIZE = (1280, 800)
INK = (27, 35, 48)
EMBER = (224, 98, 63)


def png(path, color=INK, size=SIZE, block=None):
    img = Image.new("RGB", size, color)
    if block:
        img.paste(Image.new("RGB", (block[2] - block[0], block[3] - block[1]), EMBER), block[:2])
    img.save(path)
    return path


def seed(directory, names=None, **kw):
    directory.mkdir(parents=True, exist_ok=True)
    for n in names or regress.names():
        size = (1280, 48) if n == "panel" else SIZE
        png(directory / f"{n}.png", size=size, **kw)


def test_the_five_approved_screens_exist_and_names_are_unique():
    assert regress.names() == ["desktop", "panel", "launcher", "settings", "terminal"]
    assert len(set(regress.names())) == 5


def test_the_panel_is_cut_from_the_desktop_shot_not_captured_alone():
    panel = regress.screen("panel")
    assert panel.crop_of == "desktop" and panel.crop is not None
    assert panel.launch is None and panel.action is None


def test_build_screens_cuts_the_panel_strip_off_the_bottom_of_the_desktop():
    desktop = Image.new("RGB", SIZE, INK)
    desktop.paste(Image.new("RGB", (SIZE[0], 50), EMBER), (0, SIZE[1] - 50))
    built = regress.build_screens({"desktop": desktop})
    assert set(built) == {"desktop", "panel"}
    assert built["panel"].size[0] == SIZE[0] and built["panel"].size[1] < 100
    assert built["panel"].getpixel((10, built["panel"].size[1] - 2)) == EMBER


def test_the_terminal_screen_prints_fixed_text_so_no_prompt_or_time_leaks_in():
    cmd = regress.screen("terminal").launch
    assert "konsole" in cmd and "date" not in cmd and "$PS1" not in cmd


def test_matching_screens_pass(tmp_path):
    seed(tmp_path / "actual")
    seed(tmp_path / "golden")
    rows = regress.evaluate(tmp_path / "actual", tmp_path / "golden")
    assert [r.name for r in rows] == regress.names()
    assert all(r.status == "pass" for r in rows)


def test_an_altered_screen_fails_and_writes_a_diff_image(tmp_path):
    seed(tmp_path / "actual")
    seed(tmp_path / "golden")
    png(tmp_path / "actual" / "launcher.png", block=(100, 100, 600, 500))
    rows = {r.name: r for r in regress.evaluate(tmp_path / "actual", tmp_path / "golden")}
    assert rows["launcher"].status == "fail" and rows["launcher"].result.fraction > 0.1
    assert rows["desktop"].status == "pass"
    diff = tmp_path / "actual" / "diff" / "launcher.png"
    assert diff.is_file() and Image.open(diff).size == SIZE


def test_a_change_inside_the_clock_mask_does_not_fail_the_desktop(tmp_path):
    seed(tmp_path / "actual")
    seed(tmp_path / "golden")
    box = imgdiff.box_from_fractions(regress.screen("desktop").masks[0], SIZE)
    png(tmp_path / "actual" / "desktop.png", block=box)
    rows = {r.name: r for r in regress.evaluate(tmp_path / "actual", tmp_path / "golden")}
    assert rows["desktop"].status == "pass"


def test_a_missing_golden_or_a_missing_capture_is_reported_not_passed(tmp_path):
    seed(tmp_path / "actual", names=["desktop", "panel"])
    seed(tmp_path / "golden", names=["desktop", "launcher"])
    rows = {r.name: r.status for r in regress.evaluate(tmp_path / "actual", tmp_path / "golden")}
    assert rows["desktop"] == "pass"
    assert rows["panel"] == "no-golden"
    assert rows["launcher"] == "no-capture"
    assert rows["settings"] == "no-capture" and rows["terminal"] == "no-capture"


def test_only_limits_which_screens_are_checked(tmp_path):
    seed(tmp_path / "actual")
    seed(tmp_path / "golden")
    rows = regress.evaluate(tmp_path / "actual", tmp_path / "golden", only=["panel", "desktop"])
    assert [r.name for r in rows] == ["desktop", "panel"]


def test_tolerance_and_threshold_are_passed_through(tmp_path):
    seed(tmp_path / "actual")
    seed(tmp_path / "golden")
    png(tmp_path / "actual" / "settings.png", block=(0, 0, 100, 100))  # 0.98 percent of the screen
    strict = {r.name: r.status for r in regress.evaluate(tmp_path / "actual", tmp_path / "golden")}
    loose = {r.name: r.status for r in regress.evaluate(tmp_path / "actual", tmp_path / "golden", tolerance=0.02)}
    assert strict["settings"] == "fail" and loose["settings"] == "pass"


def test_accept_copies_the_capture_over_the_golden(tmp_path):
    seed(tmp_path / "actual", color=EMBER)
    seed(tmp_path / "golden")
    regress.accept(tmp_path / "actual", tmp_path / "golden", ["terminal"])
    assert Image.open(tmp_path / "golden" / "terminal.png").getpixel((5, 5)) == EMBER
    assert Image.open(tmp_path / "golden" / "desktop.png").getpixel((5, 5)) == INK


def test_accept_creates_the_golden_folder_and_refuses_unknown_or_missing_screens(tmp_path):
    seed(tmp_path / "actual", names=["desktop"])
    regress.accept(tmp_path / "actual", tmp_path / "new" / "golden", ["desktop"])
    assert (tmp_path / "new" / "golden" / "desktop.png").is_file()
    with pytest.raises(ValueError):
        regress.accept(tmp_path / "actual", tmp_path / "golden", ["nonsense"])
    with pytest.raises(FileNotFoundError):
        regress.accept(tmp_path / "actual", tmp_path / "golden", ["panel"])


def test_check_exits_zero_on_a_match_and_one_on_a_changed_screen(tmp_path, capsys):
    seed(tmp_path / "actual")
    seed(tmp_path / "golden")
    argv = ["check", "--actual", str(tmp_path / "actual"), "--golden", str(tmp_path / "golden")]
    assert regress.main(argv) == 0
    png(tmp_path / "actual" / "settings.png", block=(0, 0, 640, 400))
    assert regress.main(argv) == 1
    out = capsys.readouterr().out
    assert "FAIL settings" in out and "PASS desktop" in out


def test_check_exits_one_when_anything_is_missing(tmp_path):
    seed(tmp_path / "actual", names=["desktop"])
    seed(tmp_path / "golden")
    assert regress.main(["check", "--actual", str(tmp_path / "actual"), "--golden", str(tmp_path / "golden")]) == 1


def test_the_accept_command_takes_screen_names_or_all(tmp_path):
    seed(tmp_path / "actual", color=EMBER)
    base = ["--actual", str(tmp_path / "actual"), "--golden", str(tmp_path / "golden")]
    assert regress.main(["accept", "desktop", *base]) == 0
    assert [p.name for p in (tmp_path / "golden").glob("*.png")] == ["desktop.png"]
    assert regress.main(["accept", "--all", *base]) == 0
    assert len(list((tmp_path / "golden").glob("*.png"))) == 5
    assert regress.main(["accept", "bogus", *base]) == 2
