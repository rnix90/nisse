# SPDX-License-Identifier: GPL-2.0-or-later
"""N-407a: the committed Plasma wallpaper folder that the nisse-wallpaper package installs."""
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import wallpaper  # noqa: E402

ROOT = HERE.parents[2]
PKG = ROOT / "assets" / "art" / "wallpaper" / "package" / "nisse"


def test_every_file_plasma_needs_is_there():
    for rel in wallpaper.package_files():
        assert (PKG / rel).is_file(), f"{rel} missing: run python tools/art/wallpaper.py --all --out assets/art/wallpaper/package/nisse"


def test_every_picture_is_exactly_the_size_in_its_name_and_the_dark_folder_differs_from_the_light_one():
    for folder in ("images", "images_dark"):
        for w, h in wallpaper.SIZES:
            img = Image.open(PKG / "contents" / folder / f"{w}x{h}.png")
            assert img.size == (w, h), (folder, w, h, img.size)
    light = Image.open(PKG / "contents" / "images" / "1920x1080.png").convert("RGB").getpixel((10, 10))
    dark = Image.open(PKG / "contents" / "images_dark" / "1920x1080.png").convert("RGB").getpixel((10, 10))
    assert light != dark
    assert dark == (0x1b, 0x23, 0x30)            # Ink, the dark sky
    assert light == (0xff, 0xfd, 0xf8)           # page, the light sky


def test_the_sun_is_the_only_orange_in_the_dark_and_light_pictures():
    for folder in ("images", "images_dark"):
        img = Image.open(PKG / "contents" / folder / "1920x1080.png").convert("RGB")
        orange = sum(1 for p in img.resize((480, 270)).getdata() if abs(p[0] - 0xe0) < 6 and abs(p[1] - 0x62) < 6 and abs(p[2] - 0x3f) < 6)
        assert 200 < orange < 4000, orange       # a round sun, not a line or a field


def test_the_metadata_is_the_generators_and_the_folder_is_small():
    assert (PKG / "metadata.json").read_text(encoding="ascii") == wallpaper.metadata()
    total = sum(p.stat().st_size for p in PKG.rglob("*") if p.is_file())
    assert total < 3 * 1024 * 1024, total
