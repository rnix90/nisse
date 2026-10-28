# Nisse logo package

The mark is the nisse's cap peeking over a hill, inside a disc. The wordmark is set in
Nunito ExtraBold (SIL OFL 1.1, see `../fonts/Nunito/`), converted to outlines, so no file
here needs the font installed.

Everything in this folder except the `ascii/` text is generated. Do not hand-edit it;
change `tools/logo/build.py` and re-run it (needs fontTools, Pillow, playwright + Chromium):

    python tools/logo/build.py

## Colours

| Name | Hex | Use |
|---|---|---|
| Ink | `#1b2330` | the mark on light backgrounds, tile and splash background |
| Paper | `#f6f2e9` | the mark on dark backgrounds |

Each form also comes in pure `-black` and `-white` for stamps, print, one-colour jobs.
In every file the cap and hill line are real transparency (SVG mask), not a paper fill.

## Which file to use

| Need | File |
|---|---|
| Default 1:1 icon | `svg/nisse-icon.svg` (light bg) / `svg/nisse-icon-reverse.svg` (dark bg) |
| Name + icon, wide | `svg/nisse-lockup-horizontal*.svg` |
| Name + icon, tall (installer, posters) | `svg/nisse-lockup-stacked*.svg` |
| Name only, where the name is listed | `svg/nisse-wordmark*.svg` (cap sits on the i) |
| Self-contained app / launcher icon | `svg/nisse-app-tile.svg` |
| Panel / toolbar icon that follows text colour | `svg/nisse-icon-symbolic.svg` |
| Raster versions | `png/` (icon 16-1024 px, lockups and wordmark 600/1200/2400 px wide) |
| Web | `favicon/` (`favicon.svg` follows dark mode, `favicon.ico`, apple-touch, android-chrome) |
| freedesktop icon theme | `linux/hicolor/` (`distributor-logo-nisse`, all sizes + scalable + symbolic) |
| Boot and login splash | `boot/` (1080p and 4K splash, 256 px reverse logo for Plymouth or GRUB) |
| Repo / link previews | `social/` (GitHub social preview 1280x640, Open Graph 1200x630) |
| Terminal / MOTD / fetch tools | `ascii/nisse-icon.txt` (plain ASCII) |

## Using it in the distro

- **os-release:** set `LOGO=distributor-logo-nisse` and install `linux/hicolor/` under
  `/usr/share/icons/hicolor/`.
- **Fonts:** install `../fonts/Nunito/` to `/usr/share/fonts/truetype/nunito/` and ship its `OFL.txt`.
- **Plymouth / GRUB:** `boot/boot-logo-reverse-256.png` on the ink background (`#1b2330`).

## Rules of thumb

- Clear space around the mark: at least a quarter of the icon's diameter.
- Smallest sizes: icon 16 px, lockups 120 px wide. Below that use the icon alone.
- Do not recolour outside the four colourways, stretch, or re-letter the wordmark.
- The terminal-under-the-cap sketch from the logo exploration is reserved for the distro's
  terminal app and is not part of this package.

## Licensing

Logo files are GPL-2.0-or-later like the rest of the repo (revisit if we ever need a
trademark policy). The Nunito font keeps its own license, SIL OFL 1.1.
