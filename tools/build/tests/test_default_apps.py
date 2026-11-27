# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508: the default apps decision (docs/default-apps.md) as data (build/default-apps.txt) agrees with what the kiwi description asks for.
The real proof that a drop leaves the image, and that an addition arrives with everything it needs, is the dnf dry run of
tests/build/test_image_apps.sh in the build VM; these tests keep the data, the description and the document from drifting apart."""
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
POLICY = ROOT / "build" / "default-apps.txt"
LIVE = ROOT / "build" / "kiwi" / "nisse" / "components" / "nisse-live.xml"
DOC = ROOT / "docs" / "default-apps.md"
KINDS = ("drop", "hide", "add")


def rows():
    out = []
    for line in POLICY.read_text(encoding="ascii").splitlines():
        if line.strip() and not line.startswith("#"):
            kind, package, app, entries = line.split("|")
            out.append((kind, package, app, entries.split()))
    return out


def live():
    root = ET.parse(LIVE).getroot()
    packages, ignores = set(), set()
    for lst in root.iter("packages"):
        packages |= {p.get("name") for p in lst.findall("package")}
        ignores |= {p.get("name") for p in lst.findall("ignore")}
    return packages, ignores


def test_every_line_has_a_known_kind_and_a_package_once():
    seen = [p for _, p, _, _ in rows()]
    assert len(seen) == len(set(seen)), "a package is listed twice"
    assert {k for k, *_ in rows()} <= set(KINDS)


def test_every_drop_is_ignored_in_the_description():
    _, ignores = live()
    missing = [p for k, p, *_ in rows() if k == "drop" and p not in ignores]
    assert not missing, f"not <ignore>d in nisse-live.xml: {missing}"


def test_every_addition_is_a_package_of_the_description_and_not_ignored():
    packages, ignores = live()
    missing = [p for k, p, *_ in rows() if k == "add" and p not in packages]
    assert not missing, f"not a <package> in nisse-live.xml: {missing}"
    assert not [p for k, p, *_ in rows() if k == "add" and p in ignores]


def test_a_hidden_package_is_kept_and_not_ignored():
    _, ignores = live()
    for k, p, *_ in rows():
        if k == "hide":
            assert p not in ignores, p


def test_no_ignore_names_a_package_the_policy_does_not_know_apart_from_the_old_ones():
    """An <ignore> added for a drop must be in the policy, so the test of the dry run knows to look for it."""
    _, ignores = live()
    policy = {p for k, p, *_ in rows() if k == "drop"}
    older = {"fedora-release", "fedora-release-*", "fedora-logos", "generic-logos", "plasma-setup", "kde-settings-plasmalogin",
             "device-mapper-multipath", "fcoe-utils", "gfs2-utils"}
    assert not (ignores - policy - older), f"ignored but not in build/default-apps.txt: {sorted(ignores - policy - older)}"


def test_the_document_names_every_app_of_the_policy():
    text = " ".join(DOC.read_text(encoding="ascii").split())       # the drop list wraps across lines
    lacking = [app for k, _, app, _ in rows() if k in ("drop", "add") and app.split(" (")[0] not in text and app.replace("++", "") not in text]
    assert not lacking, f"docs/default-apps.md does not mention: {lacking}"


def test_the_file_is_ascii_and_every_launcher_entry_is_a_desktop_file_name():
    POLICY.read_bytes().decode("ascii")
    for _, _, _, entries in rows():
        for e in entries:
            assert re.fullmatch(r"[A-Za-z0-9._+-]+\.desktop", e), e


def test_the_hidden_launchers_list_is_the_hide_lines_of_the_policy():
    hidden = ROOT / "assets" / "defaults" / "hidden-launchers.txt"
    listed = [l.strip() for l in hidden.read_text(encoding="ascii").splitlines() if l.strip() and not l.startswith("#")]
    wanted = [e for k, _, _, entries in rows() if k == "hide" for e in entries]
    assert sorted(listed) == sorted(wanted)


def test_the_document_explains_why_a_package_is_hidden_instead_of_dropped():
    text = " ".join(DOC.read_text(encoding="ascii").split())
    assert "Dropping is blocked by a dependency" in text
    for k, package, app, _ in rows():
        if k == "hide":
            assert package in text, f"docs/default-apps.md does not say why {package} is hidden instead of dropped"
