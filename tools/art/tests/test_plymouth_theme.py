# SPDX-License-Identifier: GPL-2.0-or-later
"""N-501: the committed Plymouth theme folder that the nisse-plymouth package installs. The pictures come from tools/art/
plymouth_theme.py (the same drawings as the approved boot mock, N-412); the script and the theme file are written by hand next to
them. These tests keep the folder whole, palette-only and honest to the mock: a slim track with three Ember blocks that slide
from left to right and start again, the stacked logo above it, nothing else."""
import json
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import plymouth_theme  # noqa: E402

ROOT = HERE.parents[2]
THEME = ROOT / "assets" / "art" / "plymouth" / "nisse"
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
INSTALL_DIR = "/usr/share/plymouth/themes/nisse"


def rgb(hexstr):
    h = hexstr.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def palette_rgbs():
    return {rgb(e["hex"]) for g in ("dark", "light") for e in PALETTE[g].values()}


def frame(i):
    return np.asarray(Image.open(THEME / f"bar-{i:02d}.png").convert("RGBA"))


def accent_mask(a):
    acc = rgb(PALETTE["dark"]["accent"]["hex"])
    close = (np.abs(a[:, :, :3].astype(int) - np.array(acc)).sum(axis=2) < 12) & (a[:, :, 3] == 255)
    return close


def test_every_file_the_theme_needs_is_there():
    for rel in plymouth_theme.theme_files():
        assert (THEME / rel).is_file(), f"{rel} missing: run python tools/art/plymouth_theme.py"


def test_nothing_else_is_in_the_folder():
    on_disk = sorted(p.name for p in THEME.iterdir())
    assert on_disk == sorted(plymouth_theme.theme_files()), "a file here that the theme does not list would ship unowned"


def test_the_theme_file_names_the_script_module_and_points_into_the_install_folder():
    text = (THEME / "nisse.plymouth").read_text(encoding="ascii")
    assert "[Plymouth Theme]" in text and "ModuleName=script" in text
    assert f"ImageDir={INSTALL_DIR}" in text
    assert f"ScriptFile={INSTALL_DIR}/nisse.script" in text
    assert re.search(r"^Name=nisse$", text, re.M), "the name is lowercase"


def test_every_bar_frame_has_the_same_size_and_there_are_as_many_as_the_script_expects():
    n = plymouth_theme.FRAMES
    sizes = {Image.open(THEME / f"bar-{i:02d}.png").size for i in range(n)}
    assert sizes == {plymouth_theme.BAR_SIZE}, sizes
    assert not (THEME / f"bar-{n:02d}.png").exists()
    assert f"bar_frames = {n};" in (THEME / "nisse.script").read_text(encoding="ascii")


def test_the_blocks_slide_from_left_to_right_and_the_loop_starts_and_ends_on_an_empty_track():
    n = plymouth_theme.FRAMES
    centers = []
    for i in range(n):
        ys, xs = np.nonzero(accent_mask(frame(i)))
        centers.append(None if len(xs) == 0 else float(xs.mean()))
    assert centers[0] is None and centers[-1] is None, "the loop must start and end with the blocks out of sight"
    seen = [c for c in centers if c is not None]
    assert len(seen) >= n // 2, "the blocks are on screen for most of the loop"
    assert all(b > a for a, b in zip(seen, seen[1:])), "the blocks only move right"
    first, last = centers.index(seen[0]), centers.index(seen[-1])
    assert all(c is not None for c in centers[first:last + 1]), "the blocks do not vanish and reappear mid-loop"


def test_three_blocks_are_in_a_frame_where_all_of_them_are_in_view():
    mid = frame(plymouth_theme.FRAMES // 2)
    cols = accent_mask(mid)[plymouth_theme.BAR_SIZE[1] // 2]
    runs = np.count_nonzero(np.diff(cols.astype(int)) == 1) + int(cols[0])
    assert runs == 3, runs


def test_the_pictures_use_palette_colors_only():
    allowed = palette_rgbs()
    for rel in plymouth_theme.theme_files():
        if not rel.endswith(".png"):
            continue
        a = np.asarray(Image.open(THEME / rel).convert("RGBA"))
        solid = a[a[:, :, 3] == 255][:, :3]
        uniq = np.unique(solid.reshape(-1, 3), axis=0)
        # antialiased edges blend two palette colors, so judge only the colors that cover a real area of the picture
        counts = {tuple(c): int(((solid == c).all(axis=1)).sum()) for c in uniq}
        big = [c for c, k in counts.items() if k >= max(40, solid.shape[0] // 400)]
        assert big, rel
        for c in big:
            assert c in allowed, (rel, c)


def test_the_logo_is_the_stacked_lockup_and_the_background_is_left_to_the_script():
    img = Image.open(THEME / "logo.png")
    assert img.mode == "RGBA"
    w, h = img.size
    assert abs(w / h - 640 / 680) < 0.01, (w, h)
    assert np.asarray(img)[0, 0, 3] == 0, "the corner is transparent: the screen color comes from the script"


def test_the_script_sets_the_ink_background_and_uses_every_picture():
    s = (THEME / "nisse.script").read_text(encoding="ascii")
    base = rgb(PALETTE["dark"]["base"]["hex"])
    want = ", ".join(f"{c / 255:.3f}" for c in base)
    assert f"Window.SetBackgroundTopColor({want});" in s
    assert f"Window.SetBackgroundBottomColor({want});" in s
    for rel in ("logo.png", "field.png", "bullet.png"):
        assert rel in s, f"{rel} is shipped but the script never loads it"
    assert 'Image("bar-" +' in s or 'Image("bar-"' in s


def test_the_script_covers_the_screens_a_boot_can_show():
    s = (THEME / "nisse.script").read_text(encoding="ascii")
    for hook in ("Plymouth.SetRefreshFunction", "Plymouth.SetDisplayPasswordFunction", "Plymouth.SetDisplayNormalFunction",
                 "Plymouth.SetMessageFunction", "Plymouth.SetQuitFunction"):
        assert hook in s, hook


def test_what_the_normal_screen_hides_the_password_screen_shows_again():
    """A boot photo showed the field but not the prompt: the normal screen had hidden the prompt and the password screen never showed
    it again. Every sprite show_normal makes invisible must be made visible by show_password (and the other way round)."""
    s = (THEME / "nisse.script").read_text(encoding="ascii")

    def body(name):
        start = s.index(f"fun {name}(")
        nxt = s.find("\nfun ", start + 1)
        nxt = len(s) if nxt < 0 else nxt
        end = s.find("\nPlymouth.", start)
        return s[start:min(x for x in (nxt, end if end >= 0 else len(s)) if x > start)]

    hidden = set(re.findall(r"(\w+_sprite)(?:\[i\])?\.SetOpacity\(0\)", body("show_normal")))
    shown = set(re.findall(r"(\w+_sprite)(?:\[i\])?\.SetOpacity\(1\)", body("show_password")))
    assert {"field_sprite", "prompt_sprite", "bullet_sprite"} <= hidden, hidden
    assert (hidden - {"bar_sprite"}) <= shown, f"the password screen never shows {(hidden - {'bar_sprite'}) - shown} again"
    assert "bar_sprite" in re.findall(r"(\w+_sprite)\.SetOpacity\(0\)", body("show_password")), "the password screen must hide the bar"
    assert "bar_sprite" in re.findall(r"(\w+_sprite)\.SetOpacity\(1\)", body("show_normal")), "the normal screen must show the bar again"


def test_the_theme_carries_a_static_regular_nunito():
    """Plymouth's text plugin loads one font file and cannot choose a weight, and Nunito's variable file starts at ExtraLight (200),
    so the theme carries a static Regular instance (N-501a)."""
    from fontTools.ttLib import TTFont
    assert "Nunito-Regular.ttf" in plymouth_theme.theme_files()
    f = TTFont(THEME / "Nunito-Regular.ttf")
    assert "fvar" not in f, "a variable font would show its ExtraLight default"
    assert f["OS/2"].usWeightClass == 400
    assert "Nunito" in {n.toUnicode() for n in f["name"].names if n.nameID == 1}


def test_every_text_the_script_draws_is_set_in_nunito():
    s = (THEME / "nisse.script").read_text(encoding="ascii")
    calls = re.findall(r"Image\.Text\(.*\);", s)
    assert len(calls) == 2, calls          # the message line and the password prompt
    assert 'word_font = "Nunito ' in s, "the font of the words must name Nunito"
    for c in calls:
        assert "word_font" in c, f"set in Plymouth's default font: {c}"


def test_the_message_and_the_prompt_are_closed_with_punctuation():
    """Bert (N-501a): a sentence we write ends with punctuation. A text that already ends with . ! ? or : is left alone; any other
    gets a full stop. The words come from whatever starts the message, so the theme does it, once, for both lines."""
    s = (THEME / "nisse.script").read_text(encoding="ascii")
    def function_body(name):
        start = s.index(f"fun {name}(")
        return s[start:s.index(chr(10) + "}", start)]

    body = function_body("close_sentence")
    for mark in ('"."', '"!"', '"?"', '":"'):
        assert mark in body, f"close_sentence does not know {mark}"
    for fn in ("show_message", "show_password"):
        assert "close_sentence(" in function_body(fn), f"{fn} does not close its sentence"


def test_the_script_never_shows_a_percentage():
    s = (THEME / "nisse.script").read_text(encoding="ascii")
    assert "SetBootProgressFunction" not in s, "the bar is not a measure: nothing here may pretend to know how far boot is"


def test_the_theme_text_is_ascii_and_the_name_is_lowercase():
    for p in THEME.iterdir():
        if p.suffix in (".script", ".plymouth"):
            data = p.read_bytes()
            assert all(b < 128 for b in data), p.name
            assert CAPITAL not in data.decode("ascii"), p.name
            assert data.startswith(b"# SPDX-License-Identifier: GPL-2.0-or-later") or data.startswith(b"[Plymouth Theme]"), p.name
