# SPDX-License-Identifier: GPL-2.0-or-later
"""Screenshot comparison for the regression harness (ledger N-113).

A pixel counts as changed when its largest colour-channel difference is above `threshold`. A screen passes when the
share of changed pixels, taken over the pixels outside the masks, is at most `tolerance`. Masks cover things that change
by themselves, such as the clock. Pure Pillow, no VM needed.
"""
from dataclasses import dataclass

from PIL import Image, ImageChops

DEFAULT_THRESHOLD = 16     # per-channel difference (0-255) a pixel may move before it counts as changed
DEFAULT_TOLERANCE = 0.005  # share of pixels that may be changed before a screen fails


@dataclass
class Result:
    ok: bool
    changed: int
    total: int
    fraction: float
    size_mismatch: bool
    diff_image: Image.Image


def box_from_fractions(frac, size):
    """Turn (left, top, right, bottom) given as fractions of the image into pixel coordinates."""
    w, h = size
    return (round(frac[0] * w), round(frac[1] * h), round(frac[2] * w), round(frac[3] * h))


def crop_fraction(img, frac):
    return img.crop(box_from_fractions(frac, img.size))


def _clip(box, size):
    w, h = size
    return (max(0, box[0]), max(0, box[1]), min(w, box[2]), min(h, box[3]))


def compare(actual, golden, threshold=DEFAULT_THRESHOLD, tolerance=DEFAULT_TOLERANCE, masks=()):
    """Compare two images; masks are pixel boxes (left, top, right, bottom) left out of the comparison."""
    actual = actual.convert("RGB")
    golden = golden.convert("RGB")
    if actual.size != golden.size:
        return Result(False, 0, 0, 1.0, True, actual.copy())

    counted = Image.new("L", actual.size, 255)  # 255 = pixel takes part in the comparison
    for box in masks:
        l, t, r, b = _clip(box, actual.size)
        if r > l and b > t:
            counted.paste(0, (l, t, r, b))

    r_, g_, b_ = ImageChops.difference(actual, golden).split()
    biggest = ImageChops.lighter(ImageChops.lighter(r_, g_), b_)
    changed_mask = ImageChops.multiply(biggest.point(lambda v: 255 if v > threshold else 0), counted)

    changed = changed_mask.histogram()[255]
    total = counted.histogram()[255]
    fraction = changed / total if total else 0.0

    dim = actual.point(lambda v: int(v * 0.35))
    diff = Image.composite(Image.new("RGB", actual.size, (255, 0, 0)), dim, changed_mask)
    return Result(fraction <= tolerance, changed, total, fraction, False, diff)
