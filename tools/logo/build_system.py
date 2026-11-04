#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build Nisse's replacements for the Fedora placeholder art (the generic-logos "hot dog") into assets/logo/system/.

The tree under assets/logo/system mirrors the file system (usr/share/...), so nisse-branding installs it with one copy.
Every path and size comes from tests/rpm/placeholder-paths.txt: a replacement has the same size as the file it replaces.
Inputs are the files tools/logo/build.py already generated (assets/logo/png and assets/logo/svg); colours are Ink and
Paper only (the Ember accent arrives with roadmap 1.1/1.2). The symlink places/start-here.svg is made by the RPM spec.

Needs: Pillow.  Run from anywhere:  python tools/logo/build_system.py [--out DIR]
"""
import argparse
import pathlib
import shutil

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
LOGO = ROOT / "assets" / "logo"
INK = (0x1B, 0x23, 0x30, 255)

# Where each kind of art goes: (path under the image root, kind)
TILE_SVG = LOGO / "svg" / "nisse-app-tile.svg"
SVG_COPIES = (
    "usr/share/icons/hicolor/scalable/apps/anaconda.svg",
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


def transparent(size, art, box):
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    art = fit(art, *box)
    canvas.alpha_composite(art, ((size[0] - art.width) // 2, (size[1] - art.height) // 2))
    return canvas


def build(out):
    out = pathlib.Path(out)
    if out.exists():
        shutil.rmtree(out)
    stacked = png("nisse-lockup-stacked-reverse-1280w.png")
    stacked_ink = png("nisse-lockup-stacked-1280w.png")
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
    for rel in ("usr/share/icons/hicolor/48x48/apps/anaconda.png", "usr/share/icons/oxygen/48x48/apps/anaconda.png"):
        save(rel, tile.resize((49, 49), Image.LANCZOS))
    for rel in SVG_COPIES:
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(TILE_SVG, path)

    # the logo files other packages look for by their Fedora names
    save("usr/share/pixmaps/fedora-logo-small.png", tile.resize((128, 128), Image.LANCZOS))
    save("usr/share/pixmaps/fedora-logo.png", transparent((240, 310), stacked_ink, (200, 270)))
    save("usr/share/pixmaps/system-logo-white.png", transparent((240, 310), stacked, (200, 270)))
    save("usr/share/pixmaps/splash/gnome-splash.png", on_ink((420, 293), stacked, (230, 200)))

    # Mac boot icon
    save("usr/share/pixmaps/bootloader/fedora.icns", tile.resize((512, 512), Image.LANCZOS), format="ICNS")
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=str(LOGO / "system"))
    args = parser.parse_args()
    done = build(args.out)
    print(f"wrote {sum(1 for p in pathlib.Path(done).rglob('*') if p.is_file())} files under {done}")
