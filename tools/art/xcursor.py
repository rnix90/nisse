#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-408: read and write Xcursor files, the format X11 and Wayland cursor themes use.

A file is a header ("Xcur", header size 16, version, number of chunks), a table of contents (type, nominal size, position per
chunk) and one image chunk per size: 36 header bytes (size, type, nominal size, version, width, height, hotspot x and y, delay)
then width x height pixels as 32-bit little-endian ARGB with the colors PREMULTIPLIED by alpha. This module needs only Pillow;
it replaces the xcursorgen tool so the theme builds anywhere.
"""
import struct
from dataclasses import dataclass

from PIL import Image

IMAGE_TYPE = 0xFFFD0002


@dataclass
class Frame:
    nominal: int          # the nominal size the cursor library asks for (12 for a 16 pixel picture in Breeze)
    image: Image.Image    # RGBA, not premultiplied
    xhot: int
    yhot: int
    delay: int = 50


def _premultiply(img):
    out = bytearray()
    for r, g, b, a in img.convert("RGBA").getdata():
        out += bytes((b * a // 255, g * a // 255, r * a // 255, a))          # little-endian ARGB: B, G, R, A
    return bytes(out)


def _unpremultiply(raw, w, h):
    px = []
    for i in range(0, len(raw), 4):
        b, g, r, a = raw[i:i + 4]
        if a:
            px.append((min(255, (r * 255 + a // 2) // a), min(255, (g * 255 + a // 2) // a), min(255, (b * 255 + a // 2) // a), a))
        else:
            px.append((0, 0, 0, 0))
    img = Image.new("RGBA", (w, h))
    img.putdata(px)
    return img


def encode(frames):
    """The bytes of an Xcursor file holding these frames, in order."""
    n = len(frames)
    pos = 16 + 12 * n
    toc, chunks = b"", b""
    for f in frames:
        w, h = f.image.size
        body = struct.pack("<9I", 36, IMAGE_TYPE, f.nominal, 1, w, h, f.xhot, f.yhot, f.delay) + _premultiply(f.image)
        toc += struct.pack("<III", IMAGE_TYPE, f.nominal, pos + len(chunks))
        chunks += body
    return struct.pack("<4sIII", b"Xcur", 16, 0x10000, n) + toc + chunks


def decode(data):
    """The frames of an Xcursor file (image chunks only), in file order."""
    if data[:4] != b"Xcur":
        raise ValueError("not an Xcursor file")
    _, header_size, _, n = struct.unpack("<4sIII", data[:16])
    frames = []
    for i in range(n):
        kind, nominal, pos = struct.unpack("<III", data[header_size + 12 * i:header_size + 12 * i + 12])
        if kind != IMAGE_TYPE:
            continue
        _, _, _, _, w, h, xh, yh, delay = struct.unpack("<9I", data[pos:pos + 36])
        frames.append(Frame(nominal, _unpremultiply(data[pos + 36:pos + 36 + 4 * w * h], w, h), xh, yh, delay))
    return frames
