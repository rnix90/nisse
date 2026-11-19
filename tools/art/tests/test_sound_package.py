# SPDX-License-Identifier: GPL-2.0-or-later
"""N-414 wiring: the approved sounds are a freedesktop sound theme (the nisse-sounds package) that Plasma selects by default, so every
sound is reachable by the name KDE actually asks for. The manifest assets/audio/theme/names.txt is the single source for the
package; these tests check it against what Plasma 6.8 plays (read from the Fedora 44 packages, see docs/sound-theme.md) and against
the files, and that the package, the default and the build all reference it."""
import re
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import sounds  # noqa: E402

ROOT = HERE.parents[2]
THEME_DIR = ROOT / "assets" / "audio" / "theme"
MANIFEST = THEME_DIR / "names.txt"
PKG = ROOT / "packaging" / "rpm" / "nisse-sounds"


def _manifest():
    out = {}
    for line in MANIFEST.read_text(encoding="ascii").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            f, *names = line.split()
            out[f[:-4]] = names
    return out


def test_every_theme_sound_is_in_the_manifest_and_every_manifest_file_exists():
    m = _manifest()
    assert set(m) == set(sounds.THEME)
    for event in m:
        assert (THEME_DIR / f"{event}.wav").is_file()
    for event, names in m.items():
        assert names, event


# what Plasma 6.8 asks for (verified in the Fedora 44 packages): the startup sound plays "desktop-login", the exitkde event
# "desktop-logout", plasma-pa the "audio-volume-change" feedback, notifyrc error events "dialog-error" and its serious variant
REQUIRED = {
    "login": "desktop-login",
    "logout": "desktop-logout",
    "volume": "audio-volume-change",
    "error": "dialog-error",
    "notification": "message-new-instant",
    "needs-you": "nisse-needs-you",
}


@pytest.mark.parametrize("event,name", sorted(REQUIRED.items()))
def test_each_event_answers_to_the_name_plasma_asks_for(event, name):
    assert _manifest()[event][0] == name, "the first name is the real file, the one KDE asks for"


def test_error_covers_the_serious_and_critical_variants_too():
    assert {"dialog-error-serious", "dialog-error-critical"} <= set(_manifest()["error"])


def test_no_name_is_claimed_twice():
    names = [n for ns in _manifest().values() for n in ns]
    assert len(names) == len(set(names))


def test_the_panels_own_sound_name_is_the_one_in_the_manifest():
    src = (ROOT / "panel" / "src" / "DesktopNotify.cpp").read_text(encoding="utf-8")
    assert _manifest()["needs-you"][0] in src, "the approval notice must ask for the sound the theme provides"


def test_index_theme_names_the_theme_and_falls_back_to_ocean_for_every_other_event():
    text = (PKG / "index.theme").read_text(encoding="ascii")
    assert text.startswith("[Sound Theme]") or "[Sound Theme]" in text
    assert re.search(r"^Name=nisse$", text, re.M)
    assert re.search(r"^Inherits=ocean,freedesktop$", text, re.M)
    assert re.search(r"^Directories=stereo$", text, re.M)
    assert re.search(r"^\[stereo\]\s*$", text, re.M) and "OutputProfile=stereo" in text


def test_the_system_default_selects_the_nisse_sound_theme():
    kg = (ROOT / "assets" / "theme" / "xdg" / "kdeglobals").read_text(encoding="utf-8")
    sect = re.search(r"^\[Sounds\]\n((?:[^\[\n].*\n?)*)", kg, re.M)
    assert sect, "kdeglobals has no [Sounds] section"
    assert re.search(r"^Theme=nisse$", sect.group(1), re.M)
    spec = (ROOT / "packaging" / "rpm" / "nisse-lookandfeel" / "nisse-lookandfeel.spec").read_text(encoding="utf-8")
    assert re.search(r"^Requires:\s+nisse-sounds\s*$", spec, re.M), "the default names a theme the package must bring"


def test_the_package_is_built_and_installed_in_the_image():
    assert "nisse-sounds" in (ROOT / "build" / "build-all.sh").read_text(encoding="utf-8")
    assert 'name="nisse-sounds"' in (ROOT / "build" / "kiwi" / "nisse" / "components" / "nisse-live.xml").read_text(encoding="utf-8")
    spec = (PKG / "nisse-sounds.spec").read_text(encoding="utf-8")
    assert "names.txt" in spec and "License:        GPL-2.0-or-later" in spec


def test_package_files_are_ascii():
    for p in (PKG / "index.theme", PKG / "nisse-sounds.spec", MANIFEST):
        assert p.read_text(encoding="utf-8").isascii(), p
