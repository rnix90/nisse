<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Taskbar Pins Choice Spike

Ledger task N-508c (spike part), 2026-11-27. Bert (at N-508a): the live session pins the defaults (nisse panel, Files, Terminal, System
Settings), and the install lets the user tick which apps are pinned, as a checkbox list. Two things had to be found out: where such a
page can live, and how a choice made there reaches the new user's panel. Verified items were run in the build VM or a live session of the
previous ISO.

## How a choice can reach the panel

- The panel's default layout script (the one nisse-lookandfeel ships, `assets/theme/lookandfeel/layout.js`) cannot read a list from a file.
  Verified: the functions the shell's scripting engine offers (from the strings of the `plasmashell` binary in Fedora 44's plasma-workspace)
  include `fileExists`, `applicationPath`, `defaultApplication`, `userDataPath`, `loadTemplate`, `panelById` and `panelIds`, and NO `readFile`.
  The sketch in the ledger ("the layout script reads a list the installer wrote") does not work.
- Plasma's own scripting over D-Bus does work on a running shell. Verified in a live session (`tools/vm/pins_script_probe.py`, 3 of 3):

  ```
  busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s '<script>'
  script: panelIds.forEach(function(id){ panelById(id).widgets("org.kde.plasma.icontasks").forEach(function(w){
            w.currentConfigGroup=["General"]; w.writeConfig("launchers", [ ... ]); w.reloadConfig(); }) })
  ```

  The taskbar redrew at once and `launchers` in `plasma-org.kde.plasma.desktop-appletsrc` read back as exactly the new list (Kate in,
  the terminal and the browser out); screenshots `docs/screenshots/n508c-pins-script-before.png` and `-after.png`. So a small first-login
  step can set any list of pins, for any user, without touching the layout script.
- Therefore the live session keeps the layout script's four defaults (nothing reads a choice there), and an installed system gets the
  chosen list from a per-user first-login step that runs once.

## Where the page can live

- The installer in the image is Anaconda's WebUI (`docs/install-choices.md`). Adding a page means forking the WebUI: its node toolchain, an
  npm install of upstream's lockfile and a bundle rebuild on every Fedora update. The earlier decision defers that "until a choice needs the
  installer" (N-518).
- nisse's own first-boot wizard (`nisse-setup`, a fork of Plasma Setup) already runs at the end of every install, before the first login. Its
  pages are KPackages; the choices page (N-306e) renders the manifests of `nisse-choices` (kinds: bool as a switch, enum as radio buttons,
  text as a field) and writes answers through a root helper (`org.nisse.setup.setchoice`), so kickstart, import and export (N-517a) work for
  free. A pins page there needs a fourth kind, a list of checkboxes, in the engine and in the page.
- The wizard runs as the special user `nisse-setup` with system data directories, so it can list the installed launchers (visible ones only,
  N-508).

## Decisions (Bert, 2026-11-27)

- The page lives in the first-boot wizard (he first picked Anaconda's WebUI, then confirmed the wizard once the fork cost and N-517's earlier
  ruling were put to him: only a choice that must come before partitioning, such as N-518's encryption, needs Anaconda).
- The list shows every installed app that has a visible launcher, with a search field; the four defaults are ticked.
- The page comes AFTER the preferred-app selections (a different browser, N-507b) so that what those choices install is in the list.
- The live session keeps the four defaults.

## Built (N-508c)

- `nisse-choices` 0.1-2: a new kind, `multi` (a list of values), see `docs/install-choices.md`.
- `nisse-lookandfeel` 0.2-10: the manifest `90-taskbar-pins.toml` (order 90, after every other choice; tests/rpm/test_taskbar_pins.sh keeps it
  last), `nisse-taskbar-pins` (root: writes `/etc/nisse/taskbar-pins`, one pin per line, 0644, validated again), and
  `nisse-apply-taskbar-pins` with its autostart entry: at the start of a Plasma session, once per user (a marker under the user's state
  folder), it sends Plasma the script above. It replaces the pins only on a panel that still has the layout's default pins, so a user's own
  changes are never touched; it retries while the shell or the panel is not up (the script prints how many Task Manager widgets it found
  and changed); with no pins file (the live session) it does nothing.
- `nisse-setup` 0.1-3: the page `org.nisse.setup.taskbar` (weight 170), `ChoicesUtil.launchers()`, the listing of launchers, and the root helper
  passing an empty value and up to 4096 characters on to the engine (the engine validates strictly).
- An existing user: after an update the next `nisse-choices apply` writes the pins file and the user's next login applies it, but only if
  the panel still has the default pins.

## Proof

`tests/rpm/test_taskbar_pins.sh` (scripts, manifest, order), the engine's Rust tests (21 and 9, four new), the fork's C++ tests
(`tests/e2e/test_nisse_setup_unit.sh`: the helper, the parser, the launcher listing), `tests/e2e/test_nisse_setup_taskbar_page.sh` (the tick
logic, and the page rendered offscreen from the built RPM against a stand-in engine and a stand-in for the wizard's `SetupModule`: its rows, the
ticks, the refresh when opened again, and the picture `docs/screenshots/n508c-taskbar-page.png`, an unthemed test render, not the wizard's
look), and `tools/vm/pins_choice_check.py` (15 of 15 in a live Plasma session of the previous ISO with the real engine: the live defaults hold,
`nisse-choices set` and `apply` write the file, the first-login step changes the real panel once, a changed panel is left alone;
`docs/screenshots/n508c-pins-choice-after.png`).

## Not verified

The rebuilt ISO and a real first boot through the wizard (the page was shown offscreen with stand-ins, not in the wizard's own window and
look); the choice reaching a second user created later (the step is per user by design, tried here for one); the wizard page with a real
icon theme; N-507b's browser choice does not exist yet, so "an app an earlier choice installed" is shown with a stand-in app appearing
while the page is open.
