# nisse changes to Plasma Setup 6.8.3

One row per changed file. Newest at the bottom. `tests/repo/test_nisse_setup_fork.sh` checks this list against the git history.

| File | Change | Why |
|---|---|---|
| `src/qml/LandingComponent.qml` | the landing page wallpaper is `wallpapers/nisse/contents/images(_dark)/` (the nisse-wallpaper package); the welcome text says "Welcome to nisse" for desktop and mobile | the first screen a person sees is nisse's, not KDE's Next wallpaper or "Plasma Desktop" |
| `src/qml/Main.qml` | window title "nisse setup" | branding |
| `src/main.cpp` | about data name "nisse setup", tagline "Make nisse yours", the autologin option text | branding (the application id `plasma-setup` is renamed in a later commit) |
| `modules/prepareutil/prepareutil.cpp` | the light and dark toggle applies `org.nisse.desktop` (dark, the default) and `org.nisse.desktop.light`; dark is recognised by the `NisseEmber` color scheme | a new user must get the nisse look, not Breeze (upstream) or the Fedora look (Fedora's patch) |
| `modules/prepareutil/colorssettings.kcfg` | the default color scheme is `NisseEmber` | nisse is dark by default |
