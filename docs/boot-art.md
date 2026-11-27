# Boot to desktop: the approved targets (N-412)

Bert approved the mock sheet on 2026-11-19 (`assets/art/boot/sheet.png`, full-size screens beside it). These are the targets
N-501 (Plymouth), N-502 (GRUB), N-503 (login), N-504 (lock and logout) and N-505 (Plasma splash) build, each checked with a VM
screenshot against its mock. The mocks are drawn by `tools/art/boot_mocks.py` from the Ember palette and the nisse assets
(`python tools/art/boot_mocks.py` rewrites them; 46 tests in `tools/art/tests/test_boot_mocks.py`). Nothing in `assets/art/boot`
ships.

## The boot bar (Bert: "a progress bar similar to Windows XP's boot")

A slim pill track (surface fill, outline-colored 2 px edge) with **three flat Ember blocks** that slide through it from left to
right, clipped to the track, and start again. No gradients (style guide). On the 1920 x 1080 mock: track 420 x 30 (Plymouth) with
6 px padding, blocks 34 wide and 7 px apart, radius 3. `xp_bar()` in `boot_mocks.py` is the drawing; the light look would use
the light accent.

**What GRUB can do (verified in the N-502 spike, GRUB 2.12, BIOS and UEFI):** a GRUB theme has a `progress_bar` component that it
fills as the menu timeout runs out, so the GRUB mock shows the same track as that **countdown** ("nisse starts in 4 s."). GRUB cannot
animate the sliding blocks; Plymouth does. It works, so the bar stays on the GRUB screen too (see "GRUB: built (N-502)" below).

## The screens

| Mock | Surface | What it shows |
|---|---|---|
| `grub-menu`, `grub-menu-live`, `grub-menu-1366x768`, `-1360x768`, `-1280x720`, `-1024x768` | GRUB menu (N-502), installed system and live ISO; the other sizes are the same menu on smaller screens (N-502b); rows centered by padded titles (N-502c) | Ink background; the stacked logo with the name below, 200 px wide near the top; entries in plain words, the default as an Ember row with Ink text. Installed: **nisse**, **Start from Earlier Snapshots** (the snapshot menu of N-307), **Computer Settings** (the firmware entry) and **More Ways to Start** (the older kernels). Live ISO: **nisse**, **Computer Settings** (UEFI only) and **More Ways to Start** (check the media, basic graphics). The countdown line ("nisse starts in 4 s.") and bar, and a quiet hint "Press E to change how nisse starts.". No kernel versions, ids or options on the main screen (advanced ones stay one key away, Bert's 2026-11-15 note) |
| `plymouth-boot`, `-early`, `-late` | Plymouth (N-501) | Ink; the stacked logo 300 wide, centered a little above the middle; the boot bar below it. Three frames show the blocks moving |
| `splash-dark`, `splash-light` | Plasma splash after login (N-505) | solid Ink (or Paper on the light look); the nisse **n** with the tipped hat, 260 px, inside the comet ring (the N-404 spinner in Ember), centered. Nothing else |
| `login-dark` | Login screen (N-503) | what Plasma Login Manager really draws (redrawn 2026-11-26 after the VM look; Bert chose to keep Plasma's own greeter): the nisse wallpaper (Fjell Layers, dark) blurred, the clock and date, a round avatar with its ring, the user name, a password box with its eye and arrow, and Sleep, Restart, Shut Down and Other at the bottom. No Log In pill, no logo, no light version (the greeter has one look, the system default, dark) |
| `lock-dark`, `lock-light` | Lock screen (N-504) | the screen nobody has touched, as Plasma really draws it (redrawn 2026-11-26 after the VM look; Bert chose to keep Plasma's own lock screen): the sharp nisse wallpaper under Plasma's clock and the date. No veil, no logo; the password box, the user and the buttons show after a key press and are Plasma's |
| `logout-dark`, `logout-light` | Log out, restart, shut down (N-504) | the wallpaper under an 82% veil; "What would you like to do?"; three round buttons (Log out, Restart, Shut down, the default selected in Ember with an Ink icon); the countdown line and **Cancel** |

Colors are palette colors only (tested). The name is lowercase everywhere ("nisse starts in 4 s.", "Start from Earlier Snapshots").
Paper on an Ember fill is only 3.1:1, so every Ember button and row carries Ink text; the light look's brick accent carries Paper.

## Plymouth: built (N-501)

The boot screen is the theme `nisse` in the package `nisse-plymouth` (a Plymouth **script** theme). `assets/art/plymouth/nisse/` holds
it: the pictures are drawn by `tools/art/plymouth_theme.py` from the same pieces as the mock (`xp_bar`, the stacked logo);
`nisse.plymouth` and `nisse.script` are written by hand. Photos from a real boot: `docs/screenshots/n501-plymouth-boot.png` and
`n501-plymouth-password.png`.

- **The bar** is a loop of 48 pre-drawn frames shown at 24 a second (two seconds a loop; the script has no clipping, so the frames keep
  the blocks inside the pill exactly as the mock draws them). It is an animation, never a measure: the script does not ask Plymouth
  how far boot has got and shows no percentage (a test keeps it that way).
- **Layout** is the 1920 x 1080 mock fitted into the screen and centered. Checked at 1920 x 1080 and at 3840 x 2160 (the 4K photo,
  shrunk to half, matches the same mock).
- **Also drawn:** a muted message line under the bar (a message such as "Checking the disk") and the password prompt for an encrypted
  disk (the prompt, the same pill as the field, one Ember dot per typed character), so an encrypted disk never meets a blank screen.
  The words are set in **Nunito** (N-501a, Bert's call) and always end with punctuation (Bert: a sentence we write ends with
  punctuation): `close_sentence` in the script leaves a text that already ends with . ! ? or : alone and gives any other a full stop.
  Plymouth's text plugin has no font search: it reads one fixed file, `/usr/share/fonts/Plymouth.ttf`, which dracut's own
  `plymouth-populate-initrd` makes a link to the system's default font. The package's dracut module (`46nisse-plymouth`, with
  `50-nisse-plymouth.conf` asking for it) removes that link and puts the theme's Nunito there. The theme carries a static Regular
  instance (`Nunito-Regular.ttf`, made by `tools/art/plymouth_theme.py`) because the variable file's own default is ExtraLight and
  the plugin cannot pick a weight; Nunito declares no Reserved Font Name, and its OFL.txt ships in the package.
- **How it becomes the default:** a first install of `nisse-plymouth` runs `plymouth-set-default-theme nisse` (it writes
  `/etc/plymouth/plymouthd.conf`; an upgrade leaves a theme the administrator chose alone). The scriptlet does not rebuild the
  initramfs: the image build (kiwi runs dracut) and the installer's initramfs build read the setting. Proven with dracut here: an
  initramfs built from the installed package holds all 53 theme files, `script.so` and a config naming `nisse`
  (`tests/iso/plymouth_initrd_check.sh`).
- **A finding that would have hidden the screen:** when any serial console is on the kernel line, Plymouth forces its plain text theme
  (its log says "serial consoles detected, managing them with details forced"), whatever theme is configured. The ISO's kernel line
  has `console=ttyS0` so the smoke test can follow the boot, so it now also has `plymouth.ignore-serial-consoles`
  (`build/render-kiwi.sh`; the ISO test refuses a menu entry that has a serial console without it). N-502 owns the final menu: the
  entry a person boots should not carry `console=ttyS0` at all.
- **How it was seen** without a 33-minute rebuild: `tools/vm/plymouth_overlay.sh` adds the theme to the live ISO's own initramfs,
  `tools/vm/plymouth_boot.sh` boots it headless and photographs the screen, and `tools/vm/plymouth_check.py` judges the photos against
  the mock (the bar's inside excepted) and the password screen (prompt, field, one dot per typed character). Take photos a few seconds
  apart that are NOT a multiple of two (the loop is two seconds, so photos two seconds apart show the same frame). Under this
  emulator Plymouth's graphics renderer sometimes fails to start ("Could not initialize heads" in its debug log, `plymouth.debug=
  stream:/dev/ttyS0` shows it) and the screen then shows Plymouth's grey text theme: about half the boots here. That is the renderer,
  before any theme loads; repeat the boot until the Ink screen draws. dracut stores the font under two names as a hard link, and an
  archive keeps the data with only one of them, so `tests/iso/plymouth_initrd_check.sh` unpacks both names before it compares.
- **After the next ISO rebuild:** `tests/iso/test_iso_contents.sh` (the boot screen block), then
  `tools/vm/plymouth_overlay.sh ISO DIR --plain`, `tools/vm/plymouth_boot.sh` and `tools/vm/plymouth_check.py boot` on the rebuilt ISO's
  own initramfs, and the same initramfs check (`tests/iso/plymouth_initrd_check.sh`) on an installed disk's initramfs.

## GRUB: built (N-502)

The theme is `nisse` in the package `nisse-grub-theme`; `assets/art/grub/nisse/` holds it. `tools/art/grub_theme.py` draws it from the
same Ember pieces as the mock (Pillow, no browser) and writes `theme.txt`; the two static Nunito files in the folder become GRUB's
`.pf2` fonts when the package is built (`grub2-mkfont`), and GRUB's own `unicode.pf2` is copied in for the editor (E) and the command
line (C). `grub_check.py` judges photos against the mock (where the words are, including that every row's words are centered).

**What the spike found (GRUB 2.12, BIOS and UEFI, Fedora 44), all built into the tests:**

- GRUB draws the **first-listed** component of `theme.txt` on top: the countdown bar is listed before the picture of its track.
- A progress bar is **at least 28 px high** whatever the theme says, so the track is 28 px (the mock's was 26). Its fill sits inside the
  border of its frame pieces: the frame is nine invisible 6 px pieces, the track is a baked picture, the fill is Ember with 3 px corners.
- The selected row is a box drawn from nine pieces, as tall as the item plus two borders (14 px each): 68 px, 732 px wide, rows 84 apart.
  **Rows cannot be aligned** by the theme (GRUB's boot_menu has no such property). They are centered by **padding the titles** (N-502c):
  `tools/art/grub_theme.py` works out how many spaces put a title's middle on the row's middle from the font's advance widths
  (grub2-mkfont stores every advance as whole pixels: a Regular and a SemiBold space are 8 px, a Bold one 9, so the selected row is
  **SemiBold**, not Bold, or the padding would mean something different in the two states). The padded titles are in the live
  template and the grub.d snippets (tests keep them equal to the computed ones); the main kernel row's title comes from a
  BootLoaderSpec file, whose parser strips every space after the key, so it is padded with U+00A0 written as UTF-8 bytes. Measured
  in photos (BIOS and UEFI): every row's words are within 4 px of the screen's middle. Rows whose titles change (older kernels,
  dated snapshots) stay left-aligned, Bert's call.
- The countdown label takes one number (`%d`) and cannot say "1 second", so the unit is the short "s": **"nisse starts in 4 s."**
  (Bert's choice). The bar fills from the left as the time runs out.
- The signed UEFI GRUB has the png reader, `gfxmenu` and `gfxterm` built in, so nothing needs `insmod` under Secure Boot; GRUB's own
  hint lines do not show with a theme; hotkeys work (m opens More Ways to Start).
- **One layout for every screen size (N-502b).** GRUB cannot tell which video mode it got: gfxterm adds `;auto` to the mode list it is given
  (so asking for a mode never fails) and nothing reports the result (GRUB 2.12 source, confirmed in QEMU), so a theme per size chosen at run
  time is impossible. The mode list is `1920x1080,auto` (a 1080p screen is sharp, anything else gets its own mode). The pieces keep one size:
  logo 200 px, rows 60 px high 72 apart, row text 28 px (22 and 18 for the countdown and the hint), bar 490 x 28; only the vertical spacing
  follows the screen, because every `top` is a percentage of its height (logo 5%, rows 36%, countdown 76%, bar 82%, hint 93%; GRUB drops
  the fraction: 36% of 1080 is row 388). The four-row menu fits a **1280 x 720** screen with room to spare (the smallest supported size;
  1366 x 768, 1360 x 768 and 1024 x 768 fit too), and a 4K screen that offers no 1080p shows the same menu at the same pixel size, whole but
  small. The menu is about 13% smaller than the first approved mock (Bert agreed). The padding that centers the titles is the same number of
  spaces at any size (text and spaces scale together; the tests keep every title within 12 px). Photos from QEMU (BIOS and UEFI; the
  firmware's own list is overridden with `NISSE_GFXMODE` in `grub_overlay.sh`): `docs/screenshots/n502b-grub-uefi-1920x1080.png`,
  `-1280x720.png`, `-1024x768.png`; each passes `grub_check.py` at its own size. QEMU's display draws a 1366-wide mode as 1360 with a
  broken stride, so 1366 x 768 itself could not be photographed (the layout depends only on the height).

**The live ISO's menu** is nisse's own template (`build/kiwi/nisse/grub-x86.cfg.iso-template`; Fedora's vendored one stays as
published): nisse (the default, starts at once), Computer Settings (UEFI only), More Ways to Start (check the media, basic graphics, and
a serial-console entry; hotkey m, then s). kiwi copies the theme from `/usr/share/grub/themes/nisse` to `/boot/grub2/themes/nisse` on
the ISO (`<bootloader-theme>nisse</bootloader-theme>`). Without the theme on the media the same entries show in GRUB's text menu. The
development ISO's kernel line still has `console=ttyS0` for the tests (a release build must not: ledger N-918a).

**The installed system's menu** needed more than a theme, because Fedora's `blscfg` command makes one row per BootLoaderSpec file
("nisse (6.19.10-300.fc44.x86_64) 0.2") and has no option to hide or group them (the newer `--show-default` options are in a module
that does not register `blscfg`). What did not work, seen on an installed disk: a GRUB function named `blscfg` to take its place (the
command wins over a function of the same name). What does: `blscfg` reads the directory in the GRUB variable `blsdir`, so

- `nisse-boot menu` writes two directories of its own, made of **copies of the BootLoaderSpec files with a plain title**:
  `/boot/loader/nisse-main` (the newest kernel, "nisse") and `/boot/loader/nisse-more` (the older kernels, "Start nisse with Kernel
  X", and the rescue kernel, "Start nisse in Rescue Mode"), and two small GRUB files that set `blsdir` to them
  (`/boot/grub2/nisse-menu.cfg`, `nisse-more.cfg`). Fedora's own command builds the rows, so the root device, the options, the file's id
  (Fedora's saved default still finds it) and everything else are the file's own; only the title is nisse's. The include files are
  syntax-checked before they are put in place, and the directories go in first, the pointer last.
- `09_nisse_menu` (grub.d) runs `nisse-boot menu` and, if the pointer file is there, sources it before `10_linux`'s `blscfg` call:
  nisse's rows. No pointer file (nisse-boot missing, no entry files, a refused menu) means the stock list shows, so a machine always
  has kernel rows (checked: with the files removed the stock list boots). `98_nisse_menu_refresh` runs it again at the end of
  `grub2-mkconfig`, because `10_linux` rewrites the options of every entry file while it runs (after the first copy was made).
- `35_nisse_more_ways` adds the "More Ways to Start" submenu (hotkey m; its body sets `blsdir` and calls `blscfg`);
  `30_nisse_firmware` is "Computer Settings" (Fedora's id, `uefi-firmware`); the package switches Fedora's `30_uefi-firmware` off (a
  `%posttrans` and a trigger on grub2-tools, because an update gives the mode back); `11_nisse_snapshots` says "Start from Earlier
  Snapshots" and, for the armed fallback, "Go Back to the Last Good Version".
- A `kernel-install` plugin (`91-nisse-boot-menu.install`) rewrites the rows when a kernel is added or removed, and `nisse-boot-setup`
  writes them at every boot and regenerates a `grub.cfg` that predates the snippet.
- `01_nisse_theme` (in `nisse-grub-theme`) turns the theme on from `${prefix}/themes/nisse`, the boot partition, never the root
  subvolume (a rollback swaps that), keeps a serial console next to the screen, and uses the theme only if it is there;
  `nisse-grub-theme-install` copies the theme to the boot partition after the package is installed or updated and whenever `grub.cfg` is made.

**How it was seen** without a 33-minute rebuild: `tools/vm/plymouth_overlay.sh` adds the theme to the live ISO's own initramfs,
  `tools/vm/plymouth_boot.sh` boots it headless and photographs the screen, and `tools/vm/plymouth_check.py` judges the photos against
  the mock (the bar's inside excepted) and the password screen (prompt, field, one dot per typed character). Take photos a few seconds
  apart that are NOT a multiple of two (the loop is two seconds, so photos two seconds apart show the same frame). Under this
  emulator Plymouth's graphics renderer sometimes fails to start ("Could not initialize heads" in its debug log, `plymouth.debug=
  stream:/dev/ttyS0` shows it) and the screen then shows Plymouth's grey text theme: about half the boots here. That is the renderer,
  before any theme loads; repeat the boot until the Ink screen draws. dracut stores the font under two names as a hard link, and an
  archive keeps the data with only one of them, so `tests/iso/plymouth_initrd_check.sh` unpacks both names before it compares.
- **After the next ISO rebuild:** `tests/iso/test_iso_contents.sh` (the boot screen block), then
  `tools/vm/plymouth_overlay.sh ISO DIR --plain`, `tools/vm/plymouth_boot.sh` and `tools/vm/plymouth_check.py boot` on the rebuilt ISO's
  own initramfs, and the same initramfs check (`tests/iso/plymouth_initrd_check.sh`) on an installed disk's initramfs.

## The login screen: built (N-503)

**What Fedora 44 uses:** Plasma Login Manager 6.6.4 (`plasmalogin.service`, enabled by nisse-release; the notes were right). It is a fork of
SDDM with a new greeter: a Plasma session of its own, run as the user `plasmalogin` (home `/var/lib/plasmalogin`), whose screen is QML compiled
into `/usr/libexec/plasma-login-greeter`. Nothing in it can be re-laid-out without forking the package (Bert chose not to, 2026-11-26).

**What nisse sets, and where:**
- **Colors, font, icons, cursor: nothing to do.** The greeter reads `/etc/xdg/kdeglobals` like every Plasma session, so the NisseEmber colors, Nunito and
  the nisse icons already show (seen in the VM before any login change; `docs/screenshots/n503-login-before-fedora-*.png`).
- **Wallpaper:** `/usr/lib/plasmalogin/defaults.conf`, the distro defaults file the greeter reads under the administrator's `/etc/plasmalogin.conf`
  (shipped by `nisse-lookandfeel` 0.2-6, source `assets/theme/plasmalogin/defaults.conf`): `[Greeter] WallpaperPluginId=org.kde.image` and
  `[Greeter][Wallpaper][org.kde.image][General] Image=file:///usr/share/wallpapers/nisse`. The whole nisse wallpaper package is named, so the
  dark picture of the right shape is chosen by the dark color scheme. **Not** `/usr/lib/plasmalogin/plasmalogin.conf.d/`: that folder is the
  daemon's, and a wallpaper placed there is ignored (tried first in the VM). The KCM's "Apply Plasma Settings" copies a user's own
  kdeglobals into `/var/lib/plasmalogin/.config`, which would override these defaults; nisse does not do that.
- **No logo** (Bert's call): the greeter has no slot for one, so it would have to be painted into the wallpaper, and the greeter blurs the wallpaper
  as soon as a key is pressed or the mouse moves.
- **The greeter does not appear on the live ISO** (livesys logs in automatically); it is what an installed disk shows.

**Proof (VM, the installed disk with the package's file in place):** `docs/screenshots/n503-login-nisse-idle.png` and `-awake.png` against
the Fedora cityscape before (`n503-login-before-fedora-*.png`). `tools/vm/login_check.py --idle|--awake SHOT` judges a screenshot: dark, not
blue, the Ember sun (sharp when idle, a soft glow when awake) and the clock; tests keep it able to refuse Fedora's picture and a missing sun or clock.
`tests/e2e/test_login_screen.sh` runs it against a real boot of the installed disk with the built package.

**Replacing Fedora's file.** Fedora's `kde-settings-plasmalogin` (a package of one file) already ships `/usr/lib/plasmalogin/defaults.conf`,
naming Fedora's wallpaper, and plasma-login-manager recommends it. nisse-lookandfeel therefore `Provides` and `Obsoletes` it (the same
pattern as nisse-setup for plasma-setup) and kiwi ignores it; the e2e installs the package on a disk that has Fedora's and checks it is replaced.
**After the next ISO rebuild:** the login block of `tests/iso/test_iso_contents.sh` (the defaults file, no kde-settings-plasmalogin, the greeter is in the image).

## The lock screen and the logout screen: built (N-504)

**Lock screen (Bert: keep Plasma's own, wallpaper only).** Since Plasma 6.0 the lock screen's layout lives in the shell package
(`/usr/share/plasma/shells/org.kde.plasma.desktop/contents/lockscreen/`, plasma-desktop), and kscreenlocker's greeter loads it from there: a
look-and-feel cannot replace it, and a nisse layout would mean patching plasma-desktop. Its colors, Nunito and icons already come from
`/etc/xdg/kdeglobals`. The wallpaper was Fedora's cityscape again (seen in the live VM); `nisse-lookandfeel` 0.2-7 ships
`/etc/xdg/kscreenlockerrc` (source `assets/theme/xdg/kscreenlockerrc`): `[Greeter] WallpaperPlugin=org.kde.image` and
`[Greeter][Wallpaper][org.kde.image][General] Image=file:///usr/share/wallpapers/nisse`. A user's own `~/.config/kscreenlockerrc` still wins.

**Logout screen (Bert: nisse's own copy, matching the mock).** A look-and-feel DOES own `contents/logout/Logout.qml`.
`assets/theme/lookandfeel/logout/` (Logout.qml, LogoutButton.qml, timer.js) is a restyled copy of Breeze's (plasma-workspace 6.6.4) with the same
host contract (the signals and the context properties sdtype, maysd, canLogout, spdMethods, softwareUpdatePending and the reboot notes), so
every Breeze behavior stays: the software-update variants, the other-users warning, the firmware-setup note, the countdown, Escape. What
changed: the veil is the look's own window color at 82% (Ink in the dark look, Paper in the light one; Breeze's is hard-coded black at 85%);
the question "What would you like to do?" over the buttons (only when every option is offered); round buttons drawn in the content (circle
108 px at the default size, a thin ring, the one with the keyboard focus, the default, an Ember circle with an Ink icon from the Selection
colors); the countdown line under the buttons ("Shutting down in 21 seconds."); Cancel a plain Ember word; no avatar and name (the mock has
none). The words are plain English, not Plasma's translation catalog, so they end with punctuation (rule 13); this costs the translations,
which nisse does not have yet. One source file serves both looks (`org.nisse.desktop` and `.light`).
**Carrying it:** about 350 lines of QML to compare with Breeze's after each Plasma update (the contract above is what can break).

**Proof (live VM, `tools/vm/lock_logout_check.py ISO OUTDIR RPM`):** the built package is installed in a live session; the screen is locked
(idle, then awake after a key press with a password set so the box shows, then really unlocked by typing it), and the logout screen is
opened with every option, with the shut down countdown and with the log out countdown. Each photo is judged by `tools/vm/login_check.py`
(`--idle`/`--awake` for the lock screen, `--logout`/`--logout-all` for the logout screen: the Ink veil rather than black, the Ember default
circle, Cancel, the question), which tests keep able to refuse Fedora's cityscape and Breeze's black screen. Photos:
`docs/screenshots/n504-lock-nisse-*.png`, `n504-logout-nisse-*.png`, against `n504-*-before-*.png`.
**Not verified:** the light look's logout screen (same file, the light scheme's colors); the rebuilt ISO (the block in
`tests/iso/test_iso_contents.sh` is queued); an installed disk with another user logged in; a real click on the buttons (the keys and the
countdown are what the photos show). The Log Out button's icon is the nisse icon theme's own (a chevron in a ring), not the mock's door
and arrow: a question for the icon theme, not this screen.

## The Plasma splash: built (N-505)

**Before:** both nisse looks named Breeze's splash (`ksplashrc Theme=org.kde.breeze.desktop`), which shows "Plasma made by KDE" and KDE's logo.
**Now:** `contents/splash/` in both looks (`org.nisse.desktop` and `.light`, one source in `assets/theme/lookandfeel/splash/`): `Splash.qml` and two
single-color pictures, `images/n.svg` (the approved n with its tipped hat, `assets/logo/n/svg/nisse-n-reverse.svg`) and `images/comet.svg` (the N-404
comet, `assets/art/comet/svg/nisse-comet.svg`). The QML keeps Breeze's stages and fades (everything fades in at stage 2, the ring fades out at stage
5) and its fixed 2 s turn that does not follow the animation speed (and not at all with animations off). The colors come from the active color
scheme, so one file serves both looks: the Window background (Ink, or Paper), the text color for the n (Paper, or Ink), the highlight color for the
comet (Ember, or brick); the pictures are tinted with `Kirigami.Icon { isMask: true }`. Sizes are in grid units, not pixels (the n 14, the ring 24),
so it scales with the screen's scale factor, as Breeze's does. **No text and no KDE logo** (a test keeps it that way). Both looks' defaults and a new
system default `/etc/xdg/ksplashrc` (`Theme=org.nisse.desktop`) name it; the light look's defaults name `org.nisse.desktop.light`. Shipped by
`nisse-lookandfeel` 0.2-8.

**How ksplashqml really runs (read in plasma-workspace 6.6.4 and seen in the VM):** it is the only thing that plays a splash, and in
`--test` mode it steps its stages on a timer and quits at stage 6, about a second after it starts; the Ink window covers the screen at once and the
picture fades in over it. So the real run only ever shows the first moments of the fade, and Breeze's own splash would too. The proof therefore has
two parts (`tools/vm/splash_vm_check.py ISO OUTDIR RPM`, in a live session with the built package): the REAL `ksplashqml org.nisse.desktop --test` is
sampled every 0.12 s, and the Ink window is seen covering the screen; a copy of the installed splash with ONLY its timing changed (the fade made 40 ms,
the stage 5 fade removed, under `~/.local`) is sampled the same way, in the dark look and in the light look (the light color scheme applied first), and
`tools/vm/splash_check.py` judges the frames (Ink or Paper all round, the n and the ring in the middle, nothing else) and that the comet has turned
between them. 8 of 8 checks pass; photos `docs/screenshots/n505-splash-nisse-{dark,light}.png` and `n505-splash-real-ksplashqml-fade.png`. The live
session's own `~/.config/kdedefaults/ksplashrc` still said Breeze (the image was built before this package), so the system default is checked in a
clean home (`env -i`, the XDG paths a new user has).
**Not verified:** a real login on an installed disk (the splash there is driven by Plasma's start stages, not the test timer); the ISO (the splash block
in `tests/iso/test_iso_contents.sh` is queued); other screen sizes and scale factors; a user whose own `~/.config/ksplashrc` already names another splash.

## Decisions and open points handed on

- The default entry is plain "nisse"; the snapshot entry is "Start from Earlier Snapshots" (Bert's wording, N-502); the older
  kernels are under "More Ways to Start". N-502 wired the real entries to these words.
- The avatar on the login mock is one of the 17 gnome avatars; the real login shows the user's own.
- The shut-down dialog's countdown text and the lock screen's "Type your password to unlock." are mock wording; the real Plasma
  strings are kept unless a screenshot shows them clashing.
- Plymouth and GRUB are dark in both looks (firmware and early boot have no light look); the four Plasma-session surfaces follow
  the look.
