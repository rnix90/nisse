# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508: dnf5 treats `install X --exclude=X` as an error (the solver says the argument matches only excluded packages), and kiwi runs
exactly that when a package is both listed and ignored. Fedora's own description lists some apps by name (the vendored copy names
mediawriter), so when nisse drops one, build/render-kiwi.sh takes the line out of the RENDERED copy (the vendored tree stays as
published) with tools/build/apply_drops.py."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import apply_drops as ad  # noqa: E402

COMMON = """<image>
  <packages type="image" patternType="plusRecommended" profiles="DesktopCommon">
    <namedCollection name="fonts"/>
    <package name="mediawriter"/>
    <package name="keepme"/>
    <ignore name="gfs2-utils"/>
  </packages>
</image>
"""
LIVE = """<image>
  <packages type="image" profiles="Nisse-Live">
    <package name="mediawriter"/>
    <ignore name="mediawriter"/>
  </packages>
</image>
"""


def make(tmp_path, policy="drop|mediawriter|Fedora Media Writer|org.fedoraproject.MediaWriter.desktop\nadd|vlc|VLC|vlc.desktop\n"):
    d = tmp_path / "desc"
    (d / "components" / "desktops").mkdir(parents=True)
    (d / "nisse" / "components").mkdir(parents=True)
    (d / "components" / "desktops" / "common.xml").write_text(COMMON)
    (d / "nisse" / "components" / "nisse-live.xml").write_text(LIVE)
    pol = tmp_path / "default-apps.txt"
    pol.write_text(policy)
    return d, pol


def test_a_dropped_package_is_taken_out_of_the_fedora_lists(tmp_path):
    d, pol = make(tmp_path)
    removed = ad.apply(d, pol)
    text = (d / "components" / "desktops" / "common.xml").read_text()
    assert '<package name="mediawriter"/>' not in text
    assert '<package name="keepme"/>' in text and '<ignore name="gfs2-utils"/>' in text
    assert removed == [("components/desktops/common.xml", "mediawriter")]


def test_the_nisse_files_are_left_alone(tmp_path):
    d, pol = make(tmp_path)
    ad.apply(d, pol)
    assert (d / "nisse" / "components" / "nisse-live.xml").read_text() == LIVE


def test_only_drops_are_removed_not_additions_or_hidden_ones(tmp_path):
    d, pol = make(tmp_path, policy="add|keepme|X|x.desktop\nhide|keepme2|Y|y.desktop\n")
    assert ad.apply(d, pol) == []
    assert '<package name="keepme"/>' in (d / "components" / "desktops" / "common.xml").read_text()


def test_the_result_is_well_formed_xml_and_a_second_run_changes_nothing(tmp_path):
    import xml.etree.ElementTree as ET
    d, pol = make(tmp_path)
    ad.apply(d, pol)
    ET.parse(d / "components" / "desktops" / "common.xml")
    assert ad.apply(d, pol) == []
