#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Previews for the inventory items a browser cannot show directly (run after inventory.py build).

    previews.py DIR      DIR is the output directory of inventory.py build (inventory.json + assets/)

- colors  : a swatch PNG of the six roles Plasma schemes define (Window, View, Button, Selection, Tooltip, Complementary),
            each tile showing its background, a strip of its foreground and a strip of its focus decoration colour;
            the colours are also listed in the item as `roles`
- cursor  : the Xcursor file's largest size rendered to PNG; further animation frames of that size go to `variants`
- icns    : the Mac icon rendered to PNG
- sound   : `audio` points at the file (the page plays it); no image
- anything that cannot be previewed stays listed with `preview: null` and a `note` saying why; items are never dropped.

SVG and raster items already display natively and are left alone. Running it again gives the same result. Needs Pillow.
"""
import json
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROLES = ("Window", "View", "Button", "Selection", "Tooltip", "Complementary")
TILE_W, TILE_H = 120, 90
MISSING_ROLE_COLOR = (128, 128, 128)
XCURSOR_IMAGE = 0xFFFD0002
MAX_FRAMES = 12


# ---------------------------------------------------------------- color schemes

def parse_colors(text):
    """{section: {key: value}} from a KDE .colors file (an INI file that may repeat keys)."""
    sections, current = {}, None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = sections.setdefault(line[1:-1], {})
        elif "=" in line and current is not None:
            k, _, v = line.partition("=")
            current[k.strip()] = v.strip()
    return sections


def rgb(value):
    try:
        parts = [int(p) for p in value.split(",")[:3]]
        return tuple(max(0, min(255, p)) for p in parts) if len(parts) == 3 else None
    except (AttributeError, ValueError):
        return None


def swatch(asset_path, dst):
    """Write the swatch PNG; returns (roles dict) or None when the file has no usable role."""
    sections = parse_colors(Path(asset_path).read_text(encoding="utf-8", errors="replace"))
    img = Image.new("RGB", (TILE_W * len(ROLES), TILE_H), MISSING_ROLE_COLOR)
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.load_default(size=26)
    except TypeError:  # an old Pillow without sized default fonts
        font = ImageFont.load_default()
    roles = {}
    for n, role in enumerate(ROLES):
        sec = sections.get(f"Colors:{role}", {})
        bg, fg, focus = rgb(sec.get("BackgroundNormal")), rgb(sec.get("ForegroundNormal")), rgb(sec.get("DecorationFocus"))
        if bg is None:
            continue
        x = n * TILE_W
        draw.rectangle((x, 0, x + TILE_W - 1, TILE_H - 1), fill=bg)
        if focus:
            draw.rectangle((x + 8, 8, x + TILE_W - 9, 17), fill=focus)
        if fg:
            draw.text((x + 14, 24), "Aa", fill=fg, font=font)
            draw.rectangle((x + 8, 60, x + TILE_W - 9, 79), fill=fg)
        roles[role] = {k: list(v) for k, v in (("BackgroundNormal", bg), ("ForegroundNormal", fg), ("DecorationFocus", focus)) if v}
    if not roles:
        return None
    dst.parent.mkdir(parents=True, exist_ok=True)
    img.save(dst)
    return roles


# ---------------------------------------------------------------- cursors

def xcursor_frames(data):
    """[(nominal_size, delay_ms, PIL image)] of every image chunk in an Xcursor file; raises ValueError if not one."""
    if data[:4] != b"Xcur" or len(data) < 16:
        raise ValueError("not an Xcursor file")
    _, header_size, _, ntoc = struct.unpack("<4sIII", data[:16])
    frames = []
    for n in range(ntoc):
        kind, subtype, pos = struct.unpack("<III", data[header_size + 12 * n:header_size + 12 * n + 12])
        if kind != XCURSOR_IMAGE:
            continue
        _, _, nominal, _, w, h, _, _, delay = struct.unpack("<IIIIIIIII", data[pos:pos + 36])
        raw = data[pos + 36:pos + 36 + 4 * w * h]
        if len(raw) != 4 * w * h:
            raise ValueError("truncated Xcursor image")
        out = bytearray(len(raw))
        for i in range(0, len(raw), 4):
            b, g, r, a = raw[i:i + 4]
            if a:  # the file stores premultiplied alpha
                r, g, b = min(255, r * 255 // a), min(255, g * 255 // a), min(255, b * 255 // a)
            out[i:i + 4] = bytes((r, g, b, a))
        frames.append((nominal, delay, Image.frombytes("RGBA", (w, h), bytes(out))))
    if not frames:
        raise ValueError("an Xcursor file with no images")
    return frames


def render_cursor(asset_path, dst_base):
    """Writes <dst_base>.png and <dst_base>-f2.png ...; returns (preview_path, [extra frame paths])."""
    frames = xcursor_frames(Path(asset_path).read_bytes())
    largest = max(f[0] for f in frames)
    chosen = [f for f in frames if f[0] == largest][:MAX_FRAMES]
    paths = []
    for n, (_, _, img) in enumerate(chosen, start=1):
        p = Path(f"{dst_base}.png" if n == 1 else f"{dst_base}-f{n}.png")
        p.parent.mkdir(parents=True, exist_ok=True)
        img.save(p)
        paths.append(p)
    return paths[0], paths[1:]


# ---------------------------------------------------------------- driver

def run(out):
    out = Path(out)
    inv = json.loads((out / "inventory.json").read_text(encoding="utf-8"))
    for group in inv["groups"]:
        for item in group["items"]:
            kind, asset = item["kind"], item.get("asset")
            if kind == "missing" or not asset:
                continue
            src = out / asset
            base = out / "assets" / f"{item['id']}"
            item.pop("note", None)
            if kind == "colors":
                roles = swatch(src, Path(f"{base}-swatch.png"))
                if roles:
                    item["roles"], item["preview"] = roles, f"assets/{item['id']}-swatch.png"
                else:
                    item["preview"], item["note"] = None, "no color roles found in this scheme"
            elif kind == "cursor":
                try:
                    main, extra = render_cursor(src, base)
                    item["preview"] = main.relative_to(out).as_posix()
                    item["variants"] = [p.relative_to(out).as_posix() for p in extra]
                except (ValueError, struct.error, OSError) as e:
                    item["preview"], item["note"] = None, f"not an Xcursor file or unreadable ({e})"
            elif kind == "icns":
                try:
                    with Image.open(src) as im:
                        im = im.convert("RGBA")
                    dst = Path(f"{base}.png")
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    im.save(dst)
                    item["preview"] = f"assets/{item['id']}.png"
                except (OSError, ValueError) as e:
                    item["preview"], item["note"] = None, f"icns could not be decoded ({e})"
            elif kind == "sound":
                item["audio"], item["preview"] = asset, None
            elif kind in ("png", "svg"):
                pass  # the page shows these directly
            elif not item.get("preview"):
                item["note"] = f"no preview for kind {kind}"
    (out / "inventory.json").write_text(json.dumps(inv, indent=1), encoding="utf-8")
    return inv


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[0], file=sys.stderr)
        sys.exit(2)
    result = run(sys.argv[1])
    noted = [i for g in result["groups"] for i in g["items"] if i.get("note")]
    print(f"previews done; {len(noted)} items carry a note")
    for i in noted[:10]:
        print("note:", i["id"], "-", i["note"])
