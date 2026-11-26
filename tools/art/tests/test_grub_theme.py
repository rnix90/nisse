# SPDX-License-Identifier: GPL-2.0-or-later
"""N-502: the committed GRUB theme folder that the nisse-grub-theme package installs. The pictures and theme.txt come from
tools/art/grub_theme.py (the same Ember pieces as the approved boot mock, N-412); the static Nunito fonts sit next to them and are
turned into GRUB's .pf2 format when the package is built. These tests keep the folder whole, palette-only and honest to the mock
(redrawn in N-502 for what GRUB can do: a countdown line and bar; rows centered by padded titles, N-502c).

Facts about GRUB the tests rely on, all verified in the N-502 spike (GRUB 2.12, BIOS and UEFI):
  * GRUB draws the first-listed component of theme.txt on top, so the countdown bar is listed before the picture of its track;
  * a progress bar is at least 28 px high, and its fill sits inside the border of its (invisible) frame pieces;
  * menu rows cannot be centered, and the selected row is drawn from nine pieces (a rounded Ember box);
  * the countdown text takes one number (%d), so the unit is the short "s", which reads right for one second as for ten."""
import json
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import grub_theme  # noqa: E402
import boot_mocks  # noqa: E402

ROOT = HERE.parents[2]
THEME = ROOT / "assets" / "art" / "grub" / "nisse"
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
CAPITAL = "N" + "isse"
NINE = ("nw", "n", "ne", "w", "c", "e", "sw", "s", "se")


def rgb(hexstr):
    h = hexstr.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def palette_rgbs():
    return {rgb(e["hex"]) for g in ("dark", "light") for e in PALETTE[g].values()}


def theme_text():
    return (THEME / "theme.txt").read_text(encoding="ascii")


def components(text):
    """[(kind, {property: value})] in file order, for the '+ kind { ... }' blocks of theme.txt."""
    out = []
    for m in re.finditer(r"^\+ (\w+) \{(.*?)^\}", text, re.S | re.M):
        props = {}
        for line in m.group(2).splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip().strip('"')
        out.append((m.group(1), props))
    return out


def test_the_theme_folder_is_whole_and_has_nothing_extra():
    have = sorted(p.name for p in THEME.iterdir())
    assert have == sorted(grub_theme.theme_files()), set(have) ^ set(grub_theme.theme_files())


def test_every_picture_theme_txt_names_exists_and_a_pattern_has_all_nine_pieces():
    text = theme_text()
    for name in re.findall(r'"([\w*.-]+\.png)"', text):
        if "*" in name:
            for piece in NINE:
                assert (THEME / name.replace("*", piece)).is_file(), name.replace("*", piece)
        else:
            assert (THEME / name).is_file(), name


def test_the_pictures_use_palette_colors_only():
    """Flat shapes in palette colors; only the smoothed edges (a blend of two palette colors) are in between. The most common solid
    colors of every picture are palette colors, and the track has both of its own: the surface fill and the outline edge."""
    allowed = palette_rgbs()
    for p in sorted(THEME.glob("*.png")):
        a = np.asarray(Image.open(p).convert("RGBA")).reshape(-1, 4)
        solid = a[a[:, 3] == 255][:, :3]
        if not len(solid):
            continue
        colors, counts = np.unique(solid, axis=0, return_counts=True)
        top = [tuple(int(x) for x in colors[i]) for i in np.argsort(-counts)[:2]]
        assert top[0] in allowed, f"{p.name}: its main color {top[0]} is not a palette color"
        if p.name != "bartrack.png":
            inside = sum(1 for px in map(tuple, solid.tolist()) if px in allowed)
            assert inside / len(solid) >= 0.9, f"{p.name}: only {inside} of {len(solid)} solid pixels are palette colors"
    track = np.asarray(Image.open(THEME / "bartrack.png").convert("RGBA"))
    assert tuple(int(x) for x in track[14, 280, :3]) == rgb(PALETTE["dark"]["surface"]["hex"])       # the middle of the track
    assert tuple(int(x) for x in track[0, 280, :3]) == rgb(PALETTE["dark"]["outline"]["hex"])        # its top edge


def test_the_screen_colors_are_the_palette_ones():
    text = theme_text()
    d = lambda n: PALETTE["dark"][n]["hex"].lower()  # noqa: E731
    assert f'desktop-color: "{d("base")}"' in text
    props = dict(components(text)[[k for k, _ in components(text)].index("boot_menu")][1])
    assert props["item_color"].lower() == d("text")
    assert props["selected_item_color"].lower() == d("on-accent")      # Ink on Ember, never Paper (3.1 to 1)
    labels = [p for k, p in components(text) if k == "label"]
    assert labels and all(p["color"].lower() == d("text-muted") for p in labels)


def test_the_selected_row_is_a_rounded_ember_box_of_nine_pieces():
    acc = rgb(PALETTE["dark"]["accent"]["hex"])
    for piece in NINE:
        a = np.asarray(Image.open(THEME / f"select_{piece}.png").convert("RGBA"))
        solid = a[a[:, :, 3] == 255][:, :3]
        assert all(tuple(int(x) for x in px) == acc for px in solid), piece
    nw = np.asarray(Image.open(THEME / "select_nw.png").convert("RGBA"))
    assert nw[0, 0, 3] == 0, "the outer corner of the row is rounded (transparent)"
    assert nw[nw.shape[0] - 1, nw.shape[1] - 1, 3] == 255
    assert np.asarray(Image.open(THEME / "select_c.png").convert("RGBA"))[0, 0, 3] == 255


def test_the_row_geometry_is_the_mocks():
    """The mock's row (box 732 x 68, pitch 84) is what theme.txt makes: item height plus the box's two borders is the row."""
    menu = [p for k, p in components(theme_text()) if k == "boot_menu"][0]
    border = Image.open(THEME / "select_nw.png").size[0]
    assert int(menu["item_height"]) + 2 * border == grub_theme.ROW_H == 68
    assert int(menu["item_height"]) + int(menu["item_spacing"]) == grub_theme.ROW_PITCH == 84
    assert int(menu["width"]) == grub_theme.ROW_W == 732
    assert menu["left"] == "50%-366" and int(menu["top"]) == grub_theme.ROWS_TOP
    assert menu["icon_width"] == "0" and menu["scrollbar"] == "false"


def test_the_bar_is_listed_before_its_track_and_is_tall_enough_for_grub():
    comps = components(theme_text())
    bars = [i for i, (k, p) in enumerate(comps) if k == "progress_bar"]
    tracks = [i for i, (k, p) in enumerate(comps) if k == "image" and p.get("file") == "bartrack.png"]
    assert len(bars) == 1 and len(tracks) == 1 and bars[0] < tracks[0], "GRUB draws the first-listed component on top"
    bar = comps[bars[0]][1]
    assert bar["id"] == "__timeout__"
    assert int(bar["height"]) >= 28, "GRUB makes a progress bar at least 28 px high whatever the theme says"
    assert (int(bar["width"]), int(bar["height"])) == Image.open(THEME / "bartrack.png").size == (grub_theme.BAR_W, grub_theme.BAR_H)
    assert bar["left"] == comps[tracks[0]][1]["left"] and bar["top"] == comps[tracks[0]][1]["top"]


def test_the_frame_pieces_of_the_bar_are_invisible_and_keep_the_fill_inside_the_track():
    sizes = {p: Image.open(THEME / f"bar_{p}.png").size for p in NINE}
    assert sizes["nw"] == (grub_theme.BAR_PAD, grub_theme.BAR_PAD) and sizes["se"] == (grub_theme.BAR_PAD, grub_theme.BAR_PAD)
    for p in NINE:
        assert np.asarray(Image.open(THEME / f"bar_{p}.png").convert("RGBA"))[:, :, 3].max() == 0, p
    hl = Image.open(THEME / "barhl_nw.png").size
    inner = grub_theme.BAR_H - 2 * grub_theme.BAR_PAD
    assert inner >= 12 and hl[0] <= 4


def test_the_countdown_line_is_a_closed_sentence_with_one_number_and_a_short_unit():
    comps = components(theme_text())
    label = [p for k, p in comps if k == "label" and p.get("id") == "__timeout__"][0]
    assert label["text"] == "nisse starts in %d s."
    assert label["text"].count("%d") == 1 and label["text"].rstrip()[-1] in ".!?:"
    assert label["align"] == "center"


def test_the_hint_line_is_the_closed_sentence_of_the_mock():
    labels = [p for k, p in components(theme_text()) if k == "label" and "id" not in p]
    assert [p["text"] for p in labels] == ["Press E to change how nisse starts."]


def test_nothing_on_screen_names_a_kernel_or_an_option():
    text = theme_text()
    assert not re.search(r"vmlinuz|rootflags|subvol|\.fc4|--id|root=", text)


def test_the_logo_is_the_stacked_logo_230_wide_above_the_menu():
    logo = Image.open(THEME / "logo.png")
    assert logo.size[0] == 230 and abs(logo.size[1] / 230 - 680 / 640) < 0.03
    comp = [p for k, p in components(theme_text()) if k == "image" and p.get("file") == "logo.png"][0]
    assert comp["left"] == "50%-115" and int(comp["top"]) == 90


def test_the_fonts_are_static_nunito_regular_and_bold_and_theme_txt_asks_only_for_them():
    from fontTools.ttLib import TTFont
    for name, weight in (("Nunito-Regular.ttf", 400), ("Nunito-SemiBold.ttf", 600)):
        f = TTFont(str(THEME / name))
        assert "fvar" not in f, f"{name} must be a static instance (GRUB cannot pick a weight)"
        assert f["OS/2"].usWeightClass == weight
        assert f["name"].getDebugName(1).startswith("Nunito")
    asked = set(re.findall(r'(?:font|item_font|selected_item_font|terminal-font)\s*[:=]\s*"([^"]+)"', theme_text()))
    # the editor and the command line (E, C) draw in GRUB's own terminal font, Unifont, which has the box-drawing characters
    assert asked == set(grub_theme.font_names()) | {grub_theme.TERMINAL_FONT}, asked
    for n in asked - {grub_theme.TERMINAL_FONT}:
        assert re.fullmatch(r"Nunito (Regular|SemiBold Regular) \d+", n), n


def test_the_mock_is_what_the_theme_draws():
    """The GRUB mock is redrawn for GRUB's left-aligned rows: the same geometry as theme.txt, the same words."""
    svg = boot_mocks.grub_menu_svg("installed")
    for words in ("nisse", "Start from Earlier Snapshots", "Computer Settings", "More Ways to Start", "nisse starts in 4 s.",
                  "Press E to change how nisse starts."):
        assert f">{words}<" in svg, words
    live = boot_mocks.grub_menu_svg("live")
    assert ">Start from Earlier Snapshots<" not in live and ">More Ways to Start<" in live and ">Computer Settings<" in live
    assert f'width="{grub_theme.ROW_W}" height="{grub_theme.ROW_H}"' in svg
    # the rows are centered (N-502c): the words sit in the middle of the screen
    assert 'text-anchor="start"' not in svg


def test_the_texts_follow_the_naming_and_wording_rules():
    texts = ["nisse", "Start from Earlier Snapshots", "Computer Settings", "More Ways to Start",
             "Check This Media and Start nisse", "Start nisse in Basic Graphics Mode"]
    for t in texts:
        assert CAPITAL not in t and t.isascii()
        assert grub_theme.is_headline(t), t        # short strings are headline case (N-501c)
    assert grub_theme.COUNTDOWN.endswith(".") and grub_theme.HINT.endswith(".")   # sentences end with punctuation (N-501b)


def test_the_files_are_ascii_and_the_generator_makes_the_committed_folder(tmp_path):
    for p in THEME.glob("*.txt"):
        assert p.read_text(encoding="ascii")
    grub_theme.render_all(tmp_path)
    assert sorted(p.name for p in tmp_path.iterdir()) == sorted(grub_theme.theme_files())
    assert (tmp_path / "theme.txt").read_text(encoding="ascii") == theme_text()
    for p in tmp_path.glob("*.png"):
        assert p.read_bytes() == (THEME / p.name).read_bytes(), f"{p.name} differs from the committed copy: rerun tools/art/grub_theme.py"


# ---- N-502c: the rows are centered by padding their titles (GRUB's menu has no alignment property)

FIXED_TITLES = ["nisse", "Computer Settings", "More Ways to Start", "Start from Earlier Snapshots", "Go Back to the Last Good Version",
                "Check This Media and Start nisse", "Start nisse in Basic Graphics Mode", "Start nisse with a Serial Console"]


def test_the_font_width_model_matches_what_freetype_draws():
    """The padding is worked out from the font's advance widths; check them against PIL/FreeType drawing the same text (the ink is
    narrower than the advance by the side bearings, a few px at most)."""
    from PIL import ImageFont
    for weight, name in (("Regular", "Nunito-Regular.ttf"), ("SemiBold", "Nunito-SemiBold.ttf")):
        font = ImageFont.truetype(str(THEME / name), 32)
        for title in FIXED_TITLES:
            left, _t, right, _b = font.getbbox(title)
            ink = right - left
            adv = grub_theme.advance(title, weight)
            assert -8 <= adv - ink <= 14, (weight, title, adv, ink)


def test_every_fixed_title_is_centered_within_a_space_or_so_in_both_weights():
    for title in FIXED_TITLES:
        for weight in ("Regular", "SemiBold"):
            assert abs(grub_theme.center_error(title, weight)) <= 12, (title, weight, grub_theme.center_error(title, weight))


def test_padded_titles_are_ascii_spaces_then_the_words_and_fit_the_row():
    for title in FIXED_TITLES:
        p = grub_theme.padded(title)
        assert p.endswith(title) and p[: len(p) - len(title)] == " " * grub_theme.pad_count(title) and p.isascii()
        assert grub_theme.advance(p, "SemiBold") <= grub_theme.TEXT_W, title
    assert grub_theme.pad_count("nisse") > grub_theme.pad_count("Computer Settings") > grub_theme.pad_count("More Ways to Start") - 1


def test_the_live_menu_template_uses_the_padded_titles():
    text = (ROOT / "build/kiwi/nisse/grub-x86.cfg.iso-template").read_text(encoding="ascii")
    titles = re.findall(r'(?:menuentry|submenu) "([^"]*)"', text)
    assert titles
    for t in titles:
        assert t == grub_theme.padded(t.strip()), f"title not centered: {t!r} (expected {grub_theme.padded(t.strip())!r})"


def test_the_installed_menu_snippets_use_the_padded_titles():
    for rel, want in (("packaging/rpm/nisse-boot/30_nisse_firmware", "Computer Settings"), ("packaging/rpm/nisse-boot/35_nisse_more_ways", "More Ways to Start"),
                      ("packaging/rpm/nisse-boot/11_nisse_snapshots", "Start from Earlier Snapshots"),
                      ("packaging/rpm/nisse-boot/11_nisse_snapshots", "Go Back to the Last Good Version")):
        text = (ROOT / rel).read_text(encoding="ascii")
        assert f"'{grub_theme.padded(want)}'" in text, f"{rel}: {want} is not centered"


def test_the_main_kernel_row_is_padded_with_no_break_spaces_because_the_boot_loader_spec_strips_spaces():
    """GRUB's BootLoaderSpec parser drops every space or tab after the key, so the title of the main row (a BLS file) is padded with
    U+00A0, written as an escape so the script stays ASCII."""
    text = (ROOT / "packaging/rpm/nisse-boot/nisse-boot").read_text(encoding="ascii")
    m = re.search(r"^main_pad=(\d+)$", text, re.M)
    assert m and int(m.group(1)) == grub_theme.pad_count("nisse")
    assert chr(92) + "302" + chr(92) + "240" in text


def test_the_mock_rows_are_centered():
    svg = boot_mocks.grub_menu_svg("installed")
    assert 'text-anchor="start"' not in svg
    assert svg.count(f'x="{boot_mocks.W / 2}"') >= 4
