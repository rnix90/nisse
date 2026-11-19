# The panel as a docked sidebar (N-415a)

**Status 2026-11-19: built and verified except keyboard delivery (see "OPEN" below). N-415a stays open.**

On 2026-11-19, planning the tray item, Bert said the panel should not open and minimize like a window but be an embedded part of the
desktop. Asked which form he meant, he chose a **docked sidebar on a screen edge** (not a desktop widget, not the normal window).
This page records what was verified, what was decided and what was built.

## The mechanism, verified on the live session

The image is Fedora 44's release repository only, so the live session is **Plasma 6.6.4** (KWin 6.6.4, Qt 6.10.2). layer-shell-qt 6.6.4 is
in that repository and is the same version. A Qt window made a layer-shell surface (`LayerShellQt::Window`: layer Top, anchored top,
bottom and right, exclusive zone 0, keyboard interactivity "on demand") on the live ISO:

| Question | Result (probe `tools/vm/sidebar_probe`, driver `tools/vm/sidebar_spike.py`) |
|---|---|
| docks on the right edge, full height | yes (`probe-shown.png`: it fills the screen height down to the taskbar and covers part of the windows under it) |
| taskbar button, Alt-Tab, minimize | no taskbar button in the screenshots (a layer surface is not a normal window). Alt-Tab was not exercised; by construction a layer surface is not in the window switcher |
| keyboard focus | yes: after `requestActivate()` typed keys reached the text field (`typed=hello`), and again after a click |
| slide in and out | yes: animating the surface margin from 0 to minus its width hides it completely (`probe-slid-out.png`) and back |
| pointer at the screen edge | yes: a 2 px nearly transparent layer surface on the right edge gets the pointer enter (`edge strip hover=true`) |
| several monitors | not tested |

The probe built against layer-shell-qt 6.6.4 from the release repository. The first spike attempt used 6.8.3 from the updates repository
by mistake; see `docs/build-host.md` for how that broke the build VM, and why the build VM must never install from updates.

## What Bert decided

- the **right edge**;
- it opens by the **tray click** (N-415b), a **keyboard shortcut** (Meta+N), a **click on an approval notice**, and the **pointer pushing
  against the right screen edge**;
- it **stays open until closed** (losing focus does not close it; the same triggers or Escape close it);
- it **floats over other windows** (nothing is pushed aside).

Not asked, chosen: 420 px wide, full height; the pointer must dwell about 300 ms at the edge, so a pointer passing by or a scrollbar
drag does not pop it open; an edge open does **not** take the keyboard (only an intentional open does).

## What was built

| Piece | Where |
|---|---|
| the rules: open, close, slide, edge dwell, "viewing" | `panel/src/Sidebar.{h,cpp}`, tested without a compositor in `panel/tests/tst_sidebar.cpp` |
| the real surfaces: the sidebar and the edge strip | `panel/src/LayerShellDock.{h,cpp}` (layer-shell-qt) |
| one instance, a control surface on the bus: `org.nisse.Panel` (`Toggle`, `Show`, `Hide`, `ShowApprovals`, `IsOpen`); a second launch toggles the running one and exits | `panel/src/PanelService.{h,cpp}`, `panel/tests/tst_panelservice.cpp` |
| starts at login, closed | `/etc/xdg/autostart/nisse-panel-autostart.desktop` (`nisse-panel --background`), packaged by `nisse-panel` 0.1-18 |
| the QML: no window until docked, Escape closes, focus after the slide | `panel/qml/Main.qml`, `panel/tests/tst_escape.qml` |
| a normal window where docking is not possible (X11, the offscreen test platform, `--windowed`, `--page`, `--demo-badge`) | `main.cpp` |

Knock-on changes: the desktop notice for a waiting approval is held back only while the sidebar is **open and focused** (N-205); the
pinned panel launcher stays in the taskbar as the **opener** (launching it toggles the sidebar, and so does Meta+N); the panel now runs
from login, which it did not before (the approval notice and the taskbar badge only worked while the app happened to be open). The
count badge (N-207) sits on the pinned launcher while the panel runs; the tray item (N-415b) shows it too.

## OPEN: the keyboard does not reach the real panel in the live harness (state on 2026-11-19)

Everything above works on the real panel on the live session (`tools/vm/sidebar_check.py`: 10 of 12 checks): one instance, closed at
autostart, a second launch toggles it, `Show`, `Hide`, `ShowApprovals`, the pointer at the right edge opens it. **Typing and Escape do
not**: the Wayland trace (`WAYLAND_DEBUG=1`, filtered to `wl_keyboard`) shows the panel's surface gets `wl_keyboard.enter` on some maps
and no `wl_keyboard.key` at any time, while the simple probe (`tools/vm/sidebar_probe`, same layer-shell calls, same session, same
`sendkey` input) receives every key (`tools/vm/sidebar_focus_probe.py`: 3 of 3, mapped on screen or mapped slid out). Established:

- a surface only mapped (offscreen or on) is not given the keyboard unless it appears with nothing else holding it; the first live runs
  showed the Welcome Center keeping the keyboard and the keys landing in Konsole or KRunner;
- an `xdg_activation_v1.activate` request with the stale serial Qt sends (`set_serial(228, seat)`) was not honored; with no click and no
  launch token the harness cannot produce a valid one;
- mapping the surface fresh on every open (the current design: closed means unmapped) gives `wl_keyboard.enter` at the map when the
  pointer is over the sidebar, but still no key arrives afterwards, which the probe does not show;
- synthetic clicks (both the PS/2 `mouse_move` and the USB tablet) did not land where intended, so click-to-focus is untested.

What is NOT yet known: why the panel gets no key events after an enter when the probe does. Candidates not yet bisected: the panel's
`ApplicationWindow`, its app id (`nisse-panel`, with a global shortcut registered for it), the second instance launched from the
harness's shell. Fallback if it cannot be resolved: a frameless normal window with KWin rules (no taskbar, no switcher, kept above, at
the right edge), where focus works as for any window, at the price of KWin rules for position and a different slide.

## Bugs the tests found on the way

- reversing a slide halfway emitted stray margin values (QVariantAnimation re-interpolates the old progress on the new range): a visible
  flicker, found by `tst_sidebar` (the animation is now reconfigured with its signals blocked);
- a focus request made while the surface was still sliding was ignored (live check): focus is now requested after the slide ends and
  aimed at the chat input (this alone did not make keys arrive, see OPEN);
- the window-level Escape shortcut never fired while the chat field had the keyboard: handlers on the header, the pages and the footer
  now cover it (`tests/tst_escape.qml`).

## Checks

`tools/vm/sidebar_check.py ISO OUTDIR PANEL_BINARY LAYERSHELL_TGZ` runs the REAL panel on the live session and asserts through its own
D-Bus service: closed at autostart, one process, a second launch opens it, typing reaches the chat field, Escape closes, the pointer at
the edge opens it, `ShowApprovals` opens it, a launch toggles it closed, `--show`, `--hide` and a second autostart behave. The image
contents (the layer-shell plugin, the autostart entry) are asserted by `tests/iso/test_iso_contents.sh`.

Not yet seen: several monitors, Alt-Tab, the badge on the pinned launcher with a live daemon (N-219a goldens), an approval notice
actually clicked. Queued for the next ISO rebuild and GATE 3.
