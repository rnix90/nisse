# SPDX-License-Identifier: GPL-2.0-or-later
"""N-409a: the AI panel app's icon: the three-star sparkle from Bert's Claude Code launcher, flat and in the nisse colors."""
import re
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import assistant_icon  # noqa: E402

ROOT = HERE.parents[2]
CAPITAL = "N" + "isse"   # in two parts so the lowercase-name scan does not flag this test
HICOLOR = ROOT / "assets" / "art" / "assistant" / "hicolor"
ALLOWED = {"#1b2330", "#f6f2e9", "#e0623f"}


def colors(svg):
    return {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}


def test_the_full_icon_is_three_sparkles_on_the_ink_tile_and_the_small_one_is_one_fat_sparkle():
    full, small = assistant_icon.form(detailed=True), assistant_icon.form(detailed=False)
    for ident in ("sparkle-main", "sparkle-a", "sparkle-b"):
        assert f'id="{ident}"' in full, ident
    assert 'id="sparkle-main"' in small and 'id="sparkle-a"' not in small and 'id="sparkle-b"' not in small
    for svg in (full, small):
        svg.encode("ascii")
        assert 'id="tile"' in svg and 'viewBox="0 0 512 512"' in svg
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg
        assert colors(svg) <= ALLOWED, colors(svg)
        for banned in ("Gradient", "filter", "opacity", "<image", "<text", "stroke"):
            assert banned not in svg, banned
        assert CAPITAL not in svg


def test_the_sparkles_use_the_launchers_shapes_a_big_star_and_two_small_companions_in_its_places():
    # the launcher's make_icon.py: main at the centre, radius 0.47, power 5; companions at (0.795, 0.22) r 0.145 and (0.205, 0.785)
    # r 0.10, power 4.5; for 32 px and smaller one fatter star (power 3.2, radius 0.45) with no companions
    assert (assistant_icon.MAIN, assistant_icon.COMPANIONS) == (((0.5, 0.5), 0.47, 5.0), (((0.795, 0.22), 0.145, 4.5), ((0.205, 0.785), 0.10, 4.5)))
    assert assistant_icon.SMALL_MAIN == ((0.5, 0.5), 0.45, 3.2) and assistant_icon.SMALL_CUTOFF == 32
    pts = assistant_icon.astroid((256, 256), 100, 3.0, samples=8)
    assert len(pts) == 8 and abs(pts[0][0] - 356) < 0.01 and abs(pts[0][1] - 256) < 0.01      # t = 0 is the right-hand tip


def test_the_main_star_is_ember_and_the_companions_are_paper():
    svg = assistant_icon.form(detailed=True)
    main = re.search(r'<polygon id="sparkle-main"[^>]*fill="(#[0-9a-f]{6})"', svg).group(1)
    assert main == "#e0623f"
    for ident in ("sparkle-a", "sparkle-b"):
        assert re.search(rf'<polygon id="{ident}"[^>]*fill="#f6f2e9"', svg), ident


def test_the_hicolor_tree_has_every_size_and_the_scalable_svg():
    for px in (16, 22, 24, 32, 48, 64, 96, 128, 256, 512):
        img = Image.open(HICOLOR / f"{px}x{px}" / "apps" / "nisse-assistant.png")
        assert img.size == (px, px), px
        assert img.convert("RGBA").getpixel((0, 0))[3] < 100          # the tile's rounded corner is (almost) transparent
    assert 'id="sparkle-a"' in (HICOLOR / "scalable" / "apps" / "nisse-assistant.svg").read_text(encoding="ascii")


def test_the_small_sizes_use_the_single_fat_star_so_it_survives_at_taskbar_scale():
    # at 24 px the small variant puts an Ember pixel run through the centre row; the companions (Paper) are absent
    img = Image.open(HICOLOR / "24x24" / "apps" / "nisse-assistant.png").convert("RGB")
    paper = sum(1 for x in range(24) for y in range(24) if img.getpixel((x, y))[0] > 230 and img.getpixel((x, y))[2] > 220)
    ember = sum(1 for x in range(24) for y in range(24) if abs(img.getpixel((x, y))[0] - 0xe0) < 30 and abs(img.getpixel((x, y))[2] - 0x3f) < 40)
    assert ember >= 25 and paper < 6
    big = Image.open(HICOLOR / "256x256" / "apps" / "nisse-assistant.png").convert("RGB")
    paper_big = sum(1 for x in range(0, 256, 2) for y in range(0, 256, 2) if big.getpixel((x, y))[0] > 230 and big.getpixel((x, y))[2] > 220)
    assert paper_big > 40                                            # the two companions are there at the big sizes


def test_the_desktop_file_names_the_icon():
    assert "Icon=nisse-assistant" in (ROOT / "packaging" / "rpm" / "nisse-panel" / "nisse-panel.desktop").read_text(encoding="ascii").splitlines()
