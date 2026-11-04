# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for tools/brandart/inventory.py (surface list -> inventory.json + assets)."""
import gzip
import json
import struct
import subprocess
import sys
import wave
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import inventory  # noqa: E402

SURFACES = HERE.parent / "surfaces.toml"


def png_bytes(w, h, color=(10, 20, 30)):
    from PIL import Image

    import io

    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, "PNG")
    return buf.getvalue()


def make_root(tmp_path):
    """A tiny fake image root with one file of each kind the surface list cares about."""
    root = tmp_path / "root"

    def put(rel, data):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data if isinstance(data, bytes) else data.encode())

    put("usr/share/pixmaps/logo.png", png_bytes(240, 310))
    put("usr/share/icons/hicolor/scalable/apps/mark.svg", '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 48"><g id="a"/></svg>')
    put("usr/share/icons/hicolor/scalable/apps/sheet.svgz", gzip.compress(
        b'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect id="panel-top"/><rect id="panel-left"/><g id="shadow"/></svg>'))
    put("usr/share/wallpapers/Dawn/contents/images/1920x1080.png", png_bytes(1920, 1080))
    put("usr/share/wallpapers/Dawn/contents/images/3840x2160.png", png_bytes(3840, 2160))
    put("usr/share/wallpapers/Dusk/contents/images/1280x720.png", png_bytes(1280, 720))
    put("usr/share/color-schemes/Ink.colors", "[Colors:Window]\nBackgroundNormal=27,35,48\nForegroundNormal=246,242,233\n")
    wav = root / "usr/share/sounds/ding.wav"
    wav.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(8000)
        w.writeframes(b"\x00\x00" * 16000)  # exactly 2.0 s
    put("usr/share/icons/breeze/places/48/folder.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48"/>')
    return root


def write_surfaces(tmp_path, body):
    p = tmp_path / "surfaces.toml"
    p.write_text(body)
    return p


GOOD = """
[[group]]
id = "logos"
title = "Logos"
seen = "Everywhere"
patterns = ["usr/share/pixmaps/*.png", "usr/share/icons/hicolor/scalable/apps/mark.svg"]
requests = [{ title = "A favicon", seen = "Browser tab" }]

[[group]]
id = "wallpapers"
title = "Wallpapers"
seen = "Desktop"
patterns = ["usr/share/wallpapers/*/contents/images/*.png"]
collapse_by = "usr/share/wallpapers/([^/]+)/"

[[group]]
id = "theme"
title = "Plasma theme"
seen = "Panels"
patterns = ["usr/share/icons/hicolor/scalable/apps/sheet.svgz", "usr/share/color-schemes/*.colors"]

[[group]]
id = "sounds"
title = "Sounds"
seen = "Login"
patterns = ["usr/share/sounds/*.wav"]
"""


def run(tmp_path, surfaces_text=GOOD, owners=None):
    root = make_root(tmp_path)
    surfaces = write_surfaces(tmp_path, surfaces_text)
    out = tmp_path / "out"
    owners_file = None
    if owners is not None:
        owners_file = tmp_path / "owners.json"
        owners_file.write_text(json.dumps(owners))
    inv = inventory.build(root, surfaces, out, owners=owners_file)
    return inv, out


def items(inv):
    return {i["id"]: i for g in inv["groups"] for i in g["items"]}


def test_the_real_surface_list_parses_and_is_well_formed():
    spec = inventory.load_surfaces(SURFACES)
    ids = [g["id"] for g in spec]
    assert len(ids) == len(set(ids)) >= 9
    for g in spec:
        assert g["title"] and g["seen"], g["id"]
        assert g.get("patterns") or g.get("icon_list") or g.get("requests"), f"group {g['id']} is empty"
        if g.get("icon_list"):
            assert (SURFACES.parent / g["icon_list"]).is_file(), g["icon_list"]


def test_a_pattern_that_matches_nothing_fails_and_names_the_pattern(tmp_path):
    bad = GOOD.replace('patterns = ["usr/share/sounds/*.wav"]', 'patterns = ["usr/share/sounds/nothing-here/*.wav"]')
    with pytest.raises(inventory.SurfaceError) as e:
        run(tmp_path, bad)
    assert "usr/share/sounds/nothing-here/*.wav" in str(e.value)


def test_a_missing_mark_turns_an_empty_pattern_into_a_request_item(tmp_path):
    ok = GOOD.replace('patterns = ["usr/share/sounds/*.wav"]',
                      'patterns = ["usr/share/sounds/nothing-here/*.wav"]\nmissing = true')
    inv, _ = run(tmp_path, ok)
    kinds = [i["kind"] for g in inv["groups"] if g["id"] == "sounds" for i in g["items"]]
    assert kinds == ["missing"]


def test_requests_become_missing_items(tmp_path):
    inv, _ = run(tmp_path)
    logos = next(g for g in inv["groups"] if g["id"] == "logos")
    req = [i for i in logos["items"] if i["kind"] == "missing"]
    assert len(req) == 1 and req[0]["title"] == "A favicon" and req[0]["seen"] == "Browser tab"


def test_ids_are_unique_and_stable_across_runs(tmp_path):
    a, _ = run(tmp_path / "a")
    b, _ = run(tmp_path / "b")
    ids_a = [i["id"] for g in a["groups"] for i in g["items"]]
    ids_b = [i["id"] for g in b["groups"] for i in g["items"]]
    assert ids_a == ids_b and len(ids_a) == len(set(ids_a))


def test_dimensions_are_read_for_png_svg_and_svgz(tmp_path):
    inv, _ = run(tmp_path)
    by_source = {i["source"]: i for g in inv["groups"] for i in g["items"] if i.get("source")}
    assert (by_source["/usr/share/pixmaps/logo.png"]["width"], by_source["/usr/share/pixmaps/logo.png"]["height"]) == (240, 310)
    mark = by_source["/usr/share/icons/hicolor/scalable/apps/mark.svg"]
    assert (mark["width"], mark["height"]) == (64, 48)
    sheet = by_source["/usr/share/icons/hicolor/scalable/apps/sheet.svgz"]
    assert (sheet["width"], sheet["height"]) == (100, 50)
    assert sheet["kind"] == "svg" and sheet["elements"] == ["panel-top", "panel-left", "shadow"]


def test_svgz_is_decompressed_into_a_viewable_svg_asset(tmp_path):
    inv, out = run(tmp_path)
    sheet = next(i for g in inv["groups"] for i in g["items"] if (i.get("source") or "").endswith("sheet.svgz"))
    asset = out / sheet["preview"]
    assert asset.suffix == ".svg" and asset.read_text().lstrip().startswith("<svg")


def test_a_file_matched_by_two_patterns_appears_once(tmp_path):
    twice = GOOD.replace('patterns = ["usr/share/pixmaps/*.png", "usr/share/icons/hicolor/scalable/apps/mark.svg"]',
                         'patterns = ["usr/share/pixmaps/*.png", "usr/share/pixmaps/logo.png", "usr/share/icons/hicolor/scalable/apps/mark.svg"]')
    inv, _ = run(tmp_path, twice)
    sources = [i["source"] for g in inv["groups"] for i in g["items"] if i.get("source") == "/usr/share/pixmaps/logo.png"]
    assert len(sources) == 1


def test_collapsing_keeps_the_largest_file_as_the_preview_and_lists_the_rest(tmp_path):
    inv, _ = run(tmp_path)
    dawn = next(i for g in inv["groups"] for i in g["items"] if i["id"].endswith("dawn"))
    assert (dawn["width"], dawn["height"]) == (3840, 2160)
    assert dawn["variants"] == ["1920x1080.png"] or dawn["variants"] == ["/usr/share/wallpapers/Dawn/contents/images/1920x1080.png"]
    dusk = next(i for g in inv["groups"] for i in g["items"] if i["id"].endswith("dusk"))
    assert dusk["variants"] == []


def test_kinds_are_detected(tmp_path):
    inv, _ = run(tmp_path)
    kinds = {i["source"].rsplit("/", 1)[-1]: i["kind"] for g in inv["groups"] for i in g["items"] if i.get("source")}
    assert kinds["Ink.colors"] == "colors" and kinds["ding.wav"] == "sound" and kinds["logo.png"] == "png"


def test_owner_and_license_come_from_the_owners_file(tmp_path):
    owners = {"/usr/share/pixmaps/logo.png": {"owner": "nisse-branding-0.2-1", "license": "GPL-2.0-or-later"}}
    inv, _ = run(tmp_path, owners=owners)
    logo = next(i for g in inv["groups"] for i in g["items"] if i.get("source") == "/usr/share/pixmaps/logo.png")
    assert (logo["owner"], logo["license"]) == ("nisse-branding-0.2-1", "GPL-2.0-or-later")
    other = next(i for g in inv["groups"] for i in g["items"] if (i.get("source") or "").endswith("mark.svg"))
    assert (other["owner"], other["license"]) == ("", "")


def test_a_wav_reports_its_duration(tmp_path):
    inv, _ = run(tmp_path)
    ding = next(i for g in inv["groups"] for i in g["items"] if (i.get("source") or "").endswith("ding.wav"))
    assert ding["duration"] == pytest.approx(2.0, abs=0.01)


def test_icon_lists_resolve_names_to_breeze_files_and_report_unknown_names(tmp_path):
    (tmp_path / "icons.txt").write_text("# core icons\nfolder\nno-such-icon\n")
    text = GOOD + """
[[group]]
id = "icons"
title = "Core icons"
seen = "Everywhere"
icon_list = "icons.txt"
"""
    inv, _ = run(tmp_path, text)
    icons = next(g for g in inv["groups"] if g["id"] == "icons")
    assert [i["title"] for i in icons["items"] if i["kind"] != "missing"] == ["folder"]
    assert any("no-such-icon" in n for n in inv["notes"])


def test_stage_copies_only_the_selected_files_and_asks_rpm_for_owners(tmp_path):
    root = make_root(tmp_path)
    surfaces = write_surfaces(tmp_path, GOOD)
    fake_rpm = tmp_path / "fake_rpm.py"
    fake_rpm.write_text("import sys, os\nprint('owner-of-' + os.path.basename(sys.argv[-1]) + '|MIT')\n")
    stage = tmp_path / "stage"
    inventory.stage(root, surfaces, stage, rpmdb=str(tmp_path / "db"), rpm=[sys.executable, str(fake_rpm)])
    assert (stage / "usr/share/pixmaps/logo.png").is_file()
    assert not (stage / "usr/share/icons/breeze").exists()  # not selected by any pattern
    owners = json.loads((stage / "owners.json").read_text())
    assert owners["/usr/share/pixmaps/logo.png"] == {"owner": "owner-of-logo.png", "license": "MIT"}
    # wallpapers collapse: only the largest file of each wallpaper is staged
    assert (stage / "usr/share/wallpapers/Dawn/contents/images/3840x2160.png").is_file()
    assert not (stage / "usr/share/wallpapers/Dawn/contents/images/1920x1080.png").exists()


def test_the_command_line_builds_an_inventory(tmp_path):
    root = make_root(tmp_path)
    surfaces = write_surfaces(tmp_path, GOOD)
    out = tmp_path / "out"
    r = subprocess.run([sys.executable, str(HERE.parent / "inventory.py"), "build", str(root), "--surfaces", str(surfaces), "--out", str(out)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert (out / "inventory.json").is_file()
    json.loads((out / "inventory.json").read_text())


def test_symlinked_aliases_are_not_separate_items(tmp_path):
    # cursor themes and icon themes are full of alias symlinks; they are the same artwork, not new items
    root = make_root(tmp_path)
    d = root / "usr/share/icons/cur/cursors"
    d.mkdir(parents=True)
    (d / "left_ptr").write_bytes(b"Xcur")
    try:
        (d / "arrow").symlink_to("left_ptr")
    except (OSError, NotImplementedError):
        pytest.skip("this platform cannot create symlinks")
    cursors = """
[[group]]
id = "cursors"
title = "Cursors"
seen = "Pointer"
patterns = ["usr/share/icons/cur/cursors/*"]
kind = "cursor"
"""
    surfaces = write_surfaces(tmp_path, GOOD + cursors)
    inv = inventory.build(root, surfaces, tmp_path / "out2")
    group = next(g for g in inv["groups"] if g["id"] == "cursors")
    assert [i["title"] for i in group["items"]] == ["left_ptr"]


def test_items_with_the_same_name_are_told_apart_by_their_size(tmp_path):
    root = make_root(tmp_path)
    for size in (16, 48):
        d = root / f"usr/share/icons/hicolor/{size}x{size}/apps"
        d.mkdir(parents=True)
        (d / "mark.png").write_bytes(png_bytes(size, size))
    surfaces = write_surfaces(tmp_path, GOOD + """
[[group]]
id = "marks"
title = "Marks"
seen = "x"
patterns = ["usr/share/icons/hicolor/*x*/apps/mark.png"]
""")
    inv = inventory.build(root, surfaces, tmp_path / "out3")
    group = next(g for g in inv["groups"] if g["id"] == "marks")
    assert sorted(i["title"] for i in group["items"]) == ["mark (16x16)", "mark (48x48)"]
    assert sorted(i["id"] for i in group["items"]) == ["marks/mark-16x16", "marks/mark-48x48"]


def test_icons_in_the_preferences_category_are_found(tmp_path):
    root = make_root(tmp_path)
    p = root / "usr/share/icons/breeze/preferences/32/preferences-desktop-wallpaper.svg"
    p.parent.mkdir(parents=True)
    p.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"/>')
    assert inventory.find_icon(root, "preferences-desktop-wallpaper") == (
        "usr/share/icons/breeze/preferences/32/preferences-desktop-wallpaper.svg"
    )


def test_notes_are_listed_once(tmp_path):
    (tmp_path / "icons.txt").write_text("folder\nnope-a\nnope-b\n")
    text = GOOD + """
[[group]]
id = "icons"
title = "Icons"
seen = "x"
icon_list = "icons.txt"
"""
    # a staged tree carries the notes the staging step already made; the build step finds the same icons missing again
    root = make_root(tmp_path)
    (root / "notes.json").write_text(json.dumps(["icons: icon nope-a not found in the image"]))
    inv = inventory.build(root, write_surfaces(tmp_path, text), tmp_path / "out")
    assert len(inv["notes"]) == len(set(inv["notes"])) == 2
