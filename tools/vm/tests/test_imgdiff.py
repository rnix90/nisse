# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the screenshot comparison logic (ledger N-113): tolerance, masks, size changes, the diff image."""
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import imgdiff  # noqa: E402

W, H = 200, 100
INK = (27, 35, 48)
EMBER = (224, 98, 63)


def flat(color=INK, size=(W, H)):
    return Image.new("RGB", size, color)


def with_block(img, box, color):
    out = img.copy()
    out.paste(Image.new("RGB", (box[2] - box[0], box[3] - box[1]), color), box[:2])
    return out


def test_identical_images_pass_with_nothing_changed():
    r = imgdiff.compare(flat(), flat())
    assert r.ok and r.changed == 0 and r.fraction == 0.0 and not r.size_mismatch


def test_a_colour_move_under_the_threshold_is_not_a_change():
    near = flat((INK[0] + 5, INK[1] - 5, INK[2] + 3))
    assert imgdiff.compare(flat(), near, threshold=16).ok


def test_a_colour_move_over_the_threshold_counts_every_pixel():
    far = flat((INK[0] + 40, INK[1], INK[2]))
    r = imgdiff.compare(flat(), far, threshold=16)
    assert not r.ok and r.changed == W * H and r.fraction == 1.0


def test_the_largest_channel_difference_decides_not_the_average():
    one_channel = flat((INK[0], INK[1], INK[2] + 20))
    assert not imgdiff.compare(flat(), one_channel, threshold=16).ok


def test_a_small_changed_area_inside_the_tolerance_passes():
    # 10 x 10 of a 200 x 100 image is 0.5 percent
    altered = with_block(flat(), (0, 0, 10, 10), EMBER)
    r = imgdiff.compare(flat(), altered, tolerance=0.005)
    assert r.changed == 100 and abs(r.fraction - 0.005) < 1e-9 and r.ok


def test_a_changed_area_over_the_tolerance_fails():
    altered = with_block(flat(), (0, 0, 11, 10), EMBER)
    assert not imgdiff.compare(flat(), altered, tolerance=0.005).ok


def test_a_size_change_fails_and_says_so():
    r = imgdiff.compare(flat(size=(W, H)), flat(size=(W + 1, H)))
    assert not r.ok and r.size_mismatch


def test_masked_areas_are_ignored_on_both_images():
    altered = with_block(flat(), (150, 80, 200, 100), EMBER)
    assert not imgdiff.compare(flat(), altered).ok
    r = imgdiff.compare(flat(), altered, masks=[(150, 80, 200, 100)])
    assert r.ok and r.changed == 0
    # the masked area is also left out of the pixel count the fraction is taken over
    assert r.total == W * H - 50 * 20


def test_a_mask_larger_than_the_image_is_clipped_not_an_error():
    r = imgdiff.compare(flat(), flat(), masks=[(-50, -50, 5000, 5000)])
    assert r.total == 0 and r.ok


def test_alpha_and_palette_modes_are_compared_as_rgb():
    rgba = flat().convert("RGBA")
    assert imgdiff.compare(flat(), rgba).ok
    palette = Image.new("P", (W, H), 0)
    palette.putpalette(list(INK) + [0] * (3 * 255))
    assert imgdiff.compare(palette, flat()).ok


def test_the_diff_image_marks_changed_pixels_and_dims_the_rest():
    altered = with_block(flat(), (0, 0, 20, 20), EMBER)
    r = imgdiff.compare(flat(), altered)
    d = r.diff_image
    assert d.size == (W, H)
    assert d.getpixel((5, 5)) == (255, 0, 0)
    assert d.getpixel((150, 80)) != (255, 0, 0)


def test_the_diff_image_of_a_size_mismatch_is_the_actual_image():
    a = flat(size=(W + 1, H))
    assert imgdiff.compare(a, flat()).diff_image.size == (W + 1, H)


def test_crop_takes_a_box_given_as_fractions_of_the_image():
    img = with_block(flat(), (0, 90, W, H), EMBER)
    strip = imgdiff.crop_fraction(img, (0.0, 0.9, 1.0, 1.0))
    assert strip.size == (W, 10)
    assert strip.getpixel((0, 0)) == EMBER


def test_fraction_boxes_scale_to_pixels_for_masks():
    assert imgdiff.box_from_fractions((0.5, 0.5, 1.0, 1.0), (W, H)) == (100, 50, 200, 100)
