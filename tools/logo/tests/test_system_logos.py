# SPDX-License-Identifier: GPL-2.0-or-later
"""N-405: the nisse logo stands in for every Fedora placeholder logo, and the logo build regenerates them."""
import filecmp
import sys
from pathlib import Path

import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "logo"))
sys.path.insert(0, str(ROOT / "tools" / "art"))
import build_system  # noqa: E402

SYSTEM = ROOT / "assets" / "logo" / "system"
TILE = ROOT / "assets" / "logo" / "svg" / "nisse-app-tile.svg"


@pytest.fixture(scope="module")
def regenerated(tmp_path_factory):
    out = tmp_path_factory.mktemp("system")
    build_system.build(out)
    return out


def files(root):
    return sorted(str(p.relative_to(root)).replace("\\", "/") for p in Path(root).rglob("*") if p.is_file())


def test_the_logo_build_regenerates_exactly_what_is_committed(regenerated):
    assert files(regenerated) == files(SYSTEM)
    for rel in files(SYSTEM):
        assert (regenerated / rel).read_bytes() == (SYSTEM / rel).read_bytes(), f"{rel} is stale: run tools/logo/build_system.py"


@pytest.mark.parametrize("rel", [
    "usr/share/icons/hicolor/scalable/apps/start-here.svg",
    "usr/share/icons/hicolor/scalable/apps/fedora-logo-sprite.svg",
    "usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg",
    "usr/share/pixmaps/fedora-logo-sprite.svg",
])
def test_the_start_button_and_the_sprite_are_the_nisse_tile_which_is_what_bert_chose(rel):
    # N-405, Bert 2026-11-16: keep the Ink tile for the start button and the sprite (not the bare circle)
    assert (SYSTEM / rel).read_bytes() == TILE.read_bytes()


@pytest.mark.parametrize("rel,size", [
    ("usr/share/pixmaps/fedora-logo.png", (240, 310)),
    ("usr/share/pixmaps/system-logo-white.png", (240, 310)),
    ("usr/share/pixmaps/fedora-logo-small.png", (128, 128)),
])
def test_the_fedora_named_logo_files_keep_their_size_and_are_the_nisse_logo(rel, size):
    img = Image.open(SYSTEM / rel)
    assert img.size == size
    # not the hot dog: the Fedora placeholders were mostly blue and white; nisse art is Ink and Paper only
    raw = img.convert("RGB").tobytes()
    px = [(raw[i], raw[i + 1], raw[i + 2]) for i in range(0, len(raw), 3)]
    bluish = sum(1 for r, g, b in px if b > r + 40 and b > g + 20 and b > 120)
    assert bluish < 0.01 * len(px)


def test_the_stacked_logo_card_and_the_white_logo_are_the_same_card():
    assert (SYSTEM / "usr/share/pixmaps/fedora-logo.png").read_bytes() == (SYSTEM / "usr/share/pixmaps/system-logo-white.png").read_bytes()


def test_the_distributor_logo_ids_are_kept():
    spec = (ROOT / "packaging/rpm/nisse-branding/nisse-branding.spec").read_text()
    assert "distributor-logo-nisse" in spec
    release = (ROOT / "packaging/rpm/nisse-release").rglob("*")
    text = "".join(p.read_text(errors="ignore") for p in release if p.is_file())
    assert "LOGO=distributor-logo-nisse" in text


def test_the_installer_icon_is_the_nisse_logo_on_a_disk_and_its_png_matches_the_placeholder_size():
    # N-409: anaconda is the logo on a disk (a drive with a status light), no longer the plain tile
    svg = (SYSTEM / "usr/share/icons/hicolor/scalable/apps/anaconda.svg").read_text(encoding="ascii")
    assert 'id="drive"' in svg and 'id="logo"' in svg and 'id="led"' in svg
    assert svg != TILE.read_text(encoding="ascii")
    for rel in ("usr/share/icons/hicolor/48x48/apps/anaconda.png", "usr/share/icons/oxygen/48x48/apps/anaconda.png"):
        img = Image.open(SYSTEM / rel)
        assert img.size == (49, 49), rel                       # the size of the Fedora placeholder it replaces
        assert img.convert("RGBA").getpixel((0, 0))[3] == 0     # the tile's rounded corner is transparent


def test_the_install_to_hard_drive_icon_that_the_live_desktop_launcher_names_exists_in_hicolor():
    # N-410: liveinst.desktop says Icon=org.fedoraproject.AnacondaInstaller, a file fedora-logos ships (and nisse-branding replaces),
    # so it was missing and the launcher showed a blank page. It is now the working pickaxe.
    import icons
    path = SYSTEM / "usr/share/icons/hicolor/scalable/apps/org.fedoraproject.AnacondaInstaller.svg"
    assert path.read_text(encoding="ascii") == icons.build_all()["install-to-hard-drive"]
