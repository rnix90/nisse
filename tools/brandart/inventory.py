#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Brand art inventory: find every graphic of an image that belongs to its identity or desktop theme.

Two steps, because the image can only be mounted in the build VM and the previews are easier to make on the host:

    inventory.py stage ROOT --out STAGE --rpmdb DB     (in the VM)  copy the selected files into STAGE (same relative
                                                                    paths) and write STAGE/owners.json with the owning
                                                                    package and license of each
    inventory.py build ROOT --out DIR [--owners FILE]  (anywhere)   read the selected files below ROOT (a staged tree
                                                                    or a real image root) and write DIR/inventory.json
                                                                    plus DIR/assets/ (viewable copies)

What counts as "every graphic" is tools/brandart/surfaces.toml (see its header). Item ids are stable slugs so that
comments written on the review page stay attached when the inventory is rebuilt after a new ISO.

Standard library only (tomllib needs Python 3.11).
"""
import argparse
import glob
import gzip
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tomllib
import wave
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
RASTER = {".png", ".jpg", ".jpeg", ".webp"}
SOUNDS = {".oga", ".ogg", ".wav", ".flac"}
ICON_SIZES = ("48", "64", "32", "24", "22", "16")
ICON_CATEGORIES = ("apps", "places", "actions", "preferences", "status", "devices", "mimetypes", "categories", "emblems", "emotes")
MAX_MISSING_ICONS = 0.30
MIN_NAMES_FOR_CHECK = 10  # a short list says nothing about whether this is the right image


class SurfaceError(Exception):
    """The surface list does not match the image."""


# ---------------------------------------------------------------- surface list

def load_surfaces(path):
    data = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    groups = data.get("group", [])
    seen = set()
    for g in groups:
        for key in ("id", "title", "seen"):
            if not g.get(key):
                raise SurfaceError(f"a group has no {key!r}: {g}")
        if g["id"] in seen:
            raise SurfaceError(f"duplicate group id {g['id']!r}")
        seen.add(g["id"])
    return groups


# ---------------------------------------------------------------- reading file facts

def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "item"


def kind_of(path, forced=None):
    if forced:
        return forced
    ext = Path(path).suffix.lower()
    if ext in RASTER:
        return "png"  # "png" stands for every raster image (png, jpg, webp)
    if ext in (".svg", ".svgz"):
        return "svg"
    if ext == ".colors":
        return "colors"
    if ext in SOUNDS:
        return "sound"
    if ext == ".icns":
        return "icns"
    return "file"


def read_bytes(path):
    data = Path(path).read_bytes()
    if str(path).endswith(".svgz") or data[:2] == b"\x1f\x8b":
        try:
            data = gzip.decompress(data)
        except OSError:
            pass
    return data


def png_size(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return struct.unpack(">II", data[16:24])
    return None


def jpeg_size(data):
    if data[:2] != b"\xff\xd8":
        return None
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + length
    return None


def number(text):
    m = re.match(r"\s*([0-9.]+)", text or "")
    return round(float(m.group(1))) if m else None


def svg_facts(data):
    """(width, height, element ids) of an SVG document; (None, None, []) when it cannot be parsed."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return None, None, []
    w, h = number(root.get("width")), number(root.get("height"))
    if (w is None or h is None) and root.get("viewBox"):
        parts = re.split(r"[ ,]+", root.get("viewBox").strip())
        if len(parts) == 4:
            w, h = w or number(parts[2]), h or number(parts[3])
    ids = [e.get("id") for e in root.iter() if e.get("id")]
    return w, h, ids[:400]


def audio_duration(path):
    path = str(path)
    try:
        if path.endswith(".wav"):
            with wave.open(path, "rb") as w:
                return round(w.getnframes() / w.getframerate(), 3)
        if path.endswith((".oga", ".ogg")):
            data = Path(path).read_bytes()
            ident = data.find(b"\x01vorbis")
            last = data.rfind(b"OggS")
            if ident >= 0 and last >= 0:
                rate = struct.unpack("<I", data[ident + 12:ident + 16])[0]
                granule = struct.unpack("<q", data[last + 6:last + 14])[0]
                if rate and granule > 0:
                    return round(granule / rate, 3)
    except (OSError, ValueError, struct.error, wave.Error, EOFError):
        pass
    return None


def facts(path, kind):
    """width, height, extra fields for one file."""
    out = {"width": None, "height": None}
    data = None
    if kind == "png":
        data = Path(path).read_bytes()[:65536] if Path(path).suffix.lower() == ".png" else Path(path).read_bytes()
        size = png_size(data) or jpeg_size(data)
        if size:
            out["width"], out["height"] = size
    elif kind == "svg":
        w, h, ids = svg_facts(read_bytes(path))
        out["width"], out["height"] = w, h
        out["elements"] = ids
    elif kind == "sound":
        out["duration"] = audio_duration(path)
    return out


# ---------------------------------------------------------------- selecting files

def expand(root, pattern):
    """Relative posix paths of the files below `root` matching `pattern`, sorted."""
    found = glob.glob(os.path.join(str(root), pattern), recursive=True)
    # alias symlinks (cursor and icon themes are full of them) are the same artwork, not separate items
    return sorted(Path(p).relative_to(root).as_posix() for p in found if os.path.isfile(p) and not os.path.islink(p))


def find_icon(root, name):
    """Relative path of the best file for an icon name (Breeze first, then hicolor), or None."""
    for cat in ICON_CATEGORIES:
        for size in ICON_SIZES:
            rel = f"usr/share/icons/breeze/{cat}/{size}/{name}.svg"
            if os.path.isfile(os.path.join(str(root), rel)):
                return rel
    for rel in (f"usr/share/icons/hicolor/scalable/apps/{name}.svg",):
        if os.path.isfile(os.path.join(str(root), rel)):
            return rel
    for size in ("256x256", "128x128", "64x64", "48x48", "32x32", "24x24", "22x22", "16x16"):
        rel = f"usr/share/icons/hicolor/{size}/apps/{name}.png"
        if os.path.isfile(os.path.join(str(root), rel)):
            return rel
    return None


def area_or_size(root, rel):
    p = os.path.join(str(root), rel)
    f = facts(p, kind_of(rel))
    if f["width"] and f["height"]:
        return f["width"] * f["height"]
    return os.path.getsize(p)


def select(root, group, notes, base=HERE):
    """Entries for one group: [{key, title, files: [rel...], preview: rel}] in surface-list order. Raises SurfaceError."""
    entries = []
    if group.get("icon_list"):
        names = [ln.strip() for ln in (Path(base) / group["icon_list"]).read_text(encoding="utf-8").splitlines()
                 if ln.strip() and not ln.lstrip().startswith("#")]
        missing_icons = []
        for name in names:
            rel = find_icon(root, name)
            if rel:
                entries.append({"key": name, "title": name, "files": [rel], "preview": rel})
            else:
                missing_icons.append(name)
        for name in missing_icons:
            notes.append(f"{group['id']}: icon {name} not found in the image")
        if len(names) >= MIN_NAMES_FOR_CHECK and len(missing_icons) / len(names) > MAX_MISSING_ICONS:
            raise SurfaceError(f"group {group['id']}: {len(missing_icons)} of {len(names)} icons not found; is this the right image?")

    patterns = group.get("patterns", [])
    allow_empty = bool(group.get("missing"))
    matched, order = {}, []
    for pattern in patterns:
        files = expand(root, pattern)
        if not files and not allow_empty:
            raise SurfaceError(f"group {group['id']}: pattern matches no file: {pattern}")
        for rel in files:
            if rel not in matched:
                matched[rel] = pattern
                order.append(rel)

    collapse = re.compile(group["collapse_by"]) if group.get("collapse_by") else None
    if collapse:
        buckets = {}
        for rel in order:
            m = collapse.match(rel)
            key = m.group(1) if m else rel
            buckets.setdefault(key, []).append(rel)
        for key, files in buckets.items():
            best = max(files, key=lambda r: area_or_size(root, r))
            entries.append({"key": key, "title": key.split("/")[-1], "files": [best] + [f for f in files if f != best],
                            "preview": best})
    else:
        for rel in order:
            entries.append({"key": Path(rel).stem, "title": Path(rel).stem, "files": [rel], "preview": rel})
    return entries


# ---------------------------------------------------------------- stage

def owner_of(rpm, rpmdb, path):
    cmd = [*([rpm] if isinstance(rpm, str) else rpm), "--dbpath", rpmdb, "-qf", "--qf", "%{NAME}-%{VERSION}-%{RELEASE}|%{LICENSE}\n", path]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or "|" not in r.stdout:
        return {"owner": "", "license": ""}
    owner, _, lic = r.stdout.splitlines()[0].partition("|")
    return {"owner": owner, "license": lic}


def stage(root, surfaces, stage_dir, rpmdb=None, rpm="rpm"):
    """Copy the selected files (the preview file of each entry) into `stage_dir` and record their owners."""
    root, stage_dir = Path(root), Path(stage_dir)
    notes, owners, copied = [], {}, 0
    for group in load_surfaces(surfaces):
        for entry in select(root, group, notes, Path(surfaces).parent):
            rel = entry["preview"]
            dst = stage_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / rel, dst)
            copied += 1
            path = "/" + rel
            owners[path] = owner_of(rpm, rpmdb, path) if rpmdb else {"owner": "", "license": ""}
            for other in entry["files"][1:]:
                owners.setdefault("/" + other, owner_of(rpm, rpmdb, "/" + other) if rpmdb else {"owner": "", "license": ""})
    stage_dir.mkdir(parents=True, exist_ok=True)
    (stage_dir / "owners.json").write_text(json.dumps(owners, indent=1, sort_keys=True), encoding="utf-8")
    (stage_dir / "notes.json").write_text(json.dumps(notes, indent=1), encoding="utf-8")
    return copied


# ---------------------------------------------------------------- build

def unique_id(taken, base):
    cand, n = base, 2
    while cand in taken:
        cand = f"{base}-{n}"
        n += 1
    taken.add(cand)
    return cand


def build(root, surfaces, out, owners=None, image=None):
    root, out = Path(root), Path(out)
    owner_map = json.loads(Path(owners).read_text(encoding="utf-8")) if owners else {}
    notes = []
    stage_notes = root / "notes.json"
    if stage_notes.is_file():
        notes.extend(json.loads(stage_notes.read_text(encoding="utf-8")))
    if not owners and (root / "owners.json").is_file():
        owner_map = json.loads((root / "owners.json").read_text(encoding="utf-8"))
    if out.exists():
        shutil.rmtree(out)
    (out / "assets").mkdir(parents=True)
    taken, groups = set(), []
    for group in load_surfaces(surfaces):
        gid, items = group["id"], []
        entries = select(root, group, notes, Path(surfaces).parent)
        # titles that repeat inside a group are told apart by size (or by folder when the sizes repeat too)
        counts, sizes = {}, {}
        for e in entries:
            counts[e["title"]] = counts.get(e["title"], 0) + 1
            f0 = facts(root / e["preview"], kind_of(e["preview"], group.get("kind")))
            sizes.setdefault(e["title"], []).append(f"{f0['width']}x{f0['height']}" if f0["width"] and f0["height"] else "")
        for e in entries:
            rel = e["preview"]
            kind = kind_of(rel, group.get("kind"))
            src = root / rel
            f = facts(src, kind)
            title = e["title"]
            if counts[title] > 1:
                distinct = len(set(sizes[title])) == counts[title] and "" not in sizes[title]
                title = f"{title} ({size_label(f) if distinct else Path(rel).parent.name})"
            item_id = unique_id(taken, f"{gid}/{slug(e['key'] if group.get('collapse_by') or group.get('icon_list') else title)}")
            ext = ".svg" if rel.endswith(".svgz") else Path(rel).suffix
            asset = f"assets/{item_id}{ext}"
            (out / asset).parent.mkdir(parents=True, exist_ok=True)
            if rel.endswith(".svgz"):
                (out / asset).write_bytes(read_bytes(src))
            else:
                shutil.copyfile(src, out / asset)
            path = "/" + rel
            who = owner_map.get(path, {})
            item = {
                "id": item_id, "title": title, "seen": group["seen"], "kind": kind, "source": path,
                "owner": who.get("owner", ""), "license": who.get("license", ""),
                "width": f["width"], "height": f["height"],
                "asset": asset, "preview": asset if kind in ("png", "svg") else None,
                "variants": ["/" + v for v in e["files"][1:]],
            }
            if "elements" in f:
                item["elements"] = f["elements"]
            if "duration" in f:
                item["duration"] = f["duration"]
            items.append(item)
        for req in group.get("requests", []):
            items.append(missing_item(taken, gid, req["title"], req.get("seen", group["seen"])))
        if group.get("missing") and not entries and not group.get("requests"):
            items.append(missing_item(taken, gid, f"{group['title']}: no current graphic", group["seen"]))
        groups.append({"id": gid, "title": group["title"], "seen": group["seen"], "items": items})
    inv = {"image": image or {"iso": "", "built": "", "sha256": ""}, "groups": groups, "notes": list(dict.fromkeys(notes))}
    (out / "inventory.json").write_text(json.dumps(inv, indent=1), encoding="utf-8")
    return inv


def size_label(f):
    return f"{f['width']}x{f['height']}"


def missing_item(taken, gid, title, seen):
    return {"id": unique_id(taken, f"{gid}/request-{slug(title)}"), "title": title, "seen": seen, "kind": "missing",
            "source": None, "owner": "", "license": "", "width": None, "height": None, "asset": None,
            "preview": None, "variants": []}


# ---------------------------------------------------------------- command line

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("stage", "build"):
        p = sub.add_parser(name)
        p.add_argument("root")
        p.add_argument("--out", required=True)
        p.add_argument("--surfaces", default=str(HERE / "surfaces.toml"))
        if name == "stage":
            p.add_argument("--rpmdb")
            p.add_argument("--rpm", default="rpm")
        else:
            p.add_argument("--owners")
            p.add_argument("--iso", default="")
            p.add_argument("--built", default="")
            p.add_argument("--sha256", default="")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "stage":
            n = stage(args.root, args.surfaces, args.out, rpmdb=args.rpmdb, rpm=args.rpm)
            print(f"staged {n} files into {args.out}")
        else:
            inv = build(args.root, args.surfaces, args.out, owners=args.owners,
                        image={"iso": args.iso, "built": args.built, "sha256": args.sha256})
            total = sum(len(g["items"]) for g in inv["groups"])
            print(f"{total} items in {len(inv['groups'])} groups -> {args.out}/inventory.json")
            for n in inv["notes"]:
                print("note:", n)
    except SurfaceError as e:
        print(f"inventory: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
