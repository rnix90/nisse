# nisse changes to Plasma Setup 6.8.3

One row per changed file. Newest at the bottom. `tests/repo/test_nisse_setup_fork.sh` checks this list against the git history.

| File | Change | Why |
|---|---|---|
| `src/qml/LandingComponent.qml` | the landing page wallpaper is `wallpapers/nisse/contents/images(_dark)/` (the nisse-wallpaper package); the welcome text says "Welcome to nisse" for desktop and mobile | the first screen a person sees is nisse's, not KDE's Next wallpaper or "Plasma Desktop" |
| `src/qml/Main.qml` | window title "nisse setup" | branding |
| `src/main.cpp` | about data name "nisse setup", tagline "Make nisse yours", the autologin option text | branding (the application id `plasma-setup` is renamed in a later commit) |
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
| `files/nisse-setup.desktop.in` | renamed from `files/plasma-setup.desktop.in`; runs `nisse-setup`, name "nisse setup" | the autostart entry of the wizard's session |
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
