# Look spike: how to theme widgets and window decorations (ledger N-105)

Date: 2026-11-12. Spike, not a plan. The pick is Bert's, at N-106.

## The question

The Ember color scheme (N-104) recolors KDE. Is that enough of a "distinct Nisse identity", or do widget shapes and
window decorations need their own theme, and what does each way cost? Three candidates:

- **A. Breeze plus our colors.** Keep KDE's Breeze widget style, Breeze window decoration and Breeze Plasma style; the
  Nisse color scheme (and later icons, cursor, wallpaper) carries the identity.
- **B. Kvantum, Aurorae and a custom Plasma Style.** Replace the widget style with Kvantum (an SVG and config driven
  style engine), the title bars with Aurorae (KWin's SVG decoration engine), the shell with our own Plasma Style SVGs.
  Data files only, no C++.
- **C. Custom C++ plugins.** Our own Qt style and KDecoration plugins (or a fork of Breeze).

## Method

Real renders, not mockups. The 2026-11-05 ISO (Plasma 6.6.4, KWin 6.6.4, Qt 6.10.2) was booted under QEMU. A small
driver (`tools/vm/livevm.py`) logged in over the serial console, applied each variant to the live Plasma
Wayland session and screenshotted the same three apps each time: Dolphin (a Qt widgets app), System Settings (a
Kirigami app) and the Nisse panel app (our own QML app). Variants:

| Id | What was applied |
|---|---|
| Today | stock Breeze, Breeze Light scheme (what the ISO ships) |
| A | `NisseEmber.colors` from N-104, applied with `plasma-apply-colorscheme`; Breeze style and decoration unchanged |
| B1 | Kvantum 1.1.6 with a theme made by recoloring KvFlat to the Ember tokens (script below), plus the Ember scheme |
| B2 | Kvantum with the stock rounded theme KvGnomeDark, plus the Ember scheme (shows Kvantum's shape range) |

Sheets (same windows, four variants each):

- `docs/look-spike/sheet-dolphin.jpg`
- `docs/look-spike/sheet-settings.jpg`
- `docs/look-spike/sheet-nisse.jpg`

## What was verified

| Claim | How | Result |
|---|---|---|
| The N-104 schemes load in a live Plasma session | `plasma-apply-colorscheme --list-schemes` and `NisseEmber` applied | Both Nisse schemes are listed, `NisseEmber` applied; System Settings Colors page renders both previews. This is the live-load part of N-104; the ISO packaging is still certified at GATE 1. |
| The Breeze icon theme follows the scheme | Dolphin folder icons | Blue in stock, Ember orange under the Ember scheme, with no icon work. |
| Plasma's own shell (panel, launcher menu) follows the scheme | launcher screenshot | Dark navy surfaces, Ember selection. |
| Kirigami and QML apps follow the scheme | System Settings, the Nisse panel app | Yes, in A. Under Kvantum they look almost the same as under Breeze. |
| Kvantum installs without root | `dnf download` then `rpm2cpio`, run from the home folder | Works; no missing libraries. (The live session's `sudo` wants a password.) |
| A Kvantum theme can be generated from the tokens | sed recolor of KvFlat, below | Works; see B1 in the sheets. About ten SVG colors map to tokens; a second pass was needed for stock blue and greys. |
| Aurorae is on the ISO | `rpm -q aurorae` | `aurorae-6.6.4-1.fc44`. |
| Breeze's own knobs | `breeze.kcfg`, `breeze-decoration.kcfg` in plasma-breeze | Behavior only: animations, scrollbar buttons, menu opacity, window drag, title alignment, button size. No corner radius or color settings. |

### How B1 was made (for N-107 if B is chosen)

Copy `/usr/share/Kvantum/KvFlat` to `NisseFlat`; rewrite the `[GeneralColors]` block of the `.kvconfig` from the tokens
(window, base, alt.base, button, light, mid, dark, highlight, text, link and visited colors); and substitute the
colors hard-coded in the `.svg`: KvFlat blue to `accent`, `accent-pressed`, `accent-hover`; its greys to `base`,
`surface`, `surface-2`, `divider`, `outline`. The result is generated output, like the color schemes.

## Findings

**The scheme does most of the work.** Today versus A is the big change in every window. A is "Breeze in Ember colors":
every shape, radius and spacing is stock KDE. If the identity is meant to come from color, icons, wallpaper, logos and
the mascot, A already carries it.

**Kvantum changes the shapes only a little unless someone redraws the SVG.** B1 and B2 differ from A in toolbar,
view-frame, button and field details, not in the overall silhouette. The Nisse panel app (QML) is nearly identical in A, B1
and B2. A distinct widget shape language means editing or drawing the Kvantum SVG by hand; recoloring is scripted,
reshaping is design work. A stock Kvantum theme (B2) brings its own greys and loses our surface colors.

**Window decorations were not changed in any variant.** All four use the Breeze decoration, colored by the scheme's
WM colors (`activeBackground` and friends). Aurorae is installed and would allow a full SVG title bar, but writing an
Aurorae theme was not tried in this spike (format and effort unverified).

**The Plasma Style was not changed either** (Breeze's, recolored by the scheme). A custom Plasma Style SVG set is
supported by Plasma but was not tried.

## Cost and risk

| | A | B | C |
|---|---|---|---|
| New dependencies | none | Kvantum (third party, not part of KDE; Fedora 44 has 1.1.6, GPL-3.0-or-later). Aurorae is already present. | our own plugins; or a Breeze fork replacing `plasma-breeze` |
| What can differ from stock | colors, icons, cursor, wallpaper, fonts, title alignment, button size | the above plus widget shapes and title bars, by SVG | anything |
| Work | done (N-104) plus settings | color scripts exist; shapes and title bars are hand design | C++ in Qt style and KDecoration APIs; GUESS: weeks to build |
| Per Fedora release | none beyond the usual | check that Kvantum and Aurorae still load; theme SVGs are stable data | GUESS: a porting job each release (design section 9 already flags this); security fixes to a forked Breeze become ours |
| Licence note | none | a theme derived from KvFlat carries its licence (GPL-3.0-or-later, our repo is GPL-2.0-or-later); decide at N-107 | a Breeze fork inherits Breeze's mixed licences |

The C figures are estimates, not measurements. C was not built.

## Recommendation

**A for Milestone 2.** It costs nothing new, follows every KDE upgrade, and the sheets show it already looks like
Nisse and not like stock Breeze. Spend the effort that would go into B on the stage 4 art instead.

**Keep B1 as a proven optional upgrade** (DEFERRED if Bert wants it): a generated Kvantum theme works and could be added
later if the stock widget silhouette starts to bother him; reshaping the SVG is the real cost. **Do not build C.**

If Bert wants title bars that are not Breeze's, that is Aurorae and needs its own spike (a hand-made decoration theme).

## Side findings for later tasks

- N-113 (screenshot harness): the prototype driver works. Gotchas: the live session locks itself after about 5 minutes
  (turn off `Autolock` in `kscreenlockerrc`); `loginctl unlock-sessions` asks polkit and eats the next characters typed
  on the serial console; `sudo` needs a password in the live session; `plasma-apply-colorscheme` and
  `dbus-send ... activateLauncherMenu` work from the serial shell when `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`
  and `WAYLAND_DISPLAY` are set.
- N-107 and N-108: system-wide, Kvantum (if ever used) would be selected through `kdeglobals` `[KDE] widgetStyle`;
  not verified here (the spike used `QT_STYLE_OVERRIDE` per app).
