# nisse changes to Plasma Setup 6.8.3

One row per changed file. Newest at the bottom. `tests/repo/test_nisse_setup_fork.sh` checks this list against the git history.

| File | Change | Why |
|---|---|---|
| `src/qml/LandingComponent.qml` | the landing page wallpaper is `wallpapers/nisse/contents/images(_dark)/` (the nisse-wallpaper package); the welcome text says "Welcome to nisse" for desktop and mobile | the first screen a person sees is nisse's, not KDE's Next wallpaper or "Plasma Desktop" |
| `src/qml/Main.qml` | window title "nisse Setup" (headline case, N-501c) | branding |
| `src/main.cpp` | about data name "nisse Setup", tagline "Make nisse yours", the autologin option text | branding (the application id `plasma-setup` is renamed in a later commit) |
| `modules/prepareutil/prepareutil.cpp` | the light and dark toggle applies `org.nisse.desktop` (dark, the default) and `org.nisse.desktop.light`; dark is recognised by the `NisseEmber` color scheme | a new user must get the nisse look, not Breeze (upstream) or the Fedora look (Fedora's patch) |
| `modules/prepareutil/colorssettings.kcfg` | the default color scheme is `NisseEmber` | nisse is dark by default |

## System-visible renames (scripted: `tools/fork/nisse_setup_rename.py`, decision of Bert 2026-11-18)

Only what is visible on an installed system changes; KDE's internal QML module URIs (`org.kde.plasmasetup...`, also in each module's
`X-KDE-ParentApp`), the C++ names and the macro names stay so a newer upstream merges easily. The script is idempotent and fails
loudly if a line moved; replay it onto a fresh upstream import before re-applying the look patches above.

| File | Change | Why |
|---|---|---|
| `files/nisse-setup.service.in` | renamed from `files/plasma-setup.service.in`; runs `nisse-setup-bootutil`, skipped once `/etc/nisse-setup-done` exists | the first-boot service is nisse's |
| `files/nisse-setup-polkit.rules` | renamed from `files/plasma-setup-polkit.rules`; the user is `nisse-setup`, the actions are `org.nisse.setup.*` | polkit lets only the wizard's user run the helper's actions |
| `files/nisse-setup-sysuser.conf` | renamed from `files/plasma-setup-sysuser.conf`; user `nisse-setup`, home `/run/nisse-setup` | the wizard's special user |
| `files/nisse-setup-tmpfiles.conf.in` | renamed from `files/plasma-setup-tmpfiles.conf.in`; everything under `/run/nisse-setup` | the wizard's home and session settings |
| `files/nisse-setup.desktop.in` | renamed from `files/plasma-setup.desktop.in`; runs `nisse-setup`, name "nisse Setup" | the autostart entry of the wizard's session |
| `files/nissesetuprc` | renamed from `files/plasmasetuprc`; installed as `/etc/xdg/nissesetuprc` | the wizard's admin config (the first user's groups) |
| `files/CMakeLists.txt` | installs the renamed files, the data directory is `nisse-setup` | follows the renames |
| `files/kglobalaccelrc` | comment only | follows the renames |
| `config-plasma-setup.h.cmake` | the flag file is `/etc/nisse-setup-done`, the config file `nissesetuprc` | the paths compiled into the programs |
| `src/auth/org.nisse.setup.actions` | renamed from `src/auth/org.kde.plasmasetup.actions`; domain and action ids are `org.nisse.setup.*` | the privileged helper's KAuth actions |
| `src/auth/CMakeLists.txt` | the helper is `nisse-setup-auth-helper` for the domain `org.nisse.setup` | the privileged helper |
| `src/auth/authhelper.cpp` | helper id `org.nisse.setup`, home `/run/nisse-setup`, autologin file `99-nisse-setup.conf`, the executable `nisse-setup` | the helper acts on the renamed paths |
| `src/auth/authhelper.h` | comment only | follows the renames |
| `src/accountcontroller.cpp` | calls the helper `org.nisse.setup` | the caller of the helper |
| `src/displayutil.cpp` | calls the helper `org.nisse.setup` | the caller of the helper |
| `src/initialstartutil.cpp` | calls the helper `org.nisse.setup`; recognises the user `nisse-setup` | the callers and the user check |
| `src/initialstartutil.h` | comment only | follows the renames |
| `src/bootutil/CMakeLists.txt` | the program is `nisse-setup-bootutil` | what the service runs |
| `src/bootutil/bootutil.cpp` | autologin file `99-nisse-setup.conf`, user `nisse-setup` | the display manager logs the wizard's user in |
| `src/bootutil/bootutil.h` | comment only | follows the renames |
| `src/main.cpp` | application id `nisse-setup` | the application's id |
| `src/CMakeLists.txt` | the program is `nisse-setup` | what is installed to libexec |
| `README.md` | the service, flag file and config file names | the docs follow the renames |

## The install choices page (N-306e; nisse's code, in nisse-owned files and a few hooks into upstream's)

New files are nisse's own (GPL-2.0-or-later, `SPDX-FileCopyrightText: 2026 nisse`); upstream's files only get the hooks that call them.

| File | Change | Why |
|---|---|---|
| `src/auth/choiceset.h` | new: validates a choice id and an answer, then runs `nisse-choices set` and `apply --id` | what the root helper does for the page, testable without KAuth |
| `src/auth/choiceset.cpp` | new: the implementation (no shell, a time limit on the apply, one plain line for a failure) | the helper's logic |
| `src/auth/authhelper.h` | declares the action `setchoice` | the helper's new action |
| `src/auth/authhelper.cpp` | implements `setchoice` by calling `NisseChoices::setAndApply` | the helper's new action |
| `src/auth/CMakeLists.txt` | builds `choiceset.cpp` into the helper | follows the new files |
| `src/auth/org.nisse.setup.actions` | declares `org.nisse.setup.setchoice` (Policy=no: only the polkit rule's user may use it) | KAuth needs the action declared |
| `files/nisse-setup-polkit.rules` | the wizard's user may run `org.nisse.setup.setchoice` | the page must be allowed to ask |
| `modules/CMakeLists.txt` | builds the utility module and installs the page package `org.nisse.setup.choices` | follows the new module |
| `modules/choicesutil/CMakeLists.txt` | new: the QML utility module `org.nisse.setup.choicesutil` | the page's backend |
| `modules/choicesutil/choiceslisting.h` | new: reads `nisse-choices list --json` | the page's data |
| `modules/choicesutil/choiceslisting.cpp` | new: the parser, which gives no choices and a reason for any bad input | the page's data |
| `modules/choicesutil/choicesutil.h` | new: the singleton the page binds to (choices, count, error, setChoice, reload) | the page's backend |
| `modules/choicesutil/choicesutil.cpp` | new: runs the engine to list, and the KAuth action to answer | the page's backend |
| `modules/choices/CMakeLists.txt` | new: the page's QML module | follows the page |
| `modules/choices/metadata.json` | new: a KDE/PlasmaSetup page `org.nisse.setup.choices`, weight 150 (after Wi-Fi, before Finished) | where the page sits in the wizard |
| `modules/choices/metadata.json.license` | new: licence of the metadata | REUSE convention |
| `modules/choices/contents/ui/main.qml` | new: the page (a block per choice: radio buttons for an enum, a switch for a bool, a field for a text; hidden with no choices) | the page |
| `tests/CMakeLists.txt` | new: builds and registers the two tests | nisse's tests |
| `tests/choiceset_test.cpp` | new: the helper's logic against a fake engine and, with `NISSE_CHOICES_REAL`, the real one | nisse's tests |
| `tests/choiceslisting_test.cpp` | new: the parser | nisse's tests |
| `CMakeLists.txt` | adds the tests directory when testing is on | nisse's tests |
| `modules/choicesutil/launcherlisting.h` | new (N-508c): `listLaunchers`, the apps the taskbar page offers | the taskbar page's data |
| `modules/choicesutil/launcherlisting.cpp` | new (N-508c): reads the launchers a menu would show (applications only, not NoDisplay or Hidden, for KDE, TryExec present, the first folder wins), by name, after the two default entries | the taskbar page's data |
| `modules/taskbar/CMakeLists.txt` | new (N-508c): the taskbar page's QML module | follows the page |
| `modules/taskbar/metadata.json` | new (N-508c): a KDE/PlasmaSetup page `org.nisse.setup.taskbar`, weight 170 (after the choices page, before Finished) | the list of apps is built after the earlier choices |
| `modules/taskbar/metadata.json.license` | new (N-508c): licence of the metadata | REUSE convention |
| `modules/taskbar/contents/ui/main.qml` | new (N-508c): the page: a search field and a checkbox per installed app for each multi choice, listed when the page opens | the taskbar pins choice |
| `tests/launcherlisting_test.cpp` | new (N-508c): the launcher listing | nisse's tests |
| `modules/taskbar/contents/ui/pins.js` | new (N-508c): the tick logic of the taskbar page (a newly ticked app goes to the end, an unticked one is dropped, the answer is the items joined by commas) | testable on its own |
| `tests/tst_pins.qml` | new (N-508c): QtTest checks of `pins.js`, run by `tests/e2e/test_nisse_setup_taskbar_page.sh` | nisse's tests |
| `modules/choices/contents/ui/main.qml` | N-508c: leaves multi choices to the taskbar page | follows the new page |
| `modules/choicesutil/choiceslisting.cpp` | N-508c: reads a multi choice (a list of strings) | the taskbar pins choice |
| `modules/choicesutil/choicesutil.cpp` | N-508c: `launchers()` for the taskbar page; a multi answer is kept as a list | the taskbar pins choice |
| `src/auth/choiceset.cpp` | N-508c: an empty value and up to 4096 characters are passed on to the engine, which validates strictly | a list of pins and an empty list |
| `modules/choicesutil/extraslisting.h` | new (N-507d): `parseExtras` and `parseProgress`, what the options page reads | the options page's data |
| `modules/choicesutil/extraslisting.cpp` | new (N-507d): reads `nisse-extras list` and the progress file; a bad listing gives no options and a reason | the options page's data |
| `modules/choicesutil/choicesutil.h` | N-507d: `extras`, `busy`, `applyChoice` (an answer applied in the background), `reloadExtras`, `extrasProgress` | the options page, whose answer installs software for minutes |
| `modules/choicesutil/choicesutil.cpp` | N-507d: runs `nisse-extras list`, reads its progress file, and applies an answer without blocking the window (with an hour for the helper to answer) | the options page |
| `modules/extras/CMakeLists.txt` | new (N-507d): the options page's QML module | follows the page |
| `modules/extras/metadata.json` | new (N-507d): a KDE/PlasmaSetup page `org.nisse.setup.extras`, weight 160 (after the choices page, before the taskbar page) | what it installs must be there when the taskbar page lists apps |
| `modules/extras/metadata.json.license` | new (N-507d): licence of the metadata | REUSE convention |
| `modules/extras/contents/ui/main.qml` | new (N-507d): the page: a checkbox per option with its source, license and terms, an Accept dialog for the ones that carry a license, Install Selected and a progress list | the proprietary options menu |
| `modules/extras/contents/ui/extras.js` | new (N-507d): the page's logic (the answer in catalog order, ticks, progress counts), kept out of the QML so it can be tested | the proprietary options menu |
| `modules/taskbar/contents/ui/main.qml` | N-507d: only the taskbar pins choice is a taskbar list (the options choice is a list too) | the options page |
| `tests/extraslisting_test.cpp` | new (N-507d): QtTest checks of the options parsers | nisse's tests |
| `tests/tst_extras.qml` | new (N-507d): QtTest checks of `extras.js`, run by `tests/e2e/test_nisse_setup_extras_page.sh` | nisse's tests |
| `CMakeLists.txt` | the minimum versions are the release repository's Qt 6.10 and Frameworks 6.25 (upstream: 6.11 and 6.30) | the image is Fedora 44 release only; it builds and links on those (2026-11-19). Re-check the first-boot run at the ISO gate |
