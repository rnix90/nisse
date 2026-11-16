#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-406: the nisse activity avatars, the gnome of assets/art/STYLE.md doing an activity (the starter set).

KDE ships a set of user pictures of its dragon mascot doing activities (an artist, a bookworm, a hacker ...). Bert's
group note on the brand submission: every dragon image keeps the same activity theme but with the cartoon gnome. This is
the first eight: the plain gnome and seven activities. Each is the style-guide gnome (the logo's exact hat, the face, the
round beard-body) standing with one flat prop, on the round Surface disc of the head badge, as a 512 unit drawing that is
rendered to the 600 pixel PNG the user-picture list wants (the Konqi pictures are 600 to 651 pixels).

Colors: the six of the style guide plus one for props (the metal and glass, steel), so seven at most, all Ember palette
tokens, flat shapes, no gradients, no hill (the disc is the only background).

    python tools/art/avatars.py            writes assets/art/avatars/{svg,png}/*, sheet.png
"""
import base64
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mascot_final import HAND_L, HAND_R, FEET, doc, master_art  # noqa: E402
from mascot_options import EMBER, EMBER_P, EMBER_T, INK, MUTED, PAPER, SURF  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "art" / "avatars"
COLOR_BUDGET = 7
SCALE = 0.9            # the 400 x 600 figure canvas into the 512 disc
PX = 600               # the rendered PNG size
LF = chr(10)           # written files use Unix line ends


def hand(x, y, r=15):
    return f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{EMBER_T}"/>'


def line(x1, y1, x2, y2, w, color):
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{w}" stroke-linecap="round"/>')


def rect(x, y, w, h, rx, fill, extra=""):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{extra}/>'


def circle(x, y, r, fill):
    return f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}"/>'


def prop(name, body):
    return f'<g id="prop-{name}">{body}</g>'


# ---- the props: (behind the hands, in front of the body) and where the hands go
def artist():
    palette = (f'<g transform="rotate(-18 84 466)">'
               f'<ellipse cx="84" cy="466" rx="54" ry="38" fill="{PAPER}"/>'
               f'{circle(104, 482, 9, SURF)}{circle(54, 452, 9, EMBER)}{circle(82, 440, 9, MUTED)}{circle(112, 446, 9, EMBER_P)}</g>')
    brush = (line(292, 470, 346, 404, 12, EMBER_P) + line(346, 404, 355, 393, 12, MUTED) + line(355, 393, 368, 377, 12, EMBER))
    return prop("artist", palette + brush), [(106, 486), (298, 462)]


def bookworm():
    book = (rect(112, 452, 176, 78, 10, EMBER_P) + rect(120, 446, 76, 70, 6, PAPER) + rect(204, 446, 76, 70, 6, PAPER)
            + "".join(line(130, y, 184, y, 5, MUTED) for y in (462, 477, 492))
            + "".join(line(214, y, 268, y, 5, MUTED) for y in (462, 477, 492)))
    return prop("bookworm", book), [(110, 520), (290, 520)]


def hacker():
    keyboard = rect(128, 484, 144, 38, 9, MUTED) + "".join(circle(146 + 20 * i, y, 4, INK) for y in (496, 510) for i in range(7))
    window = (rect(8, 246, 124, 92, 12, MUTED) + rect(16, 262, 108, 68, 6, INK)
              + f'<polyline points="30,278 46,292 30,306" fill="none" stroke="{PAPER}" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>'
              + line(58, 308, 90, 308, 7, EMBER))
    return prop("hacker", window + keyboard), [(150, 492), (250, 492)]


def musician():
    body = (circle(170, 490, 46, EMBER_P) + circle(208, 452, 32, EMBER_P) + circle(178, 488, 14, INK) + circle(178, 488, 6, SURF))
    neck = line(216, 446, 330, 356, 14, EMBER_P) + line(330, 356, 346, 343, 22, INK)
    notes = "".join(circle(x, y, 8, PAPER) + line(x + 8, y, x + 8, y - 34, 5, PAPER) + line(x + 8, y - 34, x + 22, y - 26, 5, PAPER)
                    for x, y in ((38, 392), (84, 352)))
    return prop("musician", notes + body + neck), [(272, 396), (200, 494)]


def scientist():
    flask = (f'<g transform="translate(310 470) scale(1.25) translate(-310 -470)"><path d="M300 378 H320 V410 L348 464 Q354 478 340 478 H280 Q266 478 272 464 L300 410 Z" fill="{MUTED}"/>'
             f'<path d="M291 436 H329 L348 464 Q354 478 340 478 H280 Q266 478 272 464 Z" fill="{EMBER}"/>'
             + circle(326, 360, 7, PAPER) + circle(300, 346, 5, PAPER) + circle(318, 334, 4, PAPER) + "</g>")
    return prop("scientist", flask), [(310, 380), HAND_L]


def teacher():
    board = (rect(4, 282, 110, 106, 10, EMBER_P) + rect(12, 290, 94, 90, 5, INK)
             + "".join(rect(x, 376 - h, 16, h, 3, PAPER) for x, h in ((24, 22), (50, 42), (76, 62)))
             + line(24, 306, 90, 300, 5, EMBER))
    pointer = line(114, 472, 40, 398, 8, EMBER_P) + circle(40, 398, 7, EMBER)
    return prop("teacher", board + pointer), [(114, 474), HAND_R]


def mechanic():
    wrench = (line(298, 484, 348, 398, 16, MUTED) + circle(352, 390, 23, MUTED) + circle(298, 488, 15, MUTED) + circle(298, 488, 6, SURF)
              + f'<rect x="346" y="356" width="14" height="26" rx="3" fill="{SURF}" transform="rotate(30 353 369)"/>')
    teeth = "".join(f'<rect x="{-6}" y="{-46}" width="12" height="16" rx="3" fill="{EMBER_P}" transform="translate(66 436) rotate({a})"/>'
                    for a in range(0, 360, 45))
    gear = teeth + circle(66, 436, 32, EMBER_P) + circle(66, 436, 11, SURF)
    return prop("mechanic", gear + wrench), [(112, 474), (292, 476)]


def boss():
    tie = rect(192, 428, 16, 12, 3, EMBER) + f'<polygon points="192,440 208,440 214,486 200,496 186,486" fill="{EMBER}"/>'
    case = (f'<path d="M248 462 V450 H278 V462" fill="none" stroke="{MUTED}" stroke-width="8" stroke-linejoin="round"/>'
            + rect(222, 462, 84, 60, 9, EMBER_P) + rect(256, 480, 14, 12, 3, MUTED))
    return prop("boss", tie + case), [(263, 450), HAND_L]


def bugcatcher():
    net = (line(294, 474, 344, 358, 8, EMBER_P)
           + f'<circle cx="350" cy="326" r="32" fill="none" stroke="{MUTED}" stroke-width="7"/>'
           + line(326, 326, 374, 326, 3, MUTED) + line(350, 302, 350, 350, 3, MUTED)
           + circle(350, 332, 11, EMBER) + circle(346, 329, 2.6, INK) + circle(354, 333, 2.6, INK) + line(350, 321, 350, 343, 2, INK))
    return prop("bugcatcher", net), [(298, 468), HAND_L]


def cardshark():
    colors = (INK, EMBER_P, PAPER)
    cards = "".join(f'<g transform="rotate({a} 330 528)">{rect(300, 430, 60, 90, 8, c)}</g>' for a, c in zip((-32, -10, 14), colors))
    suit = f'<g transform="rotate(14 330 528)"><polygon points="330,452 344,472 330,492 316,472" fill="{EMBER}"/></g>'
    return prop("cardshark", cards + suit), [(330, 522), HAND_L]


def journalist():
    pad = (rect(44, 448, 68, 86, 8, PAPER) + "".join(circle(58 + 14 * i, 448, 4.5, MUTED) for i in range(4))
           + "".join(line(54, y, 100, y, 5, MUTED) for y in (474, 490, 506)))
    pencil = line(292, 480, 334, 430, 10, EMBER) + line(334, 430, 346, 416, 10, PAPER) + line(342, 421, 349, 413, 10, INK)
    return prop("journalist", pad + pencil), [(96, 520), (292, 480)]


def messenger():
    letter = (rect(222, 452, 92, 64, 8, EMBER_P)
              + f'<path d="M226 458 L268 490 L310 458" fill="none" stroke="{PAPER}" stroke-width="7" stroke-linejoin="round" stroke-linecap="round"/>'
              + circle(268, 492, 8, EMBER) + line(330, 444, 352, 444, 5, MUTED) + line(336, 460, 360, 460, 5, MUTED))
    return prop("messenger", letter), [(306, 508), HAND_L]


def officeworker():
    mug = (rect(284, 462, 50, 58, 9, MUTED) + f'<circle cx="338" cy="490" r="13" fill="none" stroke="{MUTED}" stroke-width="7"/>'
           + f'<path d="M298 446 Q306 436 298 426" fill="none" stroke="{PAPER}" stroke-width="5" stroke-linecap="round"/>'
           + f'<path d="M320 446 Q328 436 320 426" fill="none" stroke="{PAPER}" stroke-width="5" stroke-linecap="round"/>')
    stack = (rect(34, 506, 76, 14, 4, PAPER) + rect(38, 490, 76, 14, 4, MUTED) + rect(32, 474, 76, 14, 4, PAPER))
    return prop("officeworker", stack + mug), [(76, 472), (292, 504)]


def pcbuilder():
    pins = "".join(line(x, y1, x, y2, 5, MUTED) for x in (58, 74, 90, 106) for y1, y2 in ((438, 448), (512, 522)))
    pins += "".join(line(x1, y, x2, y, 5, MUTED) for y in (462, 478, 494) for x1, x2 in ((38, 48), (112, 122)))
    chip = pins + rect(48, 446, 66, 66, 8, MUTED) + rect(62, 460, 38, 38, 5, INK) + circle(81, 479, 9, EMBER)
    driver = line(292, 484, 320, 434, 15, EMBER) + line(320, 434, 338, 402, 6, MUTED) + line(338, 402, 344, 392, 6, INK)
    return prop("pcbuilder", chip + driver), [(104, 516), (294, 484)]


def vr():
    pad_l = line(96, 472, 74, 420, 10, MUTED) + f'<circle cx="68" cy="404" r="17" fill="none" stroke="{EMBER}" stroke-width="7"/>'
    pad_r = line(304, 472, 326, 420, 10, MUTED) + f'<circle cx="332" cy="404" r="17" fill="none" stroke="{EMBER}" stroke-width="7"/>'
    cube = (f'<path d="M336 252 L366 268 V300 L336 316 L306 300 V268 Z M306 268 L336 284 L366 268 M336 284 V316" fill="none" '
            f'stroke="{PAPER}" stroke-width="5" stroke-linejoin="round" stroke-linecap="round"/>')
    return prop("vr", pad_l + pad_r + cube), [(98, 476), (302, 476)]


def laptop():
    lid = rect(116, 456, 168, 74, 9, MUTED) + circle(200, 494, 14, EMBER) + circle(200, 494, 5, PAPER)
    return prop("laptop", lid), [(138, 458), (262, 458)]


TITLES = {"bugcatcher": "bug catcher", "cardshark": "card shark", "officeworker": "office worker", "pcbuilder": "pc builder",
          "vr": "virtual reality"}

ACTIVITIES = {"artist": artist, "bookworm": bookworm, "hacker": hacker, "musician": musician, "scientist": scientist,
              "teacher": teacher, "mechanic": mechanic, "boss": boss, "bugcatcher": bugcatcher, "cardshark": cardshark,
              "journalist": journalist, "messenger": messenger, "officeworker": officeworker, "pcbuilder": pcbuilder,
              "vr": vr, "laptop": laptop}

# the names the pictures get in /usr/share/plasma/avatars (each replaces the Konqi picture of the same activity)
FILE_NAMES = {"nisse": "nisse.png", "artist": "Artist gnome.png", "bookworm": "Bookworm gnome.png", "boss": "Boss gnome.png",
              "bugcatcher": "Bug Catcher gnome.png", "cardshark": "Card Shark gnome.png", "hacker": "Hacker gnome.png",
              "journalist": "Journalist gnome.png", "mechanic": "Mechanic gnome.png", "messenger": "Messenger gnome.png",
              "musician": "Musician gnome.png", "officeworker": "Office Worker gnome.png", "pcbuilder": "PC Builder gnome.png",
              "scientist": "Scientist gnome.png", "teacher": "Teacher gnome.png", "vr": "Virtual Reality gnome.png",
              "laptop": "Laptop gnome.png"}


def wave_plain():
    arm = line(262, 452, 324, 398, 20, EMBER_T)
    wave = (circle(324, 390, 18, EMBER_T)
            + f'<path d="M356 366 Q370 384 362 406" fill="none" stroke="{MUTED}" stroke-width="5" stroke-linecap="round"/>'
            + f'<path d="M370 350 Q392 378 380 412" fill="none" stroke="{MUTED}" stroke-width="5" stroke-linecap="round"/>')
    return arm, wave


def figure(name):
    """The gnome with its prop, in the 400 x 600 figure canvas."""
    if name == "nisse":
        arm, wave = wave_plain()
        return arm + FEET + master_art() + hand(*HAND_L) + wave
    prop_markup, hands = ACTIVITIES[name]()
    return FEET + master_art() + prop_markup + "".join(hand(x, y) for x, y in hands)


def avatar(name):
    """One avatar: the Surface disc, the figure scaled into it, everything clipped to the disc."""
    clip = '<clipPath id="disc"><circle cx="256" cy="256" r="236"/></clipPath>'
    tx, ty = 256 - 200 * SCALE, 256 - 310 * SCALE
    body = (f'<circle cx="256" cy="256" r="236" fill="{SURF}"/>\n  <g clip-path="url(#disc)">'
            f'<g transform="translate({tx:.1f} {ty:.1f}) scale({SCALE})">{figure(name)}</g></g>')
    title = "nisse gnome avatar" if name == "nisse" else f"nisse gnome avatar, {TITLES.get(name, name)}"
    return doc(512, 512, title, body, clip)


def build_all():
    return {name: avatar(name) for name in ["nisse", *ACTIVITIES]}


def _inner(svg):
    start = svg.index("<defs>") if "<defs>" in svg else svg.index("<title>")
    return svg[start:svg.rindex("</svg>")]


SHEET_W, SHEET_H = 1880, 1480


def build_sheet():
    svgs = build_all()
    parts = []
    for i, (name, svg) in enumerate(svgs.items()):
        x, y = 30 + (i % 6) * 305, 40 + (i // 6) * 330
        parts.append(f'<g transform="translate({x} {y}) scale(0.54)">{_inner(svg).replace("id=\"disc\"", f"id=\"disc{i}\"").replace("url(#disc)", f"url(#disc{i})")}</g>'
                     f'<text x="{x + 138}" y="{y + 310}" text-anchor="middle" font-family="Nunito, sans-serif" font-size="24" fill="{MUTED}">{name}</text>')
    y0 = 1090
    for bg, tx, fg, label in ((INK, 30, MUTED, "dark"), (PAPER, 960, "#354156", "light")):
        parts.append(rect(tx, y0, 890, 190, 0, bg))
        x = tx + 24
        for sz in (96, 64, 48, 32):
            for i, (name, svg) in enumerate(list(svgs.items())[:2]):
                inner = _inner(svg).replace('id="disc"', f'id="s{label}{sz}{i}"').replace("url(#disc)", f"url(#s{label}{sz}{i})")
                parts.append(f'<g transform="translate({x} {y0 + 20}) scale({sz / 512:.4f})">{inner}</g>')
                x += sz + 10
            x += 18
        parts.append(f'<text x="{tx + 24}" y="{y0 + 178}" font-family="Nunito, sans-serif" font-size="20" fill="{fg}">'
                     f'{label}: sizes 96, 64, 48 and 32 px (48 px is the login screen)</text>')
    body = rect(0, 0, SHEET_W, SHEET_H, 0, INK) + "".join(parts)
    return doc(SHEET_W, SHEET_H, "nisse activity avatars", body)


# ---- the other Konqi pictures: the "loves" sticker, and the pair on the phone (Plasma Setup and Plasma Welcome)
SOURCE_LOVES = OUT / "source" / "fedora-loves-kde.svg"
TILE_SVG = ROOT / "assets" / "logo" / "svg" / "nisse-app-tile.svg"
LEFT_LOGO = '<g style="stroke-width:.675354">'   # the original's left logo group (the Fedora bubble and its f): nothing else


def build_loves():
    """The sticker as Bert gated it: the nisse logo takes the shape of the Fedora bubble (the white outline already follows
    it), the Fedora f becomes the logo's Paper disc with the hat and hill knocked out, and all three marks (the nisse
    logo, the heart and the KDE logo) are the nisse Ink. The white outline and every shape are the original's."""
    src = SOURCE_LOVES.read_text(encoding="utf-8")
    i = src.index(LEFT_LOGO)
    j = src.index("</g>", i) + len("</g>")
    left = src[i:j]
    bubble = re.search(r'<path d="[^"]+" style="fill:#51a2da[^"]*" transform="[^"]+"/>', left).group(0)
    bubble = bubble.replace("#51a2da", INK)
    tile = TILE_SVG.read_text(encoding="utf-8")
    defs = tile[tile.index("<defs>"):tile.index("</defs>") + len("</defs>")]
    disc = (f'<circle cx="256" cy="256" r="236" fill="{PAPER}" mask="url(#knockout)"/>')
    # the logo's disc sits where the f was (its centre is the bubble centre, about 76, 77) and about 57 units across
    nisse = (f'<g id="nisse-logo">{bubble}'
             f'<svg x="45" y="46" width="62" height="62" viewBox="0 0 512 512">{defs}{disc}</svg></g>')
    rest = src[j:].replace("#db3279", INK).replace("#1d99f3", INK)
    note = ("<!-- Derived from fedora-loves-kde.svg (plasma-welcome-fedora 6.3.4-3, see assets/art/avatars/source): the left logo is "
            "the nisse logo in the bubble's shape, and the heart and the KDE logo are recoloured to the nisse Ink; every shape and the "
            "outline are the original's. Licence of the original to be confirmed when this is packaged (ledger N-406a). -->")
    out = src[:i] + nisse + rest
    k = out.index(">") + 1        # right after the opening svg tag
    return out[:k] + note + out[k:]


def build_pair():
    """Two gnomes and a phone: one looks at a phone, one has a phone at the ear. Replaces the Konqi and Katie picture shown
    on the Plasma Setup finish page and the Plasma Welcome repositories page. One rounded Surface panel, so the Paper beards
    read on a light window too."""
    panel = rect(0, 0, 500, 334, 36, SURF)
    sc = 0.62

    def gnome(cx, extra):
        return (f'<g transform="translate({cx - 200 * sc:.1f} {-29}) scale({sc})">{FEET}{master_art()}{extra}</g>')

    phone_in_hands = (rect(166, 440, 62, 44, 8, INK, ' transform="rotate(-10 197 462)"') + rect(171, 445, 52, 34, 4, MUTED, ' transform="rotate(-10 197 462)"')
                      + hand(150, 478) + hand(236, 470))
    at_ear = (rect(284, 366, 20, 52, 8, INK) + rect(288, 372, 12, 40, 3, MUTED) + hand(296, 420)
              + f'<path d="M318 372 Q334 390 318 408" fill="none" stroke="{MUTED}" stroke-width="6" stroke-linecap="round"/>'
              + f'<path d="M334 358 Q362 390 334 424" fill="none" stroke="{MUTED}" stroke-width="6" stroke-linecap="round"/>'
              + hand(*HAND_L))
    body = panel + gnome(150, phone_in_hands) + gnome(350, at_ear)
    return doc(500, 334, "nisse gnomes on the phone", body)


EXTRAS_W, EXTRAS_H = 1500, 620


def build_extras_sheet(loves, pair):
    """The two other pictures on a dark and a light page: the pair (500 x 334) and the sticker (100 x 44 mm)."""
    def inner(svg):
        return svg[svg.index(">", svg.index("<svg")) + 1:svg.rindex("</svg>")]
    parts = [rect(0, 0, 750, EXTRAS_H, 0, INK), rect(750, 0, 750, EXTRAS_H, 0, PAPER)]
    for k, (x0, fg) in enumerate(((0, MUTED), (750, "#354156"))):
        parts.append(f'<g transform="translate({x0 + 125} 30)">{inner(pair)}</g>')
        parts.append(f'<g transform="translate({x0 + 150} 400) scale(1.5)">{inner(loves).replace("knockout", f"knockout{k}")}</g>')
        parts.append(f'<text x="{x0 + 24}" y="30" font-family="Nunito, sans-serif" font-size="20" fill="{fg}">{"dark" if k == 0 else "light"} page</text>')
    return doc(EXTRAS_W, EXTRAS_H, "nisse extra pictures", "".join(parts))


def _png(svg, w, h, transparent=True):
    from playwright.sync_api import sync_playwright
    uri = "data:image/svg+xml;base64," + base64.b64encode(svg.encode("ascii")).decode()
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": w, "height": h})
        pg.set_content(f'<html><body style="margin:0;background:transparent"><img src="{uri}" width="{w}" height="{h}" style="display:block"></body></html>')
        pg.wait_for_function("document.images[0].complete")
        data = pg.screenshot(clip={"x": 0, "y": 0, "width": w, "height": h}, omit_background=transparent)
        b.close()
    return data


def main():
    (OUT / "svg").mkdir(parents=True, exist_ok=True)
    (OUT / "png").mkdir(parents=True, exist_ok=True)
    for name, svg in build_all().items():
        (OUT / "svg" / f"nisse-avatar-{name}.svg").write_text(svg, encoding="ascii", newline="\n")
        (OUT / "png" / f"nisse-avatar-{name}.png").write_bytes(_png(svg, PX, PX))
    manifest = ["# source (under assets/art/avatars)" + chr(9) + "install name in /usr/share/plasma/avatars (written by tools/art/avatars.py)"]
    manifest += [f"png/nisse-avatar-{name}.png" + chr(9) + dest for name, dest in FILE_NAMES.items()]
    (OUT / "install-manifest.txt").write_text(LF.join(manifest) + LF, encoding="ascii", newline=LF)
    loves, pair = build_loves(), build_pair()
    (OUT / "svg" / "nisse-loves-kde.svg").write_text(loves, encoding="ascii", newline=LF)
    (OUT / "svg" / "nisse-pair.svg").write_text(pair, encoding="ascii", newline=LF)
    (OUT / "png" / "nisse-pair.png").write_bytes(_png(pair, 1000, 668))
    extras = build_extras_sheet(loves, pair)
    (OUT / "extras.png").write_bytes(_png(extras, EXTRAS_W, EXTRAS_H, transparent=False))
    sheet = build_sheet()
    (OUT / "sheet.svg").write_text(sheet, encoding="ascii", newline="\n")
    (OUT / "sheet.png").write_bytes(_png(sheet, SHEET_W, SHEET_H, transparent=False))
    print(f"wrote {len(build_all())} avatars (svg and {PX} px png) and sheet.png to {OUT}")


if __name__ == "__main__":
    sys.exit(main())
