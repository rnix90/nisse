# Safe-apply: updating with a way back (N-308)

`nisse-apply-updates` (package `nisse-update`) is the update flow of the rollback net. It does not decide when to
update (the update policy, N-703, and the scheduled job, N-704, do), it does the update safely once asked. It sits on the
snapshots (`docs/snapshots.md`) and on the boot fallback (`docs/boot-recovery.md`); N-309 (health check) and N-310
(watchdog) read the state it leaves.

## What it does

    nisse-apply-updates run [--reboot] [--tries N] [--dnf-arg ARG]...

| Step | What happens |
|---|---|
| 1. A way back, or no update | Refuses on live media, on a root that is not btrfs, without the snapper root config, below 10% free space (the snapshot hook would skip there, and without a snapshot there is no way back), and while an earlier update is still pending verification. Nothing is touched when it refuses. |
| 2. Snapshot | A "before" snapshot (type pre, cleanup `number`, userdata `nisse=safe-apply`): the rollback target. The dnf hook of nisse-snapshots stands aside for this run (`NISSE_SNAPSHOT_SKIP`), so the change is not snapshotted twice. If the snapshot cannot be taken the update does not start. |
| 3. Hardware kernel | `nisse-hwroute` (when installed) keeps the kernel and drivers this machine needs in place (Surface, Intel MacBook). A failure stops the run. |
| 4. Packages | `dnf upgrade -y --refresh`, plus any `--dnf-arg`. A failure stops the run. |
| 5. Nothing changed? | Then the "before" snapshot is deleted again and the state is idle (`last=nothing-to-do`): no arm, no reboot. |
| 6. Pending verification | The paired "after" snapshot is taken, the state becomes `pending-verify`, and GRUB is armed on the "before" snapshot (`nisse-boot arm --tries N SNAPSHOT`, 3 tries by default). GRUB is armed last. |
| 7. Reboot | Only with `--reboot` (Bert's decision: a desktop is never restarted under open work; when the quiet updater may reboot is N-703). Otherwise it says a reboot is needed to finish and verify. |

A failure at any step records `state=failed` with a one-line `message=`, arms nothing, and never reboots, even with
`--reboot`: an update that could not be armed has no way back by itself. The snapshot number is in the state.

## The state file (`/var/lib/nisse/update/state`, key=value lines)

| Key | Meaning |
|---|---|
| `state` | `idle`, `running`, `pending-verify` or `failed` |
| `snapshot` | the "before" snapshot (the rollback target; the one GRUB is armed on) |
| `post-snapshot` | the paired "after" snapshot (may be empty if snapper could not take it) |
| `applied-at` | epoch seconds when the update finished (N-310's time limit counts from the reboot, not from this) |
| `changed` | how many packages are new or changed (the list is in `changed.txt` beside the state) |
| `kernel-changed` | `yes` when `kernel-core` is among them |
| `message` | the reason for a failure |
| `last` | in `idle`: `verified` or `nothing-to-do` |

## The health check (N-309)

`nisse-health-check` (same package) decides whether the machine that came up after an update is good. The unit
`nisse-health-check.service` starts after the graphical target on every boot, and does nothing unless
`state=pending-verify` (it logs "nothing to check").

    nisse-health-check run [--deadline SECONDS] [--force]      status

| Check (`/usr/lib/nisse/health.d/`) | Healthy means |
|---|---|
| `10-boot` | the default target is active, and the machine is not in rescue or emergency mode |
| `20-network` | NetworkManager runs and answers, and it lists every physical network interface the kernel has. **Bert's decision: the network STACK must work, not the internet**: a machine offline for any reason (no cable, a plane, the router off) is healthy, a broken driver or a broken NetworkManager is not |
| `30-services` | every unit in `/usr/share/nisse/health/services.d/*.list` is active (dbus-broker, systemd-logind, polkit, systemd-journald, NetworkManager) |
| `40-display` | for a graphical machine: the login manager runs without a restart loop (more than 2 restarts fails) and a greeter or user session exists on a seat (a serial or console login has no seat and does not count) |

- **A check is an executable** in that folder: exit 0 when healthy, otherwise non-zero with ONE line saying what is wrong. A
  package adds its own check, or a service list, without touching the runner (the AI daemon will add one).
- **A slow start is not a failure.** The runner goes through the checks again and again until all have passed or the
  deadline (180 s) is over; a check that has passed is not run again; a check that hangs is stopped after 20 s.
- **Healthy:** it writes `/var/lib/nisse/update/health` (`result=healthy`, `checked-at`, `boot-id`, `checks`) and calls
  `nisse-apply-updates verified`, which disarms the boot fallback. **Unhealthy:** `result=unhealthy`, `failed=` every failing
  check and a `message-NAME=` line with its reason, and the update stays pending with GRUB still armed. Acting on that is
  the watchdog's job (next section).
- No checks installed is a failure, not a pass. `status` prints the last result (`result=none` before any run). `--force`
  runs the checks without an update pending and without calling `verified` (for looking, and for the tests).

## The other commands

- `nisse-apply-updates status` prints the state file (`state=idle` when there is none).
- `nisse-apply-updates verified` is what the health check (N-309) calls once the new system is good: it runs
  `nisse-boot clear` (disarm GRUB, mark the boot good) and sets the state to `idle`, `last=verified`. With nothing pending
  it does nothing.
- `nisse-apply-updates reboot` reboots, only while an update waits for verification.

## The watchdog rollback (N-310)

Two tools, kept apart on purpose: `nisse-rollback` is the mechanism (also the engine of the panel's undo button, N-311),
`nisse-update-watchdog` is the policy (when to use it on an update). Bert's decisions, 2026-11-21: a **60 second countdown
with a notice** before anything happens, a **ten minute hang limit**, and an update that was rolled back is **not tried
again until it changes**.

### nisse-rollback: the swap

    nisse-rollback run SNAPSHOT [--reason TEXT] [--reboot]
    nisse-rollback list                       (N-311: the snapshots nisse made, one line each, for the panel's undo list)

`snapper rollback` does not work on this layout (docs/boot-recovery.md), so the rollback swaps subvolumes at the top level of
the btrfs file system and leaves fstab and the kernel line alone, because both say `subvol=root`. Proven on an installed disk
first (`tools/spike/rollback_swap_spike.sh`): renaming the running root works, `.snapshots` can be moved from one parent to
another, and the next boot with the unchanged `subvol=root` starts the restored system with the changed file gone and snapper
still listing every snapshot.

| Step | What happens |
|---|---|
| refuse | live media, a root that is not btrfs, snapshot 0 or a number that is not a snapshot, a snapshot whose kernel is no longer in `/boot` (a newer kernel against older modules ends in emergency mode), a default boot entry for another kernel with no boot entry for the snapshot's. Nothing is touched when it refuses. |
| 1. copy | a writable btrfs snapshot of the snapshot, `root.rollback-new` (a leftover of a crashed run is deleted first) |
| 2. record | written INTO the copy: `state=idle`, `last=rolled-back`, `rolled-back-at`, `snapshot`, `reason`, `rolled-back-from`, the failed update's fingerprint as `blocked-fingerprint`, its package list as `failed-changed.txt`, its health result as `failed-health`, and the arm record so the next boot's `nisse-boot reconcile` hands the snapshot back to snapper's cleanup. The failed update's files are read from the real root, never from the running system, so this also works from the fallback boot |
| 3. swap | `.snapshots` moves into the copy, the running root is renamed `root.failed-<time>`, the copy becomes `root`. The last two are consecutive renames: a machine that lost power exactly between them has no `root` until `mv root.rollback-new root` from a rescue shell (the message says so). Failing before them undoes what it did |
| 4. boot | the default boot entry goes back to the snapshot's own kernel if the failed update had installed a newer one; GRUB is disarmed (`nisse-boot clear`) only after the swap; older `root.failed-*` are deleted, only the newest is kept for inspection |
| 5. reboot | only with `--reboot` |

home, `var_log` and `var_cache` are separate subvolumes and are never touched (N-312 proves it with a data subvolume).
Moving `.snapshots` empties the running system's snapshot list for the seconds before the reboot, so `nisse-boot-sync.path`
removes the boot menu file; `nisse-boot-setup` writes it again at the next boot.

`nisse-rollback list` (root, through sudo) prints one line per snapshot nisse made, never the running system (0) or one made by
hand: `NUMBER;TYPE;PRE;EPOCH;BOOTABLE;USERDATA`. `TYPE` is pre, post or single; `PRE` is the pre snapshot a post one pairs with;
`EPOCH` is the time in seconds (snapper's own date column, read with `date -d`); `BOOTABLE` is `yes` or `no:REASON` (the same
kernel rule as the refusal above); `USERDATA` is snapper's "nisse=KIND, session=ID" text, where KIND is `ai-batch`, `safe-apply`
or `package-transaction`. It prints nothing and exits 0 on live media, on a root that is not btrfs and before snapper has its
root config, and fails with snapper's words if snapper fails. The daemon turns the lines into the undo list.

### nisse-update-watchdog: when

`nisse-update-watchdog.service` runs on every boot (enabled by the preset) and ends at once when there is nothing to do. It
acts in three cases, and in each one every person with an active graphical session gets a notice with a **Keep the update**
button and the countdown, then `nisse-rollback run SNAPSHOT --reason ... --reboot`:

| Case | Trigger |
|---|---|
| unhealthy | the health check of THIS boot ended `unhealthy` while the update still waits. The result says which boot it is about (`boot-id=`, the kernel's boot id); a result with another boot's id, or none, is not this boot's verdict. Not by comparing times: in the end-to-end test `chronyd` stepped the guest's clock forward by 658397 seconds (7.6 days; the test machine's clock restarts at a fixed date on every power cycle) within about half a minute of the boot, so a result written before the step was a week older than "now minus uptime", the time comparison called this boot's result stale, and the watchdog fell through to the hang limit. A machine whose clock is wrong at boot (a flat CMOS battery) does the same |
| hang | the machine has been up for 600 s and the update still waits for its verdict (the boot or the checks never finished) |
| fallback | GRUB fell back (`nisse-boot status` says `fell-back=yes`) and the running root is a snapshot: the watchdog settles it with a real rollback to that snapshot, so the machine does not stay on a read-only root |

Pressing the button keeps the update for the rest of this boot (`/run/nisse-update/cancelled`): the update stays
`pending-verify` and GRUB stays armed, so a machine that cannot boot still falls back; the next boot starts clean and asks
again. With nobody logged in there is nobody to ask and the countdown runs anyway. The notice goes through `runuser` to each
person's own session bus (`notify-send --wait --urgency=critical --action=cancel=...`); the login screen and text logins are
not told. A failed rollback fails the unit and leaves the state `pending-verify`.

After the reboot `nisse-update-notice` (an autostart entry at every KDE login) tells each person once, in plain words, that the
update was undone and why, and that their files were not changed; what a person has been told is one number in their own
`~/.local/state/nisse/update-notice-seen`.

### Not tried again until it changes

`nisse-apply-updates run` asks dnf which packages the upgrade would install, hashes the sorted list (`fingerprint=` in the
pending state) and a rollback carries it into the restored system as `blocked-fingerprint=`. While dnf offers exactly that
set, `run` skips (exit 0, state untouched apart from `skipped-at=`, a line saying why); different versions mean a new
fingerprint and the update goes ahead. If dnf cannot say, there is no fingerprint and nothing is blocked.

## Tests

| Test | Where it runs | What it proves |
|---|---|---|
| `tests/shell/test_nisse_apply_updates.sh` | anywhere | the flow, its order (snapshot, hardware, dnf, post snapshot, arm), every refusal, each failure arming nothing and rebooting nothing, nothing-to-update, status, verified, reboot, against fakes |
| `tests/shell/test_snapshot_scripts.sh` | anywhere | the dnf hook stands aside when safe-apply is running |
| `tests/shell/test_nisse_health.sh` | anywhere | each of the four checks, healthy and broken, and the runner (retries, a hanging check, no checks, nothing pending, --force), against fakes |
| `tests/rpm/test_nisse_update.sh` | build VM | the package contents and requirements, the checks executable, the unit, rpmlint |
| `tests/e2e/test_health_check.sh` | host (QEMU, installed disk) | the REAL checks on the healthy machine, the display and services checks failing when the login manager or polkit is stopped, a healthy update verifying itself after the reboot, an idle boot touching nothing, an update with a masked NetworkManager staying pending with the reasons recorded |
| `tests/e2e/test_apply_updates.sh` | host (QEMU, installed disk) | the real dnf, snapper and GRUB: an update from a local file repository ends pending-verify with GRUB armed on the before snapshot, the packages really changed, the machine survives the reboot, and `verified` finishes it; a failing update arms nothing |
| `tests/shell/test_nisse_rollback.sh` | anywhere | the swap on a directory standing in for the top level: the copy, the record in it, `.snapshots` moved, the failed root kept (only the newest), GRUB disarmed only after the swap, the default boot entry, every refusal leaving the top level as it was, a crashed run's leftover, a run from a snapshot boot |
| `tests/shell/test_nisse_watchdog.sh` | anywhere | each trigger (unhealthy this boot, a stale result ignored, the hang limit, the fallback boot, a snapshot picked from the menu left alone), the notice and its Cancel, no graphical user, two users, a failing rollback, the after-rollback notice shown once; a fake clock makes ten minutes take no time |
| `tests/e2e/test_rollback.sh` | host (QEMU, installed disk) | the real thing, twice: a broken update rolled back by the watchdog (old packages back, writable root, snapshots, GRUB disarmed, the record, home untouched, the same update skipped, a different one verified), and an update that never finishes booting, where GRUB falls back and the watchdog settles it |
| `tests/iso/test_iso_contents.sh` | ISO rebuild (queued) | the package is in the image |

## Handed on

- N-309 (done): the health check runs after the reboot and calls `nisse-apply-updates verified` when the machine is good.
- N-310 (done): the watchdog above. **After a fallback boot the real root's state said `pending-verify` and nobody could edit
  it from the read-only snapshot**: the watchdog now settles that with a real rollback (the record is written into the restored
  root from the top level), so nothing is left pending. The end-to-end test proves both the fallback and the settling.
- N-311 (done): the panel's undo button, in Settings under "System history" (`docs/panel-notes.md`), goes through the daemon
  (`ListUndo`, `Undo`, `docs/daemon-protocol.md`) to `nisse-rollback list` and `nisse-rollback run SNAPSHOT --reboot` with
  `sudo`; the confirmation says home and data are not covered and that the computer restarts at once. An undo by hand has no
  failed update behind it, so its record has no fingerprint and blocks no update. In limited sudo mode only `nisse-rollback list`
  is passwordless; the rollback asks in the password popup. N-312 proves the excluded subvolumes with a data subvolume.
- The notice's Cancel button and the after-rollback notice are checked in unit tests with a stand-in `notify-send`; a real
  click on a real Plasma notification is a GATE 3 hand check.
- N-703/N-704 decide when it runs and when it may reboot; the panel and the AI will call it through the daemon's sudo
  helper path.
