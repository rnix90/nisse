# SPDX-License-Identifier: GPL-2.0-or-later
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import build_konsole  # noqa: E402
import contrast  # noqa: E402

PAL = contrast.load()
REPO = HERE.parents[2]
OUT = REPO / "assets" / "theme" / "konsole"
TERM = {k: v["hex"] for k, v in PAL["terminal"].items()}
DARK = {k: v["hex"] for k, v in PAL["dark"].items()}
NAMES = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]


def test_every_terminal_color_but_black_is_readable_on_the_terminal_background():
    for name, hexv in TERM.items():
        if name in ("bg", "black"):
            continue
        assert contrast.ratio(hexv, TERM["bg"]) >= 4.5, (name, hexv, contrast.ratio(hexv, TERM["bg"]))


def test_black_stays_a_dark_surface_color_not_text():
    assert contrast.ratio(TERM["black"], TERM["bg"]) < 2.0


def test_each_bright_color_is_lighter_than_its_normal_color_except_the_ember_red():
    # Bert approved bright red = Ember orange over normal red = the pink alert red; the orange is a little darker in
    # luminance but a different hue, so that one pair is exempt on purpose.
    for n in NAMES:
        if n == "red":
            continue
        assert contrast.luminance(TERM["bright-" + n]) > contrast.luminance(TERM[n]), n
    assert contrast.ratio(TERM["bright-red"], TERM["red"]) < 1.3 and TERM["bright-red"] != TERM["red"]


def test_the_ansi_colors_are_distinct_from_each_other():
    seen = {}
    for n in NAMES + ["bright-" + x for x in NAMES]:
        assert TERM[n] not in seen, (n, seen.get(TERM[n]))
        seen[TERM[n]] = n


def test_terminal_colors_that_exist_in_the_desktop_palette_are_the_same_colors():
    want = {"bg": "base", "fg": "text", "black": "surface-2", "red": "alert-text", "green": "ok-text", "yellow": "warn",
            "blue": "info", "magenta": "visited", "white": "text-muted", "bright-red": "accent-text",
            "bright-white": "text"}
    for term, dark in want.items():
        assert TERM[term] == DARK[dark], (term, dark)


def test_the_declared_terminal_pairs_are_in_the_palette_and_met():
    pairs = [p for p in PAL["pairs"] if p["fg"].startswith("terminal.") or p["bg"].startswith("terminal.")]
    assert len(pairs) >= 15
    assert contrast.check(PAL) == []


def test_the_scheme_defines_every_section_konsole_reads():
    s = build_konsole.build(PAL)
    for sec in ["Background", "BackgroundIntense", "Foreground", "ForegroundIntense", "General"]:
        assert sec in s, sec
    for i in range(8):
        assert f"Color{i}" in s and f"Color{i}Intense" in s, i
    assert s["General"]["Description"] == "nisse Ember"
    assert s["General"]["Opacity"] == "1"


def test_the_scheme_values_are_the_terminal_colors_as_rgb():
    s = build_konsole.build(PAL)
    def triple(h):
        return ",".join(str(c) for c in contrast.rgb(h))
    assert s["Background"]["Color"] == triple(TERM["bg"])
    assert s["Foreground"]["Color"] == triple(TERM["fg"])
    for i, n in enumerate(NAMES):
        assert s[f"Color{i}"]["Color"] == triple(TERM[n]), n
        assert s[f"Color{i}Intense"]["Color"] == triple(TERM["bright-" + n]), n


def test_the_checked_in_scheme_is_exactly_what_the_generator_writes():
    want = build_konsole.render(build_konsole.build(PAL))
    got = (OUT / "NisseEmber.colorscheme").read_text(encoding="ascii")
    assert got == want


def test_the_profile_uses_the_scheme_fira_code_and_the_ember_cursor():
    text = (OUT / "Nisse.profile").read_text(encoding="ascii")
    lines = text.splitlines()
    assert "ColorScheme=NisseEmber" in lines
    assert any(l.startswith("Font=Fira Code,10,") for l in lines)
    assert "Name=nisse" in lines
    assert "UseCustomCursorColor=true" in lines
    assert "CustomCursorColor=" + ",".join(str(c) for c in contrast.rgb(DARK["accent"])) in lines


def test_the_terminal_files_are_plain_ascii():
    for name in ("NisseEmber.colorscheme", "Nisse.profile"):
        assert all(b < 128 for b in (OUT / name).read_bytes()), name
