# SPDX-License-Identifier: GPL-2.0-or-later
"""N-403: the nisse "n" with a hat. The mark is Nunito's n (the wordmark's own letterform) with the logo's HAT standing
upright on its left stem, the same recipe as the hat on the dotless i of the wordmark."""
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))

import build_n  # noqa: E402

PALETTE = json.loads((ROOT / "assets" / "palette" / "ember.json").read_text(encoding="ascii"))
EXTRA = {"#000000", "#ffffff"}   # the black and white colorways every logo form already ships
NAMES = ["nisse-n", "nisse-n-reverse", "nisse-n-black", "nisse-n-white", "nisse-n-symbolic",
         "nisse-n-tile", "nisse-n-tile-ember"]


def palette_hexes():
    out = set(EXTRA)
    for group in ("dark", "light"):
        for entry in PALETTE[group].values():
            out.add(entry["hex"].lower())
    return out


def test_the_forms_exist():
    assert sorted(build_n.build_forms()) == sorted(NAMES)


def test_every_svg_is_ascii_with_a_licence_header_a_view_box_and_a_lowercase_title():
    for name, svg in build_n.build_forms().items():
        svg.encode("ascii")
        assert "SPDX-License-Identifier: GPL-2.0-or-later" in svg, name
        assert re.search(r'viewBox="0 0 512 512"', svg), name
        titles = re.findall(r"<title>(.*?)</title>", svg)
        assert titles and all("Nisse" not in t for t in titles), (name, titles)


def test_the_hat_is_the_logos_hat_exactly():
    spec = importlib.util.spec_from_file_location("nisse_logo_build", ROOT / "tools" / "logo" / "build.py")
    logo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(logo)
    for name, svg in build_n.build_forms().items():
        assert logo.HAT in svg, (name, "the logo HAT markup is not in this form")


def test_the_hat_stands_on_the_left_stem_like_the_hat_on_the_dotless_i():
    g = build_n.geometry()
    assert abs(g["hat_cx"] - g["stem_cx"]) < 0.5, g
    assert g["hat_bottom"] <= g["x_height_top"], "the hat must sit above the letter, not inside it"
    assert g["hat_bottom"] > g["x_height_top"] - 0.1 * g["x_height"], "the hat must nearly touch the stem, as on the i"


def test_the_mark_fits_the_square_with_room_and_is_centered():
    g = build_n.geometry()
    assert g["fit_left"] >= 40 and g["fit_top"] >= 40, g
    assert g["fit_right"] <= 512 - 40 and g["fit_bottom"] <= 512 - 40, g
    assert abs((g["fit_left"] + g["fit_right"]) / 2 - 256) < 1.0, g


def test_colors_come_from_the_palette_and_the_known_colorways_and_there_are_no_gradients():
    allowed = palette_hexes()
    for name, svg in build_n.build_forms().items():
        used = {h.lower() for h in re.findall(r"#[0-9a-fA-F]{6}\b", svg)}
        assert used <= allowed, (name, sorted(used - allowed))
        assert "Gradient" not in svg and "filter" not in svg, name


def test_symbolic_inherits_the_text_color_and_the_tiles_are_ink_squares():
    forms = build_n.build_forms()
    assert "currentColor" in forms["nisse-n-symbolic"]
    for name in ("nisse-n-tile", "nisse-n-tile-ember"):
        assert 'fill="#1b2330"' in forms[name] and 'rx="112"' in forms[name], name
    assert 'fill="#e0623f"' in forms["nisse-n-tile-ember"] and 'fill="#e0623f"' not in forms["nisse-n-tile"]


def test_the_mark_is_legible_at_the_small_sizes():
    # render the tile and look for ink in the hat band and in the letter band at 16 and 22 px
    from playwright.sync_api import sync_playwright
    import base64
    import io

    from PIL import Image
    svg = build_n.build_forms()["nisse-n-tile"]
    uri = "data:image/svg+xml;base64," + base64.b64encode(svg.encode("ascii")).decode()
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        for px in (16, 22):
            pg.set_viewport_size({"width": px, "height": px})
            pg.set_content(f'<html><body style="margin:0"><img src="{uri}" width="{px}" height="{px}" style="display:block"></body></html>')
            pg.wait_for_function("document.images[0].complete")
            im = Image.open(io.BytesIO(pg.screenshot(clip={"x": 0, "y": 0, "width": px, "height": px}))).convert("L")
            top = [im.getpixel((x, y)) for y in range(px // 5, px // 2) for x in range(px)]
            low = [im.getpixel((x, y)) for y in range(px // 2, px - px // 5) for x in range(px)]
            tile_bg = im.getpixel((px // 2, 0))
            assert max(abs(v - tile_bg) for v in top) > 60, (px, "no hat ink in the upper half")
            assert max(abs(v - tile_bg) for v in low) > 60, (px, "no letter ink in the lower half")
        b.close()


# ---------------------------------------------------------------- variants (Bert: "hat placement or letter read")
VARIANT_NAMES = ["stem", "centered", "right", "tipped", "tipped-centered"]


def test_the_variants_exist_and_are_all_different():
    forms = build_n.build_variants()
    assert sorted(forms) == sorted(VARIANT_NAMES)
    assert len(set(forms.values())) == len(forms)


def test_every_variant_uses_the_logos_exact_hat_and_fits_the_square():
    spec = importlib.util.spec_from_file_location("nisse_logo_build", ROOT / "tools" / "logo" / "build.py")
    logo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(logo)
    for name, svg in build_n.build_variants().items():
        svg.encode("ascii")
        assert logo.HAT in svg, name
        g = build_n.geometry(name)
        assert g["fit_left"] >= 40 and g["fit_top"] >= 40, (name, g)
        assert g["fit_right"] <= 512 - 40 and g["fit_bottom"] <= 512 - 40, (name, g)
        assert abs((g["fit_left"] + g["fit_right"]) / 2 - 256) < 1.0, (name, g)


def test_the_hat_anchors_are_where_the_names_say():
    left = build_n.geometry("stem")
    assert abs(left["hat_cx"] - left["stem_cx"]) < 0.5
    center = build_n.geometry("centered")
    assert abs(center["hat_cx"] - center["n_cx"]) < 0.5
    right = build_n.geometry("right")
    assert abs(right["hat_cx"] - right["right_stem_cx"]) < 0.5
    assert build_n.geometry("tipped")["tilt"] != 0 and build_n.geometry("tipped-centered")["tilt"] != 0
    assert build_n.geometry("stem")["tilt"] == 0 and build_n.geometry("centered")["tilt"] == 0


def test_every_variant_is_legible_at_the_small_sizes():
    from playwright.sync_api import sync_playwright
    import base64
    import io

    from PIL import Image
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        for name in VARIANT_NAMES:
            svg = build_n.build_variants(tiles=True)[name]
            uri = "data:image/svg+xml;base64," + base64.b64encode(svg.encode("ascii")).decode()
            for px in (16, 22):
                pg.set_viewport_size({"width": px, "height": px})
                pg.set_content(f'<html><body style="margin:0"><img src="{uri}" width="{px}" height="{px}" style="display:block"></body></html>')
                pg.wait_for_function("document.images[0].complete")
                im = Image.open(io.BytesIO(pg.screenshot(clip={"x": 0, "y": 0, "width": px, "height": px}))).convert("L")
                bg = im.getpixel((px // 2, 0))
                top = [im.getpixel((x, y)) for y in range(px // 5, px // 2) for x in range(px)]
                low = [im.getpixel((x, y)) for y in range(px // 2, px - px // 5) for x in range(px)]
                assert max(abs(v - bg) for v in top) > 60, (name, px, "no ink in the upper half")
                assert max(abs(v - bg) for v in low) > 60, (name, px, "no ink in the lower half")
        b.close()
