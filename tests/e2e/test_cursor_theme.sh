#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-408: libXcursor itself finds the nisse cursors in the built image, and falls back to Breeze for every other pointer.
# Run in the Fedora build VM (libXcursor and python3 present) against an ISO:  tests/e2e/test_cursor_theme.sh out/nisse-live.iso
set -euo pipefail
iso="${1:?usage: test_cursor_theme.sh ISO}"
fail() { echo "FAIL: $*" >&2; exit 1; }
work="$(mktemp -d)"
cleanup() { sudo umount "$work/root" 2>/dev/null || true; sudo umount "$work/iso" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/iso" "$work/root"
sudo mount -o loop,ro "$iso" "$work/iso"
sudo mount -o loop,ro "$work/iso/LiveOS/squashfs.img" "$work/root"
icons="$work/root/usr/share/icons"
[ -d "$icons/nisse_cursors" ] || fail "the nisse_cursors theme is not in the image"
XCURSOR_PATH="$icons" python3 - <<'PY'
import ctypes, ctypes.util

lib = ctypes.CDLL(ctypes.util.find_library("Xcursor") or "libXcursor.so.1")

class Image(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("size", ctypes.c_uint32), ("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
                ("xhot", ctypes.c_uint32), ("yhot", ctypes.c_uint32), ("delay", ctypes.c_uint32), ("pixels", ctypes.POINTER(ctypes.c_uint32))]

class Images(ctypes.Structure):
    _fields_ = [("nimage", ctypes.c_int), ("images", ctypes.POINTER(ctypes.POINTER(Image))), ("name", ctypes.c_char_p)]

lib.XcursorLibraryLoadImages.restype = ctypes.POINTER(Images)
lib.XcursorLibraryLoadImages.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]

def load(name, size=32):
    got = lib.XcursorLibraryLoadImages(name.encode(), b"nisse_cursors", size)
    assert got, f"libXcursor found no {name} in nisse_cursors"
    img = got.contents.images[0].contents
    return img.width, img.height, img.pixels[(img.height // 2) * img.width + img.width // 2], img.pixels[0]

for name, letter_hint in (("x-cursor", "X"), ("wayland-cursor", "W")):
    w, h, centre, corner = load(name)
    assert w == h and w > 0, (name, w, h)                                   # a square picture of some size
    assert corner >> 24 == 0, f"{name}: the corner must be transparent (round badge)"
    assert centre >> 24 == 255, f"{name}: the centre must be solid"
print("ok   libXcursor loads x-cursor and wayland-cursor from nisse_cursors")
# a pointer the theme does NOT carry falls through to Breeze (Inherits=breeze_cursors)
w, h, centre, corner = load("left_ptr")
assert w > 0 and h > 0
print("ok   left_ptr falls through to breeze_cursors")
PY
echo "PASS: cursor theme"
