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

## The tray item (N-415b)

The six icons are installed by `nisse-branding` (N-415) and the panel's tray item switches among them. It is a StatusNotifierItem that
`nisse-panel` exports itself over QtDBus (`panel/src/TrayItem.cpp`; no new dependency), plus a small dbusmenu for the right-click menu.
Plain D-Bus was chosen because the same code then runs in the unit test on a private bus and in the image (Qt Labs would hand off to
plasma-integration under Plasma, and kf6-kstatusnotifieritem pulls in Widgets).

**Which icon wins** when several things are true, strongest first (Bert, 2026-11-20): offline, needs you, paused, busy, unread, idle.
Offline is first because with the daemon gone the approvals count and the pause switch are last-known values that cannot be acted on;
the tooltip keeps the last-known count ("Daemon not reachable (last known: 2 approvals waiting)"). `TrayState` holds the rule and the
words, `panel/tests/tst_trayicon.cpp` proves every state and every pair.

| Where | What |
|---|---|
| icon | `nisse-tray-<state>-symbolic`; Status is NeedsAttention only for needs you |
| tooltip | the state in words with the approvals count ("2 approvals waiting", "AI paused", "Working", "1 conversation finished") |
| left click | slides the sidebar in or out (`PanelService::Toggle`) |
| middle click | opens the sidebar on the approvals page |
| right-click menu | Open nisse; Approvals (N), shown only while something waits and the daemon is there; a separator; Pause AI / Resume AI (the kill switch, N-215, as the desktop device; disabled while the daemon is away) |

The SNI protocol has no count slot, so the count is on the tooltip, in the menu entry and in the needs-you icon itself; the taskbar badge
on the pinned launcher (N-207) stays as it was. The inputs come from `DaemonClient` (connection, approvals, kill switch) and from the
conversation tabs (`SessionTabs.workingCount` and `unreadCount`, handed over through `TrayCounts`). `--demo-tray STATE[:N]` forces a state
for screenshots and checks.

Checked: `tst_trayicon` (state mapping, 44 checks), `tst_trayitem` (the item and the menu on a private bus, 20 checks: registration with a
watcher that appears later, each state's icon, status and tooltip, the count, change signals, clicks, the menu and its events),
`tests/e2e/tray_inner.sh` (the real panel and the real daemon on a bus: the icon follows the kill switch, the menu really pauses and
resumes the daemon and is audited as the desktop device, offline when the daemon stops), and `tools/vm/tray_check.py` (the live Plasma
session's own watcher takes the item for each state, with screenshots). The live check's 32 checks pass on the image's Plasma 6.6.4, and its screenshots are the proof the icons read in the real tray:
`docs/screenshots/n-415b-tray-states.png` is the tray crop for each of the six states (each distinct at the tray's size). Notes for the
next person who drives the live session: files go over the serial console at about 100 KB a minute, so `tray_check.py` sends the panel
gzipped (strip it first); `busctl` opens a pager on the serial tty unless given `--no-pager`; and the session locks itself after the long
transfer, so the check unlocks it (`loginctl unlock-sessions`) before each screenshot.

Not provable in the harness, so GATE 3 hand checks (N-313): a real
mouse click on the tray icon slides the sidebar, and the right-click menu shows its entries and works.

## The website and favicon mark

The logo build had already made the web set (`assets/logo/favicon`, `assets/logo/social`). Three favicon options were shown at tab
size on a light and a dark browser (`tools/art/web_mark_options.py`): **A** the logo disc, **B** the n with its hat, **C** the Ink
tile. Bert chose **A, the logo disc as built**: it reads best at 16 px, follows the browser's light or dark mode, and matches the link
preview card and the touch icon, so nothing is rebuilt. B was a narrow shape at 16 px that reads as a letter; C vanishes on a dark
browser.

The web set as it stands: `favicon.svg` (follows the color scheme), `favicon.ico` (16, 32, 48, 64), `favicon-16.png`,
`favicon-32.png`, `apple-touch-icon.png` (180), `android-chrome-192.png` and `-512.png`, `og-image-1200x630.png` and
`github-social-preview-1280x640.png`.
