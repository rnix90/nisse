# The tray icon and the web mark (N-413)

Bert approved both on 2026-11-19 (`assets/art/tray/sheet.png`, `assets/art/web/sheet.png`).

## The tray icon: one mark, six states

The mark is the n with its tipped hat (N-403, the panel app's icon). `tools/art/tray_icons.py` builds six symbolic SVGs
(`assets/art/tray/svg/nisse-tray-<state>-symbolic.svg`, 33 tests in `tools/art/tests/test_tray_icons.py`). Plasma recolors a
symbolic icon to the panel's text color, so each file is **one color** (`currentColor`) with KDE's `current-color-scheme` style,
no gradients, no filters, no opacity. The tray is monochrome, so the states differ by shape:

| State | Shape | Means (source) |
|---|---|---|
| idle | the n alone | nothing waits |
| busy | the n, smaller, inside the comet ring (the N-404 spinner, the same ring the Plasma splash uses) | a turn is running |
| needs-you | a solid disc top right with an exclamation mark cut out | an approval waits (N-205) |
| unread | a solid dot top right | a turn finished while you were elsewhere (N-207) |
| paused | two bars top right (bars, not a disc: a disc with bars cut out was too like needs-you at 22 px, found by the test) | the kill switch is on (N-215) |
| offline | a ring with a slash through it, top right | the daemon cannot be reached (N-218) |

Every badge leaves a clear gap around itself (a mask), so it never merges with the n at 16 px. Tests check: six states exist,
well-formed ASCII, KDE style present, drawn in `currentColor` only, the hat is the logo's own `HAT`, badges stay inside the box, the
six differ pairwise at 22 px, the badge states keep the n undisturbed and add a mark top right, and the icon takes the panel color.

**Handed on (N-415 and the panel wiring):** install the six files into `nisse-branding` (or `nisse-theme`) as
`/usr/share/icons/hicolor/scalable/status/nisse-tray-<state>-symbolic.svg`, and have the tray item switch among them as the daemon's
state changes (the panel already tracks approvals, unread, the kill switch and the daemon's presence). The Plasma widget (N-5xx or
later) reuses them.

## The website and favicon mark

The logo build had already made the web set (`assets/logo/favicon`, `assets/logo/social`). Three favicon options were shown at tab
size on a light and a dark browser (`tools/art/web_mark_options.py`): **A** the logo disc, **B** the n with its hat, **C** the Ink
tile. Bert chose **A, the logo disc as built**: it reads best at 16 px, follows the browser's light or dark mode, and matches the link
preview card and the touch icon, so nothing is rebuilt. B was a narrow shape at 16 px that reads as a letter; C vanishes on a dark
browser.

The web set as it stands: `favicon.svg` (follows the color scheme), `favicon.ico` (16, 32, 48, 64), `favicon-16.png`,
`favicon-32.png`, `apple-touch-icon.png` (180), `android-chrome-192.png` and `-512.png`, `og-image-1200x630.png` and
`github-social-preview-1280x640.png`.
