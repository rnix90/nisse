# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for tools/brandart/serve.py (local server, safe comment store, export)."""
import json
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import inventory  # noqa: E402
import previews  # noqa: E402
import serve  # noqa: E402
from test_inventory import GOOD, make_root, write_surfaces  # noqa: E402


@pytest.fixture
def site(tmp_path):
    root = make_root(tmp_path)
    out = tmp_path / "brandart"
    inventory.build(root, write_surfaces(tmp_path, GOOD), out,
                    image={"iso": "nisse-live.iso", "built": "2026-11-04T10:00Z", "sha256": "abcd1234abcd1234"})
    previews.run(out)
    server = serve.make_server(out, port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield base, out
    server.shutdown()
    server.server_close()


def call(base, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def item_ids(out):
    inv = json.loads((out / "inventory.json").read_text())
    return {i["title"]: i["id"] for g in inv["groups"] for i in g["items"]}


# a comment full of characters outside ASCII: e acute, em dash, curly quotes and an emoji (built from code points so this
# file stays plain ASCII)
NON_ASCII = "caf" + chr(0xE9) + " " + chr(0x2014) + " " + chr(0x201C) + "quoted" + chr(0x201D) + " " + chr(0x1F600)


def state(**kw):
    base = {"direction": "", "items": {}, "groups": {}, "custom": []}
    base.update(kw)
    return base


def test_the_default_state_is_empty(site):
    base, _ = site
    status, body = call(base, "GET", "/api/state")
    assert status == 200 and json.loads(body) == state()


def test_state_round_trips(site):
    base, _ = site
    s = state(direction="warm and friendly", items={"logos/logo": {"verdict": "redraw", "priority": "must", "comment": "more cap"}},
              groups={"logos": {"comment": "all of these"}}, custom=[{"id": "custom-1", "title": "Tray icon", "comment": "mono"}])
    assert call(base, "PUT", "/api/state", s)[0] == 200
    assert json.loads(call(base, "GET", "/api/state")[1]) == s


def test_an_invalid_verdict_is_rejected_and_changes_nothing(site):
    base, out = site
    good = state(items={"a": {"verdict": "keep", "priority": "", "comment": "ok"}})
    call(base, "PUT", "/api/state", good)
    bad = state(items={"a": {"verdict": "explode", "priority": "", "comment": "x"}})
    status, _ = call(base, "PUT", "/api/state", bad)
    assert status == 400
    assert json.loads((out / "comments.json").read_text()) == good


def test_a_malformed_body_is_a_400_not_a_crash(site):
    base, _ = site
    req = urllib.request.Request(base + "/api/state", data=b"{not json", method="PUT")
    with pytest.raises(urllib.error.HTTPError) as e:
        urllib.request.urlopen(req, timeout=10)
    assert e.value.code == 400
    assert call(base, "GET", "/api/state")[0] == 200


def test_a_crash_between_the_temp_write_and_the_rename_keeps_the_old_file(site, monkeypatch):
    base, out = site
    good = state(direction="first")
    call(base, "PUT", "/api/state", good)

    def boom(*a, **k):
        raise OSError("disk went away")

    monkeypatch.setattr(serve.os, "replace", boom)
    status, _ = call(base, "PUT", "/api/state", state(direction="second"))
    assert status == 500
    monkeypatch.undo()
    assert json.loads((out / "comments.json").read_text()) == good
    assert not list(out.glob("comments.json.tmp*")), "the temp file must be cleaned up"


def test_the_previous_state_is_kept_as_a_backup(site):
    base, out = site
    call(base, "PUT", "/api/state", state(direction="one"))
    call(base, "PUT", "/api/state", state(direction="two"))
    assert json.loads((out / "comments.json.bak").read_text())["direction"] == "one"


def test_quick_consecutive_saves_all_land_and_the_last_wins(site):
    base, out = site
    results = []

    def save(n):
        results.append(call(base, "PUT", "/api/state", state(direction=f"v{n}"))[0])

    threads = [threading.Thread(target=save, args=(n,)) for n in range(12)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert results == [200] * 12
    assert json.loads((out / "comments.json").read_text())["direction"].startswith("v")


def test_an_oversized_body_is_refused(site):
    base, _ = site
    status, _ = call(base, "PUT", "/api/state", state(direction="x" * 3_000_000))
    assert status == 413


def test_the_server_refuses_a_non_loopback_bind(tmp_path):
    with pytest.raises(ValueError):
        serve.make_server(tmp_path, port=0, host="0.0.0.0")


def test_assets_and_the_inventory_are_served_and_paths_cannot_escape(site):
    base, out = site
    inv = json.loads(call(base, "GET", "/api/inventory")[1])
    asset = next(i["asset"] for g in inv["groups"] for i in g["items"] if i.get("asset"))
    assert call(base, "GET", "/" + asset)[0] == 200
    call(base, "PUT", "/api/state", state(direction="secret"))
    assert call(base, "GET", "/assets/../comments.json")[0] == 404
    assert call(base, "GET", "/assets/%2e%2e/comments.json")[0] == 404


def test_the_page_is_served(site):
    base, _ = site
    status, body = call(base, "GET", "/")
    assert status == 200 and b"Brand art review" in body


def test_export_writes_a_complete_ascii_brief_and_copies_the_redraw_originals(site):
    base, out = site
    ids = item_ids(out)
    logo, mark, dawn = ids["logo"], ids["mark"], ids["Dawn"] if "Dawn" in ids else ids["dawn"]
    s = state(
        direction="Warm, round, a little mischievous.",
        items={
            logo: {"verdict": "redraw", "priority": "must", "comment": "Make the cap bigger."},
            mark: {"verdict": "keep", "priority": "", "comment": "Fine as is."},
            dawn: {"verdict": "variant", "priority": "nice", "comment": "Needs a dark twin."},
        },
        groups={"logos": {"comment": "These are the most visible."}},
        custom=[{"id": "custom-1", "title": "Tray icon", "comment": "Monochrome, 4 states."}],
    )
    call(base, "PUT", "/api/state", s)
    status, body = call(base, "POST", "/api/export", {})
    assert status == 200
    result = json.loads(body)
    md = result["markdown"]
    assert Path(result["path"]).is_file() and Path(result["path"]).read_text() == md
    for needle in ("Overall direction", "Warm, round", "These are the most visible.", "Make the cap bigger.", "Fine as is.",
                   "Needs a dark twin.", "Tray icon", "Monochrome, 4 states.", "/usr/share/pixmaps/logo.png", "240x310",
                   "redraw", "must", logo, "nisse-live.iso"):
        assert needle in md, needle
    folder = Path(result["path"]).with_suffix("")
    copied = sorted(p.name for p in folder.iterdir())
    assert len(copied) == 2 and any(n.startswith(logo.replace("/", "__")) for n in copied)
    assert not any(n.startswith(mark.replace("/", "__")) for n in copied), "a 'keep' item must not be copied"


def test_export_is_pure_ascii_and_reports_what_it_replaced(site):
    base, out = site
    ids = item_ids(out)
    call(base, "PUT", "/api/state", state(items={ids["logo"]: {"verdict": "redraw", "priority": "", "comment": NON_ASCII}}))
    result = json.loads(call(base, "POST", "/api/export", {})[1])
    md = result["markdown"]
    md.encode("ascii")
    assert "replaced" in md.lower() and "non-ASCII" in md


def test_export_with_nothing_commented_still_works(site):
    base, _ = site
    status, body = call(base, "POST", "/api/export", {})
    assert status == 200 and "Overall direction" in json.loads(body)["markdown"]
