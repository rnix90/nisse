# SPDX-License-Identifier: GPL-2.0-or-later
import copy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import build_scheme  # noqa: E402
import contrast  # noqa: E402

PAL = contrast.load()
REPO = HERE.parents[2]
OUT = REPO / "assets" / "theme" / "color-schemes"
BREEZE = [ln for ln in (HERE / "fixtures" / "breeze-keys.txt").read_text(encoding="ascii").splitlines() if ln and not ln.startswith("#")]
DARK = build_scheme.build(PAL, "dark")
LIGHT = build_scheme.build(PAL, "light")
SETS = ["Colors:Window", "Colors:View", "Colors:Button", "Colors:Header", "Colors:Header][Inactive", "Colors:Tooltip", "Colors:Complementary"]
FG = ["ForegroundNormal", "ForegroundInactive", "ForegroundActive", "ForegroundLink", "ForegroundVisited",
      "ForegroundNegative", "ForegroundNeutral", "ForegroundPositive"]
NOT_COLORS = ("ColorScheme", "Name", "shadeSortColumn", "contrast", "Enable", "ChangeSelectionColor")


def rgb_of(hex_value):
    return ",".join(str(c) for c in contrast.rgb(hex_value))


def hexed(triple):
    return "#%02x%02x%02x" % tuple(int(x) for x in triple.split(","))


def split_key(entry):
    section, key = entry.split(" ", 1)
    return section[1:-1], key


def test_every_key_stock_breeze_dark_defines_is_present_in_both_schemes():
    for name, scheme in (("dark", DARK), ("light", LIGHT)):
        missing = [b for b in BREEZE if split_key(b)[0] not in scheme or split_key(b)[1] not in scheme[split_key(b)[0]]]
        assert missing == [], (name, missing)


def test_every_color_value_is_a_valid_rgb_triple():
    for scheme in (DARK, LIGHT):
        for section, keys in scheme.items():
            for key, value in keys.items():
                if key in NOT_COLORS or (section.startswith("ColorEffects") and key != "Color"):
                    continue
                parts = value.split(",")
                assert len(parts) == 3 and all(p.isdigit() and 0 <= int(p) <= 255 for p in parts), (section, key, value)


def test_the_dark_scheme_uses_the_tokens():
    d = {k: v["hex"] for k, v in PAL["dark"].items()}
    assert DARK["Colors:Window"]["BackgroundNormal"] == rgb_of(d["base"])
    assert DARK["Colors:Window"]["BackgroundAlternate"] == rgb_of(d["surface"])
    assert DARK["Colors:View"]["BackgroundNormal"] == rgb_of(d["surface"])
    assert DARK["Colors:Button"]["BackgroundNormal"] == rgb_of(d["surface-2"])
    assert DARK["Colors:Selection"]["BackgroundNormal"] == rgb_of(d["accent"])
    assert DARK["Colors:Selection"]["ForegroundNormal"] == rgb_of(d["on-accent"])
    for s in SETS:
        assert DARK[s]["ForegroundNormal"] == rgb_of(d["text"]), s
        assert DARK[s]["ForegroundInactive"] == rgb_of(d["text-muted"]), s
        assert DARK[s]["ForegroundLink"] == rgb_of(d["accent-text"]), s
        assert DARK[s]["ForegroundVisited"] == rgb_of(d["visited"]), s
        assert DARK[s]["ForegroundNegative"] == rgb_of(d["alert-text"]), s
        assert DARK[s]["ForegroundNeutral"] == rgb_of(d["warn"]), s
        assert DARK[s]["ForegroundPositive"] == rgb_of(d["ok-text"]), s


def test_the_light_scheme_is_for_documents_and_uses_the_light_tokens():
    lt = {k: v["hex"] for k, v in PAL["light"].items()}
    assert LIGHT["Colors:Window"]["BackgroundNormal"] == rgb_of(lt["paper"])
    assert LIGHT["Colors:View"]["BackgroundNormal"] == rgb_of(lt["page"])
    assert LIGHT["Colors:View"]["ForegroundNormal"] == rgb_of(lt["text"])
    assert LIGHT["Colors:View"]["ForegroundLink"] == rgb_of(lt["accent"])
    assert LIGHT["Colors:View"]["ForegroundVisited"] == rgb_of(lt["visited"])
    assert LIGHT["Colors:Selection"]["BackgroundNormal"] == rgb_of(lt["accent"])
    assert LIGHT["Colors:Selection"]["ForegroundNormal"] == rgb_of(lt["on-accent"])
    # the complementary group of a light scheme is a dark area, as in Breeze Light
    assert LIGHT["Colors:Complementary"]["BackgroundNormal"] == rgb_of(PAL["dark"]["base"]["hex"])


def test_text_and_status_colors_are_readable_on_every_background_of_their_set():
    for name, scheme in (("dark", DARK), ("light", LIGHT)):
        for s in SETS:
            for bg_key in ("BackgroundNormal", "BackgroundAlternate"):
                bg = hexed(scheme[s][bg_key])
                for fg_key in FG:
                    got = contrast.ratio(hexed(scheme[s][fg_key]), bg)
                    assert got >= 4.5, f"{name} {s} {fg_key} on {bg_key}: {got:.2f}"


def test_selection_text_is_readable_on_the_selection_color():
    for name, scheme in (("dark", DARK), ("light", LIGHT)):
        bg = hexed(scheme["Colors:Selection"]["BackgroundNormal"])
        for fg_key in FG:
            got = contrast.ratio(hexed(scheme["Colors:Selection"][fg_key]), bg)
            assert got >= 4.5, f"{name} Selection {fg_key}: {got:.2f}"


def test_window_manager_colors_follow_the_tokens():
    d = {k: v["hex"] for k, v in PAL["dark"].items()}
    assert DARK["WM"]["activeBackground"] == rgb_of(d["surface"])
    assert DARK["WM"]["activeForeground"] == rgb_of(d["text"])
    assert DARK["WM"]["inactiveBackground"] == rgb_of(d["base"])
    assert DARK["WM"]["inactiveForeground"] == rgb_of(d["text-muted"])
    assert contrast.ratio(hexed(DARK["WM"]["activeForeground"]), hexed(DARK["WM"]["activeBackground"])) >= 4.5
    assert contrast.ratio(hexed(DARK["WM"]["inactiveForeground"]), hexed(DARK["WM"]["inactiveBackground"])) >= 4.5


def test_names_and_identity():
    assert DARK["General"]["ColorScheme"] == "NisseEmber" and DARK["General"]["Name"] == "Nisse Ember"
    assert LIGHT["General"]["ColorScheme"] == "NisseEmberLight" and LIGHT["General"]["Name"] == "Nisse Ember Light"


def test_rendering_is_deterministic_and_plain_ascii_with_an_spdx_header():
    a, b = build_scheme.render(DARK), build_scheme.render(build_scheme.build(PAL, "dark"))
    assert a == b
    assert a.startswith("# SPDX-License-Identifier: GPL-2.0-or-later")
    assert all(ord(c) < 128 for c in a)


def test_the_committed_files_match_the_generator():
    assert (OUT / "NisseEmber.colors").read_text(encoding="ascii") == build_scheme.render(DARK)
    assert (OUT / "NisseEmberLight.colors").read_text(encoding="ascii") == build_scheme.render(LIGHT)


def test_a_worse_token_is_caught_by_the_readability_check():
    # mutation check: with a muted text that is too dark, a dark-scheme pair falls below 4.5
    bad = copy.deepcopy(PAL)
    bad["dark"]["text-muted"]["hex"] = "#555d6b"
    scheme = build_scheme.build(bad, "dark")
    assert contrast.ratio(hexed(scheme["Colors:Window"]["ForegroundInactive"]), hexed(scheme["Colors:Window"]["BackgroundNormal"])) < 4.5
