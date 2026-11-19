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

## Decisions and open points handed on

- The default entry is plain "nisse"; the snapshot entry is named for what it is ("Earlier versions of nisse"). N-502 wires the
  real entries to these words (GRUB shows the entries from `nisse-boot` and the BLS entries).
- The avatar on the login mock is one of the 17 gnome avatars; the real login shows the user's own.
- The shut-down dialog's countdown text and the lock screen's "Type your password to unlock" are mock wording; the real Plasma
  strings are kept unless a screenshot shows them clashing.
- Plymouth and GRUB are dark in both looks (firmware and early boot have no light look); the four Plasma-session surfaces follow
  the look.
