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
| `grub-menu`, `grub-menu-live` | GRUB menu (N-502), installed system and live ISO (rows centered by padded titles, N-502c) | Ink background; the stacked logo with the name below, 230 px wide near the top; entries in plain words, the default as an Ember row with Ink text. Installed: **nisse**, **Start from Earlier Snapshots** (the snapshot menu of N-307), **Computer Settings** (the firmware entry) and **More Ways to Start** (the older kernels). Live ISO: **nisse**, **Computer Settings** (UEFI only) and **More Ways to Start** (check the media, basic graphics). The countdown line ("nisse starts in 4 s.") and bar, and a quiet hint "Press E to change how nisse starts.". No kernel versions, ids or options on the main screen (advanced ones stay one key away, Bert's 2026-11-15 note) |
| `plymouth-boot`, `-early`, `-late` | Plymouth (N-501) | Ink; the stacked logo 300 wide, centered a little above the middle; the boot bar below it. Three frames show the blocks moving |
| `splash-dark`, `splash-light` | Plasma splash after login (N-505) | solid Ink (or Paper on the light look); the nisse **n** with the tipped hat, 260 px, inside the comet ring (the N-404 spinner in Ember), centered. Nothing else |
| `login-dark`, `login-light` | Login screen (N-503) | the wallpaper (Fjell Layers) under a 50% Ink (or Paper) veil; a round avatar (220 px), the user name, a password field, an Ember **Log in** pill with Ink text (the light look: brick with Paper); keyboard layout bottom left, the small logo bottom center, restart and shut down bottom right |
| `lock-dark`, `lock-light` | Lock screen (N-504) | the wallpaper under a 50% veil; a large light-weight clock and the date, kept above the sun so they never cross it; the password field low in the screen; the small logo and name bottom left |
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
- The layout is for **1920 x 1080** (GRUB is asked for that mode first, then 1280 x 720, then the native one). Other sizes show the
  same layout at the same pixel sizes; a theme for them is ledger N-502b.

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

## Decisions and open points handed on

- The default entry is plain "nisse"; the snapshot entry is "Start from Earlier Snapshots" (Bert's wording, N-502); the older
  kernels are under "More Ways to Start". N-502 wired the real entries to these words.
- The avatar on the login mock is one of the 17 gnome avatars; the real login shows the user's own.
- The shut-down dialog's countdown text and the lock screen's "Type your password to unlock." are mock wording; the real Plasma
  strings are kept unless a screenshot shows them clashing.
- Plymouth and GRUB are dark in both looks (firmware and early boot have no light look); the four Plasma-session surfaces follow
  the look.
