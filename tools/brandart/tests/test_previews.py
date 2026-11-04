# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for tools/brandart/previews.py (color swatches, Xcursor frames, icns, honest notes)."""
import json
import struct
import sys
from pathlib import Path

import pytest
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import inventory  # noqa: E402
import previews  # noqa: E402
from test_inventory import make_root, write_surfaces  # noqa: E402

SURFACES = """
[[group]]
id = "colors"
title = "Color schemes"
seen = "Everywhere"
patterns = ["usr/share/color-schemes/*.colors"]

[[group]]
id = "cursors"
title = "Cursors"
seen = "Pointer"
patterns = ["usr/share/icons/cur/cursors/*"]
kind = "cursor"

[[group]]
id = "installer"
title = "Installer"
seen = "Install"
patterns = ["usr/share/pixmaps/*.icns"]

[[group]]
id = "sounds"
title = "Sounds"
seen = "Login"
patterns = ["usr/share/sounds/*.wav"]
"""

SCHEME = """[Colors:Window]
BackgroundNormal=27,35,48
ForegroundNormal=246,242,233
DecorationFocus=224,98,63

[Colors:View]
BackgroundNormal=255,255,255
ForegroundNormal=20,20,20
DecorationFocus=61,174,233

[Colors:Selection]
BackgroundNormal=224,98,63
ForegroundNormal=255,255,255
DecorationFocus=224,98,63
"""


def xcursor(frames):
    """A synthetic Xcursor file: frames = [(nominal_size, width, height, (r, g, b, a)), ...]; one solid colour each."""
    chunks = []
    for nominal, w, h, (r, g, b, a) in frames:
        # pixels are premultiplied ARGB32, little endian: bytes B G R A
        pm = lambda c: c * a // 255
        pixel = bytes([pm(b), pm(g), pm(r), a])
        body = struct.pack("<IIIIIIIII", 36, 0xFFFD0002, nominal, 1, w, h, 0, 0, 50) + pixel * (w * h)
        chunks.append((nominal, body))
    header = struct.pack("<4sIII", b"Xcur", 16, 0x10000, len(chunks))
    offset = 16 + 12 * len(chunks)
    toc, blob = b"", b""
    for nominal, body in chunks:
        toc += struct.pack("<III", 0xFFFD0002, nominal, offset + len(blob))
        blob += body
    return header + toc + blob


def fixture(tmp_path, scheme=SCHEME, cursor=None, icns_ok=True):
    root = make_root(tmp_path)
    (root / "usr/share/color-schemes/Ember.colors").write_text(scheme)
    cur = root / "usr/share/icons/cur/cursors"
    cur.mkdir(parents=True)
    (cur / "left_ptr").write_bytes(cursor if cursor is not None else xcursor([(24, 24, 24, (255, 0, 0, 255)), (48, 48, 48, (0, 0, 255, 255))]))
    (cur / "busy").write_bytes(xcursor([(32, 32, 32, (0, 255, 0, 255)), (32, 32, 32, (0, 200, 0, 255))]))
    (cur / "broken").write_bytes(b"this is not an xcursor file")
    if icns_ok:
        Image.new("RGBA", (256, 256), (27, 35, 48, 255)).save(root / "usr/share/pixmaps/mark.icns", format="ICNS")
    out = tmp_path / "out"
    inv = inventory.build(root, write_surfaces(tmp_path, SURFACES), out)
    return inv, out


def find(inv, gid, title):
    return next(i for g in inv["groups"] if g["id"] == gid for i in g["items"] if i["title"] == title)


def test_a_color_scheme_gets_a_swatch_with_its_real_colors(tmp_path):
    inv, out = fixture(tmp_path)
    previews.run(out)
    item = find(json.loads((out / "inventory.json").read_text()), "colors", "Ember")
    img = Image.open(out / item["preview"]).convert("RGB")
    assert img.size == (720, 90)
    assert img.getpixel((5, 40)) == (27, 35, 48)        # Window background, first tile
    assert img.getpixel((20, 70)) == (246, 242, 233)    # Window foreground strip
    assert img.getpixel((20, 12)) == (224, 98, 63)      # Window decoration (focus) strip
    assert img.getpixel((125, 40)) == (255, 255, 255)   # View background, second tile
    assert item["roles"]["Window"]["BackgroundNormal"] == [27, 35, 48]


def test_a_color_scheme_missing_roles_still_renders_the_others(tmp_path):
    inv, out = fixture(tmp_path)
    previews.run(out)
    item = find(json.loads((out / "inventory.json").read_text()), "colors", "Ember")
    img = Image.open(out / item["preview"]).convert("RGB")
    # Button, Tooltip and Complementary are not in this scheme: a neutral grey tile, not a crash
    assert img.getpixel((245, 40)) == previews.MISSING_ROLE_COLOR


def test_a_cursor_renders_its_largest_size_and_extra_frames(tmp_path):
    inv, out = fixture(tmp_path)
    previews.run(out)
    data = json.loads((out / "inventory.json").read_text())
    left = find(data, "cursors", "left_ptr")
    img = Image.open(out / left["preview"]).convert("RGBA")
    assert img.size == (48, 48) and img.getpixel((3, 3)) == (0, 0, 255, 255)
    busy = find(data, "cursors", "busy")
    assert len(busy["variants"]) == 1  # the second animation frame
    assert Image.open(out / busy["variants"][0]).size == (32, 32)


def test_a_broken_cursor_stays_listed_with_a_note(tmp_path):
    inv, out = fixture(tmp_path)
    before = sum(len(g["items"]) for g in inv["groups"])
    previews.run(out)
    data = json.loads((out / "inventory.json").read_text())
    broken = find(data, "cursors", "broken")
    assert broken["preview"] is None and "not an Xcursor file" in broken["note"]
    assert sum(len(g["items"]) for g in data["groups"]) == before


def test_an_icns_file_gets_a_png_preview(tmp_path):
    inv, out = fixture(tmp_path)
    previews.run(out)
    mark = find(json.loads((out / "inventory.json").read_text()), "installer", "mark")
    img = Image.open(out / mark["preview"])
    assert img.format == "PNG" and img.size[0] >= 128


def test_sounds_stay_without_an_image_and_keep_their_duration(tmp_path):
    inv, out = fixture(tmp_path)
    previews.run(out)
    ding = find(json.loads((out / "inventory.json").read_text()), "sounds", "ding")
    assert ding["preview"] is None and ding["duration"] == pytest.approx(2.0, abs=0.01) and ding["audio"].endswith(".wav")


def test_running_twice_gives_the_same_inventory(tmp_path):
    inv, out = fixture(tmp_path)
    previews.run(out)
    first = (out / "inventory.json").read_text()
    previews.run(out)
    assert (out / "inventory.json").read_text() == first
