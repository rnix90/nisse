# Boot recovery: snapshots in the GRUB menu and the boot counter (N-307)

The `nisse-boot` package is the backstop under the rollback net: a way to start an earlier snapshot from the GRUB menu,
and a way for GRUB to do it by itself when a machine keeps failing to boot. It sits under N-308 (safe-apply arms it),
N-309 (the health check clears it) and N-310 (the watchdog rollback). The layout it works on is `docs/storage-spike.md`
and the snapshots are `docs/snapshots.md`.

## What was verified (an installed nisse disk in QEMU, Fedora 44, GRUB 2.12, snapper 0.13)

| Question | Finding |
|---|---|
| Does Fedora offer a snapshot boot menu (grub-btrfs)? | No. Neither `grub-btrfs` nor a snapper GRUB plugin is in the Fedora 44 repositories. |
| Does Fedora offer boot counting for GRUB? | Yes, in `grub2-tools`: `/etc/grub.d/08_fallback_counting` counts `boot_counter` down on every boot that never set `boot_success`, and at 0 sets `default=1`. It was written for ostree, where entry 1 is the previous deployment. On nisse entry 1 is the rescue entry or an older kernel on the same broken root, so it is not a rollback. greenboot (in Fedora) only adds the same GRUB snippet and gates its rollback trigger on `/run/ostree-booted`, so it is left out. |
| Does a snapshot boot? | Yes. `rootflags=subvol=root/.snapshots/N/snapshot` on the kernel line boots to the login screen with network and the display manager. The snapshot is read-only, so the system comes up "degraded" (logrotate, flatpak and plocate services fail). Good for looking around and as an emergency way in, not for daily use. |
| Can GRUB save its variables on a nisse install? | **No, as installed.** The installed `grubenv` carries `env_block=512+1`; with it GRUB writes `next_entry`, `boot_counter` and `boot_success` to that raw block (inside the ext4 reserved area) instead of the file, so none of them was ever saved: a one-shot entry booted twice, and nothing counted. `grub2-editenv - unset env_block` fixes it (checked: the one-shot entry is then used once and the counter counts). Where it comes from is not verified; `nisse-boot-setup` removes it on every boot. |
| Can the snapshot entries be BootLoaderSpec files? | **No.** `grub2-mkconfig` rewrote the `options` of every file in `/boot/loader/entries`, including a snapshot entry, which kept its snapshot title and booted the normal root. The entries live in `/boot/grub2/nisse-boot.cfg`, read by a static snippet. |
| What if the entry file is bad? | A garbage file inside a submenu left the machine at the GRUB menu with the fallback armed (nobody to press a key). With the rollback entry's commands in the static snippet and the file only setting variables, a garbage file and a missing kernel both end in a normal boot (GRUB's own `fallback=0`). |
| Which kernel boots a snapshot? | The one whose modules the snapshot holds. A snapshot taken before a kernel update booted with the new kernel from `/boot` dropped to emergency mode (root locked); with the old kernel it booted. Entries pin the newest kernel in the snapshot that `/boot` still has, and a snapshot with none is not offered. |
| Does `snapper rollback` work here? | Not as is: "Cannot detect ambit since default subvolume is unknown" (the default subvolume is the top level, the system boots by an explicit `subvol=root`). With `--ambit classic` it works and sets the default subvolume to a new writable copy, **but the next boot still used `subvol=root`**: the kernel option wins. So N-310 needs its own rollback step (new writable subvolume plus the entry options), not `snapper rollback`. |
| Does a guest reboot work in this QEMU setup (WHPX)? | No: both `reboot` and the monitor's `system_reset` hang at a blank screen. `tools/vm/vmserver.py` power-cycles instead (stop the process, start it on the same disk and firmware variables). |

## How it works

| Piece | What it does |
|---|---|
| `/etc/grub.d/09_nisse_fallback` | After Fedora's counting: when `boot_counter` is -1 (the countdown ran out), `boot_success` is 0 and `nisse_fallback` is set, `default` becomes that entry and `fallback=0` names the first entry as GRUB's own way out. |
| `/etc/grub.d/11_nisse_snapshots` | The "nisse snapshots" submenu (from `nisse-boot.cfg`, if it exists) and the "nisse rollback boot" entry (if `nisse-rollback.cfg` exists, so it is in the menu only while armed). Static: nothing here changes when snapshots do. |
| `nisse-boot sync` | Writes `/boot/grub2/nisse-boot.cfg`: the 10 newest snapshots whose kernel is still in `/boot`, newest first, titled `#N date description`. Atomic, syntax-checked with `grub2-script-check`, unchanged content is not rewritten. |
| `nisse-boot arm [--tries N] SNAPSHOT` | For N-308. Writes the rollback file, protects the snapshot from snapper cleanup, then arms GRUB last (`boot_counter=N`, `boot_success=0`, `nisse_fallback`). Default N is 3: three boots in a row that never finish, and the fourth starts the snapshot. |
| `nisse-boot clear` | For N-309. Disarms GRUB, removes the rollback file, hands the snapshot back to cleanup and sets `boot_success=1`. Safe to call when nothing is armed. |
| `nisse-boot reconcile` | Drops an arm that GRUB no longer has. After a fallback boot the running system is a read-only snapshot: `nisse-boot clear` there can disarm GRUB (its variables are on `/boot`, a separate writable partition) but cannot remove the real root's state file or release the snapshot, so the next normal boot's setup run finishes the job. |
| `nisse-boot status` | `armed`, `snapshot`, `tries-left` or `fell-back`, `boot-success` as key=value lines. |
| `nisse-boot-setup.service` | Every boot of an installed system: remove `env_block`, reconcile a stale arm, regenerate `grub.cfg` once if it lacks the snippets (Fedora does not regenerate it when a package adds one), write the menu. Never stops a boot. |
| `nisse-boot-sync.path` | Watches `/.snapshots` and refreshes the menu when a snapshot appears or goes. |
| user unit drop-in | While armed, Fedora's `grub-boot-success.service` (it sets `boot_success=1` two minutes after any login) does not run, so it cannot hide a boot that hangs after the login. Only `nisse-boot clear` says the boot was good. |

Counting, as verified: arm with `--tries 3` and the first three boots start normally (the counter goes 2, 1, 0) and the
fourth starts the snapshot (the counter shows -1); it keeps starting the snapshot until `nisse-boot clear`.

## Limits, said plainly

- **A hung boot does not reboot itself.** The counter moves once per GRUB pass. A machine that hangs before or after the
  login needs a power-cycle (or the watchdog of N-310) to count; once it is back at GRUB it counts and falls back.
- **The snapshot boot is read-only.** Starting from the menu is for looking around and as an emergency way in. The real
  undo is the rollback of N-310.
- **A corrupted `nisse-rollback.cfg` cannot come from the tool**: it never puts a file in place that
  `grub2-script-check` rejects. If one is damaged anyway (or names a kernel that is gone) the machine still boots
  normally; both were checked.
- **A corrupted `nisse-boot.cfg` (the menu file) is not covered the same way.** It is only read when someone opens the
  "nisse snapshots" submenu, so it cannot affect an unattended boot, but a damaged one makes that submenu fail.
- **A machine with nobody at the keyboard and a snapshot that cannot mount** (for example deleted by hand) boots the
  snapshot entry every time until `nisse-boot clear` or a person picks another entry. `arm` protects the snapshot from
  cleanup; it cannot stop `snapper delete`.
- **`/boot` is shared.** A kernel removed from `/boot` (Fedora keeps three) takes its snapshots out of the menu at the next
  `sync`.

## Tests

| Test | Where it runs | What it proves |
|---|---|---|
| `tests/shell/test_nisse_boot.sh` | anywhere | sync, arm, clear, status, fixenv and the setup script against a fake snapper, grub2-editenv and /boot: the file formats, the 10-entry limit, kernel pinning, refusal of bad input, GRUB armed last, bad files never put in place |
| `tests/rpm/test_nisse_boot.sh` | build VM | the package contents, requirements, units and presets, the snippets pass `grub2-script-check`, rpmlint |
| `tests/e2e/test_boot_fallback.sh` | host (QEMU on an installed disk) | the real GRUB: a snapshot picked from the menu by keyboard boots; a counted failure falls back after the armed tries; the unarmed and the armed-then-cleared controls do not; the success timer is held while armed; a garbage file and a missing kernel boot normally |
| `tests/iso/test_iso_contents.sh` | ISO rebuild (queued) | the package, the snippets, the units and the preset are in the image |

## Handed on

- N-308 arms it after the update snapshot (`nisse-boot arm SNAPSHOT`) and reboots; N-309's health check calls
  `nisse-boot clear` when it passes; N-310 adds the writable rollback (`snapper rollback` does not apply, see the table).
- The first boot of an installed image regenerates `grub.cfg` once; a hand check on a real graphical install is queued.
