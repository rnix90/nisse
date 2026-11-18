# SPDX-License-Identifier: GPL-2.0-or-later
"""N-408: the Xcursor file reader and writer (the format X11 and Wayland cursor themes use)."""
import struct
import sys
from pathlib import Path

import pytest
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import xcursor  # noqa: E402


def frame(nominal, size, color=(224, 98, 63, 255)):
    return xcursor.Frame(nominal=nominal, image=Image.new("RGBA", (size, size), color), xhot=size // 2, yhot=size // 2)


def test_a_file_starts_with_the_magic_and_lists_one_image_chunk_per_frame():
    data = xcursor.encode([frame(12, 16), frame(24, 32)])
    magic, header_size, version, n = struct.unpack("<4sIII", data[:16])
    assert magic == b"Xcur" and header_size == 16 and n == 2
    for i in range(n):
        kind, nominal, pos = struct.unpack("<III", data[16 + 12 * i:28 + 12 * i])
        assert kind == 0xFFFD0002 and nominal in (12, 24)
        size, kind2, nominal2, ver, w, h, xh, yh, delay = struct.unpack("<9I", data[pos:pos + 36])
        assert size == 36 and kind2 == 0xFFFD0002 and nominal2 == nominal and w == h and xh == yh == w // 2


def test_pixels_are_stored_premultiplied_and_come_back_the_same():
    img = Image.new("RGBA", (4, 4), (200, 100, 50, 128))
    data = xcursor.encode([xcursor.Frame(12, img, 2, 2)])
    pos = struct.unpack("<I", data[16 + 8:16 + 12])[0]
    first = struct.unpack("<I", data[pos + 36:pos + 40])[0]
    a, r, g, b = first >> 24, (first >> 16) & 255, (first >> 8) & 255, first & 255
    assert a == 128 and abs(r - 100) <= 1 and abs(g - 50) <= 1 and abs(b - 25) <= 1      # premultiplied by alpha/255
    back = xcursor.decode(data)[0]
    assert back.nominal == 12 and (back.xhot, back.yhot) == (2, 2)
    got = back.image.getpixel((0, 0))
    assert abs(got[0] - 200) <= 2 and abs(got[1] - 100) <= 2 and abs(got[2] - 50) <= 2 and got[3] == 128


def test_a_roundtrip_keeps_every_frame_in_order():
    frames = [frame(12, 16), frame(18, 24), frame(24, 32)]
    back = xcursor.decode(xcursor.encode(frames))
    assert [f.nominal for f in back] == [12, 18, 24]
    assert [f.image.size for f in back] == [(16, 16), (24, 24), (32, 32)]


def test_a_file_that_is_not_an_xcursor_is_refused():
    with pytest.raises(ValueError):
        xcursor.decode(b"not a cursor at all, just text")
