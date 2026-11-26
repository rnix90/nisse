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

**What GRUB can do (to verify in N-502, as the ledger says):** a GRUB theme has a `progress_bar` component that it fills as the
menu timeout runs out, so the GRUB mock shows the same track as that **countdown** ("nisse starts in 4 seconds"). GRUB cannot animate
the sliding blocks; Plymouth does. If N-502 finds the countdown bar unusable, the bar stays on the Plymouth screen only, with
Bert's approval (the ledger's rule).

## The screens

| Mock | Surface | What it shows |
|---|---|---|
| `grub-menu` | GRUB menu (N-502) | Ink background; the stacked logo with the name below, 230 px wide near the top; three entries in plain words, the default as an Ember row with Ink text: **nisse**, **Earlier versions of nisse** (the snapshot menu of N-307), **Computer settings** (the firmware entry); the countdown line and bar; a quiet hint "Press E to change how nisse starts". No kernel versions, ids or options on screen (advanced ones stay one key away, Bert's 2026-11-15 note) |
| `plymouth-boot`, `-early`, `-late` | Plymouth (N-501) | Ink; the stacked logo 300 wide, centered a little above the middle; the boot bar below it. Three frames show the blocks moving |
| `splash-dark`, `splash-light` | Plasma splash after login (N-505) | solid Ink (or Paper on the light look); the nisse **n** with the tipped hat, 260 px, inside the comet ring (the N-404 spinner in Ember), centered. Nothing else |
| `login-dark`, `login-light` | Login screen (N-503) | the wallpaper (Fjell Layers) under a 50% Ink (or Paper) veil; a round avatar (220 px), the user name, a password field, an Ember **Log in** pill with Ink text (the light look: brick with Paper); keyboard layout bottom left, the small logo bottom center, restart and shut down bottom right |
| `lock-dark`, `lock-light` | Lock screen (N-504) | the wallpaper under a 50% veil; a large light-weight clock and the date, kept above the sun so they never cross it; the password field low in the screen; the small logo and name bottom left |
| `logout-dark`, `logout-light` | Log out, restart, shut down (N-504) | the wallpaper under an 82% veil; "What would you like to do?"; three round buttons (Log out, Restart, Shut down, the default selected in Ember with an Ink icon); the countdown line and **Cancel** |

Colors are palette colors only (tested). The name is lowercase everywhere ("nisse starts in 4 seconds", "Earlier versions of nisse").
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

## Decisions and open points handed on

- The default entry is plain "nisse"; the snapshot entry is named for what it is ("Earlier versions of nisse"). N-502 wires the
  real entries to these words (GRUB shows the entries from `nisse-boot` and the BLS entries).
- The avatar on the login mock is one of the 17 gnome avatars; the real login shows the user's own.
- The shut-down dialog's countdown text and the lock screen's "Type your password to unlock" are mock wording; the real Plasma
  strings are kept unless a screenshot shows them clashing.
- Plymouth and GRUB are dark in both looks (firmware and early boot have no light look); the four Plasma-session surfaces follow
  the look.
