# SPDX-License-Identifier: GPL-2.0-or-later
"""WCAG 2.x contrast helpers for the Nisse palette tokens."""
import json
import re
from pathlib import Path

HEX = re.compile(r"^#[0-9a-f]{6}$")
DEFAULT_FILE = Path(__file__).resolve().parents[2] / "assets" / "palette" / "ember.json"


def rgb(hex_color):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def luminance(hex_color):
    def lin(c):
        c = c / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in rgb(hex_color))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(fg, bg):
    hi, lo = sorted((luminance(fg), luminance(bg)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def load(path=DEFAULT_FILE):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def token(palette, dotted):
    """Resolve 'dark.base' to its hex value; raises KeyError for an unknown token."""
    group, name = dotted.split(".", 1)
    return palette[group][name]["hex"]


def check(palette):
    """Return a list of problems; an empty list means every declared pair meets its minimum."""
    problems = []
    for group in ("dark", "light", "terminal"):
        for name, t in palette.get(group, {}).items():
            if not HEX.match(t["hex"]):
                problems.append(f"{group}.{name}: {t['hex']!r} is not a lowercase #rrggbb value")
    for p in palette["pairs"]:
        try:
            fg, bg = token(palette, p["fg"]), token(palette, p["bg"])
        except KeyError as e:
            problems.append(f"pair {p['fg']} on {p['bg']}: unknown token {e}")
            continue
        got = ratio(fg, bg)
        if got + 1e-9 < p["min"]:
            problems.append(f"{p['fg']} on {p['bg']} ({p['use']}): {got:.2f} is below {p['min']}")
    return problems


if __name__ == "__main__":
    import sys
    found = check(load(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_FILE))
    print("\n".join(found) if found else "palette: ok")
    sys.exit(1 if found else 0)
