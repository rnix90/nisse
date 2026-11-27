# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508: tools/build/image_packages.py works out which packages the ISO will hold WITHOUT building the ISO: it reads the kiwi description the
way kiwi does (profiles and what they require, package lists, Fedora package groups, ignores), runs the same dnf5 install kiwi runs (as a
dry run in an empty root), and reads the answer. kiwi turns an <ignore> into dnf's --exclude, so a package that something hard-requires
cannot be dropped: the dry run fails and says which. These tests cover the reading and the parsing; the dry run itself is in
tests/build/test_image_apps.sh (it needs the Fedora build VM)."""
import shutil
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import image_packages as ip  # noqa: E402

ROOT = HERE.parents[2]

KIWI = """<?xml version="1.0" encoding="utf-8"?>
<image schemaversion="7.4" name="T">
  <include from="this://./parts/a.xml"/>
  <include from="this://./parts/b.xml"/>
  <packages type="bootstrap"><package name="filesystem"/></packages>
</image>
"""
PART_A = """<image>
  <profiles>
    <profile name="Top" description="t"><requires profile="Base"/><requires profile="Live"/></profile>
    <profile name="Base" description="b"/>
    <profile name="Live" description="l"/>
    <profile name="Other" description="o"/>
  </profiles>
  <packages type="image" patternType="plusRecommended" profiles="Base">
    <package name="bash"/><package name="arm-only" arch="aarch64"/><package name="both" arch="aarch64,x86_64"/>
    <namedCollection name="kde-apps"/><namedCollection name="pim" arch="aarch64,ppc64le"/>
    <ignore name="digikam"/>
  </packages>
  <packages type="image" profiles="Other"><package name="not-selected"/></packages>
</image>
"""
PART_B = """<image>
  <packages type="image" profiles="Top"><package name="top-pkg"/><ignore name="krusader"/></packages>
  <packages type="iso" profiles="Live"><package name="dracut-live"/><file name="x.yaml" target="y"/></packages>
  <packages type="image"><package name="no-profile"/></packages>
</image>
"""


@pytest.fixture
def description(tmp_path):
    (tmp_path / "parts").mkdir()
    (tmp_path / "Nisse.kiwi").write_text(KIWI)
    (tmp_path / "parts" / "a.xml").write_text(PART_A)
    (tmp_path / "parts" / "b.xml").write_text(PART_B)
    return tmp_path


def test_a_profile_pulls_in_the_lists_of_the_profiles_it_requires(description):
    sel = ip.load(description, "Top", arch="x86_64")
    assert {"bash", "both", "top-pkg", "dracut-live", "no-profile", "filesystem"} <= set(sel.packages)
    assert "not-selected" not in sel.packages


def test_a_list_for_another_architecture_is_left_out(description):
    sel = ip.load(description, "Top", arch="x86_64")
    assert "arm-only" not in sel.packages
    assert sel.groups == ["kde-apps"]


def test_ignores_are_collected_from_every_selected_list(description):
    assert ip.load(description, "Top", arch="x86_64").ignores == ["digikam", "krusader"]


def test_the_command_is_the_one_kiwi_runs_with_excludes_and_groups(description):
    sel = ip.load(description, "Top", arch="x86_64")
    cmd = ip.dnf_command(sel, root="/tmp/r", release="44", repo="/x/repo")
    assert cmd[:2] == ["sudo", "dnf"] and "--assumeno" in cmd
    assert "--exclude=digikam" in cmd and "--exclude=krusader" in cmd
    assert "@kde-apps" in cmd and "bash" in cmd
    assert "--setopt=install_weak_deps=True" in cmd           # patternType plusRecommended
    assert "--installroot=/tmp/r" in cmd and "--releasever=44" in cmd


SAMPLE = """Updating and loading repositories:
Repositories loaded.
Argument 'firefox' matches only excluded packages.

Package                                  Arch   Version                             Repository      Size
Installing:
 nisse-panel                             x86_64 0:0.1-20.fc44                       nisse        1.2 MiB
Installing group/module packages:
 akregator                               x86_64 0:25.12.3-1.fc44                    fedora       4.4 MiB
Installing dependencies:
 vlc-libs                                x86_64 1:3.0.23-8.fc44                     fedora      22.0 MiB
 fedora-bookmarks                        noarch 0:28-36.fc44                        fedora      93.8 KiB
Installing weak dependencies:
 vlc-plugin-ffmpeg                       x86_64 1:3.0.23-8.fc44                     fedora     257.2 KiB
Installing groups:
 KDE PIM

Transaction Summary:
 Installing:      5 packages
"""


def test_the_transaction_table_gives_the_package_names_and_nothing_else():
    assert ip.parse_transaction(SAMPLE) == ["akregator", "fedora-bookmarks", "nisse-panel", "vlc-libs", "vlc-plugin-ffmpeg"]


def test_a_solver_failure_is_reported_with_the_problem_text():
    text = """Failed to resolve the transaction:
Problem: package kleopatra-1:25.12.3-1.fc44.x86_64 requires kwatchgnupg, but none of the providers can be installed
  - conflicting requests
"""
    with pytest.raises(ip.SolverError) as e:
        ip.parse_transaction(text)
    assert "requires kwatchgnupg" in str(e.value)


def test_a_dropped_package_that_is_hard_required_is_named_in_the_error():
    text = "Problem: package plasma-desktop-1:6.6.4-1.fc44.x86_64 requires kfind, but none of the providers can be installed\n"
    with pytest.raises(ip.SolverError) as e:
        ip.parse_transaction(text)
    assert ip.blocked_names(str(e.value), ["kfind", "kwrite"]) == ["kfind"]


def test_the_notice_that_an_argument_only_matches_excluded_packages_is_not_a_blocker():
    text = ("Argument 'krusader' matches only excluded packages.\n"
            "Problem: package a requires kfind, but none of the providers can be installed\n")
    assert ip.blocked_names(text, ["krusader", "kfind"]) == ["kfind"]


def test_many_excluded_argument_notices_do_not_push_the_problem_out_of_the_report():
    notices = [f"Argument 'p{i}' matches only excluded packages." for i in range(90)]
    text = "\n".join(["Failed to resolve the transaction:"] + notices
                     + ["Problem 1: package a requires kfind, but none of the providers can be installed"]) + "\n"
    with pytest.raises(ip.SolverError) as e:
        ip.parse_transaction(text)
    assert "requires kfind" in str(e.value)


def test_output_that_is_not_a_transaction_is_refused():
    with pytest.raises(ip.SolverError):
        ip.parse_transaction("something else entirely\n")


def test_the_real_description_names_the_groups_and_the_nisse_packages(tmp_path):
    shutil.copytree(ROOT / "build" / "kiwi" / "fedora", tmp_path / "d")
    shutil.copy(ROOT / "build" / "kiwi" / "Nisse.kiwi", tmp_path / "d" / "Nisse.kiwi")
    shutil.copytree(ROOT / "build" / "kiwi" / "nisse", tmp_path / "d" / "nisse")
    sel = ip.load(tmp_path / "d", "Nisse-Live", arch="x86_64")
    assert {"kde-apps", "kde-media", "kde-pim", "kde-desktop-environment"} <= set(sel.groups)
    assert {"nisse-panel", "nisse-lookandfeel", "anaconda-live", "filesystem"} <= set(sel.packages)
    assert "fedora-release" in sel.ignores


def test_the_download_size_is_the_sum_of_the_package_sizes_in_mib():
    # 1.2 MiB + 4.4 MiB + 22.0 MiB + 93.8 KiB + 257.2 KiB
    expected = 1.2 + 4.4 + 22.0 + 93.8 / 1024 + 257.2 / 1024
    assert abs(ip.download_mib(SAMPLE) - expected) < 0.01
    assert ip.download_mib("nothing here") == 0.0
