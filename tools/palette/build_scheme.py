# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate the nisse Plasma color schemes from assets/palette/ember.json.

    python tools/palette/build_scheme.py          # writes assets/theme/color-schemes/*.colors

The files are generated output: edit the tokens or this script, never the .colors files.
"""
import sys
from pathlib import Path

import contrast

OUT_DIR = Path(__file__).resolve().parents[2] / "assets" / "theme" / "color-schemes"

# Breeze's effect and window-manager blend settings, unchanged (same numbers in Breeze Dark and Breeze Light).
EFFECTS = {
    "ColorEffects:Disabled": {
        "Color": "56,56,56", "ColorAmount": "0", "ColorEffect": "0", "ContrastAmount": "0.65", "ContrastEffect": "1",
        "IntensityAmount": "0.1", "IntensityEffect": "2",
    },
    "ColorEffects:Inactive": {
        "ChangeSelectionColor": "true", "Color": "112,111,110", "ColorAmount": "0.025", "ColorEffect": "2",
        "ContrastAmount": "0.1", "ContrastEffect": "2", "Enable": "false", "IntensityAmount": "0", "IntensityEffect": "0",
    },
}


def rgb(hex_value):
    return ",".join(str(c) for c in contrast.rgb(hex_value))


def group(bg, alt, fg):
    """One Colors:* group. fg maps the semantic names to hex values."""
    return {
        "BackgroundAlternate": rgb(alt), "BackgroundNormal": rgb(bg),
        "DecorationFocus": rgb(fg["focus"]), "DecorationHover": rgb(fg["hover"]),
        "ForegroundActive": rgb(fg["active"]), "ForegroundInactive": rgb(fg["inactive"]),
        "ForegroundLink": rgb(fg["link"]), "ForegroundNegative": rgb(fg["negative"]),
        "ForegroundNeutral": rgb(fg["neutral"]), "ForegroundNormal": rgb(fg["normal"]),
        "ForegroundPositive": rgb(fg["positive"]), "ForegroundVisited": rgb(fg["visited"]),
    }


def dark_foregrounds(d):
    return {"normal": d["text"], "inactive": d["text-muted"], "active": d["accent-text"], "link": d["accent-text"],
            "visited": d["visited"], "negative": d["alert-text"], "neutral": d["warn"], "positive": d["ok-text"],
            "focus": d["accent"], "hover": d["accent-hover"]}


def build(pal, variant):
    """Return {section: {key: value}} for 'dark' (the shell) or 'light' (document apps)."""
    d = {k: v["hex"] for k, v in pal["dark"].items()}
    lt = {k: v["hex"] for k, v in pal["light"].items()}
    dark_fg = dark_foregrounds(d)
    if variant == "dark":
        name, ident = "nisse Ember", "NisseEmber"
        fg = dark_fg
        sel_fg = {k: d["on-accent"] for k in dark_fg}
        sel_fg.update(focus=d["on-accent"], hover=d["on-accent"])
        sections = {
            "Colors:Button": group(d["surface-2"], d["surface"], fg),
            "Colors:Complementary": group(d["base"], d["surface"], dark_fg),
            "Colors:Header": group(d["surface"], d["base"], fg),
            "Colors:Header][Inactive": group(d["base"], d["surface"], fg),
            "Colors:Selection": group(d["accent"], d["accent-pressed"], sel_fg),
            "Colors:Tooltip": group(d["surface-2"], d["surface"], fg),
            "Colors:View": group(d["surface"], d["surface-2"], fg),
            "Colors:Window": group(d["base"], d["surface"], fg),
        }
        wm = {"activeBackground": d["surface"], "activeBlend": d["text"], "activeForeground": d["text"],
              "inactiveBackground": d["base"], "inactiveBlend": d["text-muted"], "inactiveForeground": d["text-muted"]}
    elif variant == "light":
        name, ident = "nisse Ember Light", "NisseEmberLight"
        fg = {"normal": lt["text"], "inactive": lt["text-muted"], "active": lt["accent"], "link": lt["accent"],
              "visited": lt["visited"], "negative": lt["alert"], "neutral": lt["warn"], "positive": lt["ok"],
              "focus": lt["accent"], "hover": lt["accent"]}
        sel_fg = {k: lt["on-accent"] for k in fg}
        sections = {
            "Colors:Button": group(lt["paper"], lt["page"], fg),
            "Colors:Complementary": group(d["base"], d["surface"], dark_fg),
            "Colors:Header": group(lt["paper"], lt["page"], fg),
            "Colors:Header][Inactive": group(lt["page"], lt["paper"], fg),
            "Colors:Selection": group(lt["accent"], lt["accent"], sel_fg),
            "Colors:Tooltip": group(lt["page"], lt["paper"], fg),
            "Colors:View": group(lt["page"], lt["paper"], fg),
            "Colors:Window": group(lt["paper"], lt["page"], fg),
        }
        wm = {"activeBackground": lt["paper"], "activeBlend": lt["paper"], "activeForeground": lt["text"],
              "inactiveBackground": lt["page"], "inactiveBlend": lt["page"], "inactiveForeground": lt["text-muted"]}
    else:
        raise ValueError(variant)
    scheme = {k: dict(v) for k, v in EFFECTS.items()}
    scheme.update({k: sections[k] for k in sorted(sections)})
    scheme["General"] = {"ColorScheme": ident, "Name": name, "shadeSortColumn": "true"}
    scheme["KDE"] = {"contrast": "4"}
    scheme["WM"] = {k: rgb(v) for k, v in wm.items()}
    return scheme


def render(scheme):
    lines = ["# SPDX-License-Identifier: GPL-2.0-or-later",
             "# Generated by tools/palette/build_scheme.py from assets/palette/ember.json. Do not edit by hand.", ""]
    for section, keys in scheme.items():
        lines.append(f"[{section}]")
        lines.extend(f"{k}={v}" for k, v in sorted(keys.items()))
        lines.append("")
    return "\n".join(lines)


def main():
    pal = contrast.load()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for variant in ("dark", "light"):
        scheme = build(pal, variant)
        path = OUT_DIR / (scheme["General"]["ColorScheme"] + ".colors")
        path.write_text(render(scheme), encoding="ascii", newline="\n")
        print("wrote", path)


if __name__ == "__main__":
    sys.exit(main())
