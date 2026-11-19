# SPDX-License-Identifier: GPL-2.0-or-later
"""N-415: no approved art is left unpackaged and no open art request is left without an owner.

tests/rpm/approved-art.txt lists every approved asset: its path in the image, the package that ships it and the task that made it.
tools/brandart/surfaces.toml lists the art the brand inventory still asks for ("requests"). Each request must say what became of
it: `shipped` (a path in the manifest), `owner` (an OPEN ledger task that will build it), `repo` (it lives in the repository and
is not part of the image) or `decided` (a done task that decided against it). A shipped asset nothing uses yet also names the open
task that will use it (`used_by`), so it is not built and forgotten."""
import re
import sys
import tomllib
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "tools" / "art"))

MANIFEST = ROOT / "tests" / "rpm" / "approved-art.txt"
SURFACES = ROOT / "tools" / "brandart" / "surfaces.toml"
LEDGER = ROOT / "docs" / "planning" / "TASK-LEDGER.md"


def _manifest():
    rows = []
    for line in MANIFEST.read_text(encoding="ascii").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            path, pkg, task, *opts = line.split()
            rows.append({"path": path, "pkg": pkg, "task": task, "min": int(next((o[4:] for o in opts if o.startswith("min=")), 1))})
    return rows


def _tasks():
    text = LEDGER.read_text(encoding="utf-8")
    return {m.group(2): m.group(1) == "x" for m in re.finditer(r"^- \[(.)\] \*\*(N-\d+[a-z]?)\*\*", text, re.M)}


def _requests():
    out = []
    for g in tomllib.loads(SURFACES.read_text(encoding="utf-8"))["group"]:
        for r in g.get("requests", []):
            out.append((g["id"], r))
    return out


def test_manifest_lines_are_well_formed_and_every_package_and_task_exists():
    tasks = _tasks()
    rows = _manifest()
    assert len(rows) >= 25
    for r in rows:
        assert r["path"].startswith("/usr/") or r["path"].startswith("/etc/"), r
        assert (ROOT / "packaging" / "rpm" / r["pkg"] / f"{r['pkg']}.spec").is_file(), f"no package {r['pkg']}"
        assert tasks.get(r["task"]) is True, f"{r['task']} must be a done task in the ledger ({r['path']})"


def test_no_path_is_listed_twice():
    paths = [r["path"] for r in _manifest()]
    assert len(paths) == len(set(paths))


def test_the_six_tray_icons_are_in_the_manifest_and_the_branding_spec():
    import tray_icons
    rows = {r["path"]: r for r in _manifest()}
    spec = (ROOT / "packaging" / "rpm" / "nisse-branding" / "nisse-branding.spec").read_text(encoding="utf-8")
    assert "assets/art/tray/svg" in spec and "hicolor/scalable/status" in spec
    for state in tray_icons.STATES:
        path = f"/usr/share/icons/hicolor/scalable/status/{tray_icons.file_name(state)}"
        assert rows[path]["pkg"] == "nisse-branding" and rows[path]["task"] == "N-415", path
        assert (ROOT / "assets" / "art" / "tray" / "svg" / tray_icons.file_name(state)).is_file()


KEYS = {"shipped", "owner", "repo", "decided"}


def _unowned(requests):
    return [r["title"] for _, r in requests if not (KEYS & set(r))]


def test_every_request_says_what_became_of_it():
    assert _unowned(_requests()) == [], "give each of these requests shipped, owner, repo or decided"


def test_an_owner_is_an_open_task_and_a_decision_is_a_done_one():
    tasks = _tasks()
    for gid, r in _requests():
        if "owner" in r:
            assert tasks.get(r["owner"]) is False, f"[{gid}] '{r['title']}': {r['owner']} must be an open ledger task"
        if "decided" in r:
            t = r["decided"].split(":")[0].strip()
            assert tasks.get(t) is True, f"[{gid}] '{r['title']}': {t} must be a done ledger task"
        if "used_by" in r:
            assert tasks.get(r["used_by"]) is False, f"[{gid}] '{r['title']}': {r['used_by']} must be an open ledger task"


def test_a_shipped_request_points_at_the_manifest():
    paths = {r["path"] for r in _manifest()}
    for gid, r in _requests():
        if "shipped" in r:
            assert r["shipped"] in paths, f"[{gid}] '{r['title']}' claims {r['shipped']}, which is not in tests/rpm/approved-art.txt"


def test_the_tray_art_names_the_task_that_will_use_it():
    tray = [r for _, r in _requests() if "tray icon" in r["title"]]
    assert tray and tray[0].get("used_by") == "N-415b", "shipped tray icons must name the task that wires them (N-415b)"


def test_an_orphan_request_is_caught():
    toml = ' '.join([
        '[[group]]', 'id = "x"', 'title = "X"', 'seen = "y"',
        'requests = [{ title = "Orphan", seen = "z" }, { title = "Ok", seen = "z", owner = "N-502" }]'])
    bad = tomllib.loads(toml.replace(' id', chr(10) + 'id').replace(' title = "X"', chr(10) + 'title = "X"').replace(' seen = "y"', chr(10) + 'seen = "y"').replace(' requests', chr(10) + 'requests'))
    assert _unowned([('x', r) for r in bad['group'][0]['requests']]) == ['Orphan']
