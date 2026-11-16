# SPDX-License-Identifier: GPL-2.0-or-later
"""N-403: the n tile is the nisse panel app's own icon. Checks the pieces that can be checked without building an RPM:
the freedesktop icon files, the desktop file, the packaging that ships them and the RPM tests that look for them.
(The RPM and ISO tests themselves run in the Fedora build VM.)"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HICOLOR = ROOT / "assets" / "logo" / "n" / "hicolor"
SIZES = (16, 22, 24, 32, 48, 64, 96, 128, 192, 256, 512)


def test_the_icon_theme_files_exist_at_every_size_and_scalable_and_symbolic():
    for px in SIZES:
        png = HICOLOR / f"{px}x{px}" / "apps" / "nisse-n.png"
        assert png.is_file() and png.stat().st_size > 0, png
    svg = HICOLOR / "scalable" / "apps" / "nisse-n.svg"
    assert svg.is_file() and "SPDX-License-Identifier" in svg.read_text(encoding="ascii")
    sym = HICOLOR / "symbolic" / "apps" / "nisse-n-symbolic.svg"
    assert sym.is_file() and "currentColor" in sym.read_text(encoding="ascii")


def test_the_panel_desktop_file_uses_the_n_not_the_start_button_icon():
    text = (ROOT / "packaging" / "rpm" / "nisse-panel" / "nisse-panel.desktop").read_text(encoding="ascii")
    assert re.search(r"^Icon=nisse-n$", text, re.M), text
    assert "distributor-logo-nisse" not in text


def test_the_branding_package_ships_the_n_icons():
    spec = (ROOT / "packaging" / "rpm" / "nisse-branding" / "nisse-branding.spec").read_text(encoding="utf-8")
    assert "assets/logo/n/hicolor" in spec, "the spec must copy the n icon tree"
    assert re.search(r"^%\{_datadir\}/icons/hicolor/\*/apps/nisse-n\*$", spec, re.M), "the spec must list the n icons in %files"


def test_the_panel_package_requires_the_branding_that_ships_its_icon_and_was_rebuilt():
    spec = (ROOT / "packaging" / "rpm" / "nisse-panel" / "nisse-panel.spec").read_text(encoding="utf-8")
    assert re.search(r"^Requires:\s+nisse-branding$", spec, re.M)
    assert re.search(r"^Release:\s+16%\{\?dist\}$", spec, re.M), "the panel changed, so its release moves from 15 to 16"
    assert "- The panel's own icon is the nisse n" in spec


def test_the_vm_rpm_tests_look_for_the_new_icon():
    panel = (ROOT / "tests" / "rpm" / "test_nisse_panel.sh").read_text(encoding="utf-8")
    assert "Icon=nisse-n" in panel and "Icon=distributor-logo-nisse" not in panel
    brand = (ROOT / "tests" / "rpm" / "test_branding.sh").read_text(encoding="utf-8")
    assert "nisse-n.png" in brand and "nisse-n.svg" in brand and "nisse-n-symbolic.svg" in brand
