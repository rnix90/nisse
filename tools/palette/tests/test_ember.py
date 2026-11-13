# SPDX-License-Identifier: GPL-2.0-or-later
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import contrast  # noqa: E402

PAL = contrast.load()

REQUIRED_DARK = ["base", "surface", "surface-2", "divider", "outline", "text", "text-muted", "accent", "accent-hover",
                 "accent-pressed", "on-accent", "accent-text", "ok", "warn", "info", "alert", "on-ok", "on-alert"]
REQUIRED_LIGHT = ["page", "paper", "text", "text-muted", "outline", "accent", "on-accent", "ok", "warn", "info", "alert"]


def test_the_contrast_math_matches_known_values():
    assert round(contrast.ratio("#ffffff", "#000000"), 2) == 21.0
    assert contrast.ratio("#1b2330", "#1b2330") == 1.0
    assert round(contrast.ratio("#f6f2e9", "#1b2330"), 1) == 14.1  # Paper on Ink, worked out by hand earlier


def test_bert_chose_these_three_colors_and_they_must_not_drift():
    assert contrast.token(PAL, "dark.base") == "#1b2330"   # Ink
    assert contrast.token(PAL, "dark.text") == "#f6f2e9"   # Paper
    assert contrast.token(PAL, "dark.accent") == "#e0623f"  # Ember (decision 2026-11-02, approved 2026-11-12)


def test_every_required_token_exists_in_both_sets():
    assert [n for n in REQUIRED_DARK if n not in PAL["dark"]] == []
    assert [n for n in REQUIRED_LIGHT if n not in PAL["light"]] == []


def test_every_declared_pair_meets_its_minimum():
    assert contrast.check(PAL) == []


def test_pairs_never_promise_less_than_the_floor_unless_marked_decorative():
    for p in PAL["pairs"]:
        assert p["min"] >= 3.0 or p.get("decorative"), p


def test_text_pairs_promise_at_least_aa():
    for p in PAL["pairs"]:
        if p.get("kind") == "text":
            assert p["min"] >= 4.5, p


def test_the_pairs_cover_the_ones_the_desktop_uses():
    declared = {(p["fg"], p["bg"]) for p in PAL["pairs"]}
    needed = [
        ("dark.text", "dark.base"), ("dark.text", "dark.surface-2"), ("dark.text-muted", "dark.base"),
        ("dark.text-muted", "dark.surface-2"), ("dark.accent-text", "dark.base"), ("dark.on-accent", "dark.accent"),
        ("dark.on-alert", "dark.alert"), ("dark.on-ok", "dark.ok"), ("dark.outline", "dark.base"),
        ("light.text", "light.page"), ("light.text-muted", "light.page"), ("light.accent", "light.page"),
        ("light.on-accent", "light.accent"), ("light.text", "light.paper"),
    ]
    assert [n for n in needed if n not in declared] == []


def test_the_alert_red_and_the_accent_are_distinguishable_on_dark():
    # A red "needs you" badge beside the Ember accent must not read as the same thing (design 6.5 uses red and green).
    assert contrast.ratio(contrast.token(PAL, "dark.alert"), contrast.token(PAL, "dark.accent")) >= 1.0
    a, b = contrast.rgb(contrast.token(PAL, "dark.alert")), contrast.rgb(contrast.token(PAL, "dark.accent"))
    assert sum(abs(x - y) for x, y in zip(a, b)) >= 60  # colour distance, not only lightness; Bert judges it by eye in N-103


def test_the_file_is_plain_ascii():
    text = contrast.DEFAULT_FILE.read_text(encoding="utf-8")
    assert all(ord(c) < 128 for c in text)
