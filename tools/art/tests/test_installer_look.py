# SPDX-License-Identifier: GPL-2.0-or-later
"""N-411: the installer's look. The installer is the Anaconda WebUI, a Cockpit page whose colors and logo come from the branding
folder named after os-release ID (nisse has none, so it used Fedora's blue). These tests check the generated branding folder:
palette colors only, the contrast pairs the palette promises, a header rule that beats the installer's own, and the logo files."""
import io
import json
import re
import sys
from pathlib import Path

import pytest
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE.parents[1] / "palette"))

import contrast  # noqa: E402
import installer_look  # noqa: E402

ROOT = HERE.parents[2]
PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
CSS = installer_look.css(PALETTE)


def palette_hexes():
    return {e["hex"].lower() for g in ("dark", "light") for e in PALETTE[g].values()}


def block(selector):
    """The declarations of the first rule whose selector is exactly `selector`, as {property: value}."""
    m = re.search(re.escape(selector) + r"\s*\{(.*?)\n\}", CSS, re.S)
    assert m, f"no rule for {selector}"
    return dict(re.findall(r"(--[a-z0-9-]+):\s*([^;]+);", m.group(1)))


DARK = block(":root.pf-v6-theme-dark")
LIGHT = block(":root:not(.pf-v6-theme-dark)")


def pal(dotted):
    return contrast.token(PALETTE, dotted)


def test_the_branding_folder_is_named_after_the_os_release_id():
    assert installer_look.BRAND_DIR == "nisse"
    spec = (ROOT / "packaging" / "rpm" / "nisse-release" / "nisse-release.spec").read_text(encoding="ascii")
    assert "ID=nisse" in spec.splitlines()


def test_the_css_is_ascii_and_licensed():
    assert CSS.isascii()
    assert CSS.startswith("/* SPDX-License-Identifier: GPL-2.0-or-later")


def test_every_color_is_a_palette_color():
    mixed = re.findall(r"color-mix\(in srgb, (#[0-9a-fA-F]{6}) \d+%, (#[0-9a-fA-F]{6})\)", CSS)
    flat = re.sub(r"color-mix\([^)]*\)", "", CSS)
    for h in re.findall(r"#[0-9a-fA-F]{6}\b", flat) + [c for pair in mixed for c in pair]:
        assert h.lower() in palette_hexes(), f"{h} is not an Ember palette color"


def test_no_color_literal_is_a_bare_name_or_rgb():
    code = re.sub(r"/\*.*?\*/", "", CSS, flags=re.S)   # comments may say "white"
    assert not re.search(r"\brgba?\(|\bhsla?\(|\bwhite\b|\bblack\b", code)


def test_dark_look_uses_the_dark_palette_tokens():
    assert DARK["--pf-t--global--color--brand--default"].lower() == pal("dark.accent").lower()
    assert DARK["--pf-t--global--color--brand--hover"].lower() == pal("dark.accent-hover").lower()
    assert DARK["--pf-t--global--color--brand--clicked"].lower() == pal("dark.accent-pressed").lower()
    assert DARK["--pf-t--global--background--color--primary--default"].lower() == pal("dark.base").lower()
    assert DARK["--pf-t--global--background--color--secondary--default"].lower() == pal("dark.surface").lower()
    assert DARK["--pf-t--global--background--color--control--default"].lower() == pal("dark.surface-2").lower()
    assert DARK["--pf-t--global--text--color--regular"].lower() == pal("dark.text").lower()
    assert DARK["--pf-t--global--text--color--subtle"].lower() == pal("dark.text-muted").lower()
    assert DARK["--pf-t--global--text--color--link--default"].lower() == pal("dark.accent-text").lower()
    assert DARK["--pf-t--global--border--color--default"].lower() == pal("dark.outline").lower()


def test_light_look_uses_the_light_palette_tokens():
    assert LIGHT["--pf-t--global--color--brand--default"].lower() == pal("light.accent").lower()
    assert LIGHT["--pf-t--global--background--color--primary--default"].lower() == pal("light.page").lower()
    assert LIGHT["--pf-t--global--background--color--secondary--default"].lower() == pal("light.paper").lower()
    assert LIGHT["--pf-t--global--text--color--regular"].lower() == pal("light.text").lower()
    assert LIGHT["--pf-t--global--text--color--subtle"].lower() == pal("light.text-muted").lower()
    assert LIGHT["--pf-t--global--text--color--link--default"].lower() == pal("light.accent").lower()
    assert LIGHT["--pf-t--global--border--color--default"].lower() == pal("light.outline").lower()


def test_a_fill_carries_the_text_the_palette_says():
    """Paper on Ember is only 3.1:1, so an Ember fill carries Ink (dark look); the light look's darker accent carries Paper."""
    for tok in ("default", "hover", "clicked"):
        assert DARK[f"--pf-t--global--text--color--on-brand--{tok}"].lower() == pal("dark.on-accent").lower()
        assert LIGHT[f"--pf-t--global--text--color--on-brand--{tok}"].lower() == pal("light.on-accent").lower()
    assert DARK["--nisse-header-text"].lower() == pal("dark.on-accent").lower()
    assert LIGHT["--nisse-header-text"].lower() == pal("light.on-accent").lower()


@pytest.mark.parametrize("fg,bg,minimum", [
    ("dark.on-accent", "dark.accent", 4.5), ("dark.on-accent", "dark.accent-hover", 4.5),
    ("dark.text", "dark.base", 4.5), ("dark.text", "dark.surface", 4.5), ("dark.text", "dark.surface-2", 4.5),
    ("dark.text-muted", "dark.base", 4.5), ("dark.accent-text", "dark.base", 4.5), ("dark.accent-text", "dark.surface-2", 4.5),
    ("dark.outline", "dark.base", 3.0),
    ("light.on-accent", "light.accent", 4.5), ("light.text", "light.page", 4.5), ("light.text", "light.paper", 4.5),
    ("light.text-muted", "light.page", 4.5), ("light.accent", "light.page", 4.5), ("light.outline", "light.page", 3.0),
])
def test_the_pairs_the_installer_uses_meet_the_palette_contrast(fg, bg, minimum):
    assert contrast.ratio(pal(fg), pal(bg)) >= minimum


def mix_value(value):
    """A palette color or a color-mix of two palette colors, as a hex."""
    m = re.fullmatch(r"color-mix\(in srgb, (#[0-9a-fA-F]{6}) (\d+)%, (#[0-9a-fA-F]{6})\)", value.strip())
    if not m:
        return value.strip().lower()
    a, pct, b = m.group(1), int(m.group(2)), m.group(3)
    return "#" + "".join(f"{round(int(a[i:i + 2], 16) * pct / 100 + int(b[i:i + 2], 16) * (100 - pct) / 100):02x}" for i in (1, 3, 5))


def test_the_header_text_is_readable_on_both_ends_of_the_gradient_in_both_looks():
    """The header text sits on the whole radial gradient: both ends must meet 4.5:1 with it."""
    dark_ends = block(".anaconda")
    for key in ("--brand-default-light", "--brand-default"):
        assert contrast.ratio(pal("dark.on-accent"), mix_value(dark_ends[key])) >= 4.5, key
    light_ends = block(":root:not(.pf-v6-theme-dark) .anaconda")
    for key in ("--brand-default-light", "--brand-default"):
        end = mix_value(light_ends[key])
        assert contrast.ratio(pal("light.on-accent"), end) >= 4.5, f"{key} {end} is too light for Paper header text"


def test_the_header_rule_beats_the_installers_own():
    """The installer's rule is `.pf-v6-c-page__main-group > .pf-v6-c-page__main-section:first-child` (specificity 0,3,0); ours
    starts with :root, so it is 0,4,0 and wins whatever the load order."""
    assert re.search(r"^:root \.pf-v6-c-page__main-group > \.pf-v6-c-page__main-section:first-child \{", CSS, re.M)
    assert "var(--nisse-header-text)" in CSS


def test_the_logo_is_shown_as_the_finished_tile_not_the_installers_white_glyph():
    m = re.search(r"\.anaconda \{.*?\.logo \{(.*?)\}", CSS, re.S)
    assert m
    assert "filter: none" in m.group(1) and "mix-blend-mode: normal" in m.group(1)
    assert 'url("logo.png")' in m.group(1)


def test_the_page_tokens_are_set_on_the_root_so_they_reach_the_page_background():
    """Set on .anaconda they did not reach the page and sidebar backgrounds (found in the live installer, N-411)."""
    m = re.search(r"^\.anaconda \{(.*?)^\}", CSS, re.S | re.M)
    assert m
    assert "--pf-t--" not in m.group(1)
    assert "--pf-t--global--background--color--primary--default" in DARK


def test_the_logo_is_a_128_pixel_tile():
    img = Image.open(io.BytesIO(installer_look.logo_png()))
    assert img.size == (128, 128) and img.mode == "RGBA"
    # the corner is transparent (a rounded tile) and the middle is not
    assert img.getpixel((0, 0))[3] == 0
    assert img.getpixel((64, 100))[3] == 255


def test_the_touch_icon_is_180_and_the_favicon_has_three_sizes():
    touch = Image.open(io.BytesIO(installer_look.apple_touch_png()))
    assert touch.size == (180, 180)
    ico = Image.open(io.BytesIO(installer_look.favicon_ico()))
    assert ico.format == "ICO"
    assert {(16, 16), (32, 32), (48, 48)} <= set(ico.info["sizes"])


def test_write_makes_the_four_files_and_is_deterministic(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    installer_look.write(a)
    installer_look.write(b)
    folder = Path("usr/share/cockpit/branding") / installer_look.BRAND_DIR
    for name in installer_look.FILES:
        assert (a / folder / name).read_bytes() == (b / folder / name).read_bytes()
        assert (a / folder / name).stat().st_size > 0
    assert sorted(p.name for p in (a / folder).iterdir()) == sorted(installer_look.FILES)


def test_the_name_is_lowercase_in_everything_printed():
    CAPITAL = "N" + "isse"  # in two parts so the lowercase-name scan does not flag this test
    assert CAPITAL not in CSS
