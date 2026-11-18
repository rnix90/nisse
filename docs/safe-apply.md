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

## The other commands

- `nisse-apply-updates status` prints the state file (`state=idle` when there is none).
- `nisse-apply-updates verified` is what the health check (N-309) calls once the new system is good: it runs
  `nisse-boot clear` (disarm GRUB, mark the boot good) and sets the state to `idle`, `last=verified`. With nothing pending
  it does nothing.
- `nisse-apply-updates reboot` reboots, only while an update waits for verification.

## Tests

| Test | Where it runs | What it proves |
|---|---|---|
| `tests/shell/test_nisse_apply_updates.sh` | anywhere | the flow, its order (snapshot, hardware, dnf, post snapshot, arm), every refusal, each failure arming nothing and rebooting nothing, nothing-to-update, status, verified, reboot, against fakes |
| `tests/shell/test_snapshot_scripts.sh` | anywhere | the dnf hook stands aside when safe-apply is running |
| `tests/rpm/test_nisse_update.sh` | build VM | the package contents and requirements, rpmlint |
| `tests/e2e/test_apply_updates.sh` | host (QEMU, installed disk) | the real dnf, snapper and GRUB: an update from a local file repository ends pending-verify with GRUB armed on the before snapshot, the packages really changed, the machine survives the reboot, and `verified` finishes it; a failing update arms nothing |
| `tests/iso/test_iso_contents.sh` | ISO rebuild (queued) | the package is in the image |

## Handed on

- N-309 runs the checks after the reboot and calls `nisse-apply-updates verified` (or lets the watchdog act).
- N-310 uses `state=pending-verify` and `nisse-boot status` to decide when to roll back.
- **After a fallback boot the real root's state still says `pending-verify`.** GRUB started the before snapshot (read-only,
  its own copy of the state directory predates the update), and nobody can edit the real root from there. Once the machine is
  back on the normal root, N-310 must settle it (roll back properly, or record the failed update) and not leave it pending.
  The end-to-end test (`tests/e2e/test_apply_updates.sh`) proves the fallback itself: an update that is never verified boots
  the before snapshot by itself, with the old package version.
- N-703/N-704 decide when it runs and when it may reboot; the panel and the AI will call it through the daemon's sudo
  helper path.
