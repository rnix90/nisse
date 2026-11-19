#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build nisse's replacements for the Fedora placeholder art (the generic-logos "hot dog") into assets/logo/system/.

The tree under assets/logo/system mirrors the file system (usr/share/...), so nisse-branding installs it with one copy.
Every path and size comes from tests/rpm/placeholder-paths.txt: a replacement has the same size as the file it replaces.
Inputs are the files tools/logo/build.py already generated (assets/logo/png and assets/logo/svg); colours are Ink and
Paper only (the Ember accent arrives with roadmap 1.1/1.2). The symlink places/start-here.svg is made by the RPM spec.

Needs: Pillow.  Run from anywhere:  python tools/logo/build_system.py [--out DIR]
"""
import argparse
import io
import pathlib
import shutil
import sys

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parents[2]
LOGO = ROOT / "assets" / "logo"
INK = (0x1B, 0x23, 0x30, 255)

# Where each kind of art goes: (path under the image root, kind)
TILE_SVG = LOGO / "svg" / "nisse-app-tile.svg"
SVG_COPIES = (
    "usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg",
    "usr/share/icons/hicolor/scalable/apps/fedora-logo-sprite.svg",
    "usr/share/icons/hicolor/scalable/apps/start-here.svg",
    "usr/share/pixmaps/fedora-logo-sprite.svg",
)


def png(name):
    return Image.open(LOGO / "png" / name).convert("RGBA")


def fit(img, max_w, max_h):
    """Scale `img` to the largest size inside max_w x max_h, keeping its proportions."""
    scale = min(max_w / img.width, max_h / img.height)
    return img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.LANCZOS)


def on_ink(size, art, box, left=None):
    """Ink canvas of `size` with `art` fitted into `box` (w, h) and centred (or at x=`left`, centred vertically)."""
    canvas = Image.new("RGBA", size, INK)
    art = fit(art, *box)
    x = left if left is not None else (size[0] - art.width) // 2
    canvas.alpha_composite(art, (x, (size[1] - art.height) // 2))
    return canvas


def card(size, art, box, radius=26):
    """Opaque Ink rounded card with `art` fitted and centred: readable on a light page and on a dark one."""
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    canvas.paste(Image.new("RGBA", size, INK), (0, 0), mask)
    art = fit(art, *box)
    canvas.alpha_composite(art, ((size[0] - art.width) // 2, (size[1] - art.height) // 2))
    return canvas


def build(out):
    out = pathlib.Path(out)
    if out.exists():
        shutil.rmtree(out)
    stacked = png("nisse-lockup-stacked-reverse-1280w.png")
    horizontal = png("nisse-lockup-horizontal-reverse-1200w.png")
    tile = png("nisse-app-tile-1024.png")
    icon_reverse = png("nisse-icon-reverse-512.png")

    def save(rel, img, **kw):
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        img.save(path, **kw)

    # installer (Anaconda) and its boot media
    save("usr/share/anaconda/boot/splash.png", on_ink((640, 480), stacked, (360, 300)))
    syslinux = on_ink((640, 300), stacked, (300, 230)).convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=16)
    save("usr/share/anaconda/boot/syslinux-splash.png", syslinux)
    save("usr/share/anaconda/pixmaps/anaconda_header.png", on_ink((800, 88), horizontal, (420, 56), left=24))
    for name in ("progress_first.png", "splash.png"):
        save(f"usr/share/anaconda/pixmaps/{name}", on_ink((416, 265), stacked, (230, 190)))
    save("usr/share/anaconda/pixmaps/sidebar-bg.png", Image.new("RGBA", (406, 767), INK))
    save("usr/share/anaconda/pixmaps/sidebar-logo.png", fit(icon_reverse, 128, 128))
    save("usr/share/anaconda/pixmaps/topbar-bg.png", Image.new("RGBA", (1040, 132), INK))

    # launcher and installer icons (the start button is start-here)
    # the installer's icon is the nisse logo on a disk (N-409), drawn by tools/art/icons.py; its PNGs keep the placeholder's 49 pixels
    sys.path.insert(0, str(ROOT / "tools" / "art"))
    import icons  # noqa: E402
    disk = icons.build_all()["anaconda"]
    path = out / "usr/share/icons/hicolor/scalable/apps/anaconda.svg"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(disk, encoding="ascii", newline=chr(10))
    # the icon liveinst.desktop names for the live desktop's Install to Hard Drive launcher (fedora-logos shipped it; N-410: a pickaxe)
    pick = out / f"usr/share/icons/hicolor/scalable/apps/{icons.INSTALLER_ICON}.svg"
    pick.write_text(icons.build_all()["install-to-hard-drive"], encoding="ascii", newline=chr(10))
    disk_png = Image.open(io.BytesIO(icons.render_png(disk, 49))).convert("RGBA")
    for rel in ("usr/share/icons/hicolor/48x48/apps/anaconda.png", "usr/share/icons/oxygen/48x48/apps/anaconda.png"):
        save(rel, disk_png)
    for rel in SVG_COPIES:
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(TILE_SVG, path)

    # the logo files other packages look for by their Fedora names
    save("usr/share/pixmaps/fedora-logo-small.png", tile.resize((128, 128), Image.LANCZOS))
    # shown on light and dark pages alike (the About page uses system-logo-white.png): opaque cards
    save("usr/share/pixmaps/fedora-logo.png", card((240, 310), stacked, (180, 240)))
    save("usr/share/pixmaps/system-logo-white.png", card((240, 310), stacked, (180, 240)))

    # the installer you see is the Anaconda WebUI (a Cockpit page): its colors and logo come from the branding folder named after
    # os-release ID, built from the palette (N-411)
    import installer_look  # noqa: E402
    installer_look.write(out)

    # Mac boot icon
    save("usr/share/pixmaps/bootloader/fedora.icns", tile.resize((512, 512), Image.LANCZOS), format="ICNS")
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=str(LOGO / "system"))
    args = parser.parse_args()
    done = build(args.out)
    print(f"wrote {sum(1 for p in pathlib.Path(done).rglob('*') if p.is_file())} files under {done}")
