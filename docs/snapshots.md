# Snapshots around package changes (N-305)

The `nisse-snapshots` package takes a btrfs snapshot pair around every package transaction, keeps 20 pairs for 14 days,
and does nothing on live media or on a non-btrfs root. This page records what was verified, what was decided and how it
is wired. The root layout it sits on is `docs/storage-spike.md` (N-302).

## What was verified (Fedora 44 build VM, snapper 0.13.0, dnf5 5.4)

| Question | Finding |
|---|---|
| Does Fedora offer a package-manager snapshot hook for dnf5? | No. `python3-dnf-plugin-snapper` is a dnf4 plugin. dnf5 has the `actions` plugin (`libdnf5-plugin-actions`), which runs a command before and after each transaction. nisse uses that. |
| How does snapper count "20 pairs"? | `NUMBER_LIMIT` counts every pre and every post snapshot separately and keeps a pair together. Limit 5 left 6 snapshots (3 pairs) in a test of 8 pairs. 20 pairs is `NUMBER_LIMIT=40`; a test of 25 pairs left exactly 20 pairs. |
| Is there a "delete after N days" setting? | No. The number algorithm only keeps the youngest N. The 14-day rule is a small daily job (`nisse-snapshot-prune`). |
| Can the 5 GiB cap be a plain `SPACE_LIMIT=5G`? | The value is accepted and needs a btrfs quota group (`snapper setup-quota`). With quotas on and about 88 MB pinned against a 30 MB limit, snapper's `cleanup number` removed nothing, so enforcement could not be verified. |
| Can a size check work without quotas? | No. `btrfs filesystem du` reports "set shared" data that includes what the live system still uses, so it cannot tell what deleting the snapshots would free. Quota group `1/0` did show the right number (88 MB for about 84 MB pinned). |
| Does editing the config file take effect at once? | No. `snapperd` caches configs. The scripts call `snapper --no-dbus` so they always read the file. |

## Decisions (Bert, 2026-11-18)

1. **14-day age limit:** a daily prune timer deletes snapshot pairs older than 14 days (snapper's own hourly cleanup
   keeps the 20-pair count).
2. **5 GiB cap: dropped.** The only reliable measure needs btrfs quotas, which cost performance, and snapper's own
   enforcement is unverified. The N-302 retention decision is amended to **20 pairs and 14 days**. Instead of a size cap,
   the hook skips the pre snapshot (and says so in dnf's log) when `/` has less than 10% free, so snapshots do not fill
   a small disk. Quotas can be added later by a new decision if disks turn out to fill.

## How it is wired

| Piece | What it does |
|---|---|
| `nisse-snapshot-setup.service` | First boot of an installed system, once: if `/` is btrfs and there is no snapper `root` config, `snapper create-config /` and apply `/usr/share/nisse/snapshots/root.conf`. If applying fails the new config is deleted so the next boot retries. Skipped on live media. It never edits snapper's own `/etc/sysconfig/snapper`: `create-config` does that. |
| `root.conf` | Timed snapshots off, `NUMBER_LIMIT=40`, empty pre/post pairs removed after an hour. |
| `nisse-snapshots.actions` | `pre_transaction` and `post_transaction` lines for the dnf5 actions plugin, `enabled=host-only` so an image build in another installroot is not snapshotted. |
| `nisse-snapshot-hook pre` / `post` | Takes the pre snapshot (tagged `number`, userdata `nisse=package-transaction`), remembers its number in `/run/nisse-snapshots`, and takes the paired post snapshot. Never fails the transaction: a problem is a `log.WARNING` line and exit 0. |
| `nisse-snapshot-prune` (daily timer) | Deletes number-tagged pairs whose post snapshot is older than 14 days and unpaired old pre snapshots; never the active or default snapshot, never snapshots nisse did not make. |
| Presets | Enable the setup service, the prune timer and `snapper-cleanup.timer`; disable `snapper-timeline.timer` and `snapper-boot.timer`. |

## Tests

| Test | Where it runs | What it proves |
|---|---|---|
| `tests/shell/test_snapshot_scripts.sh` | anywhere | the three scripts against a fake snapper: skips, pairing, never failing a transaction, the age rule |
| `tests/rpm/test_nisse_snapshots.sh` | build VM | the package contents, requirements, units, presets, rpmlint |
| `tests/e2e/test_snapshots_btrfs.sh` | build VM (sudo) | the real snapper on a loop btrfs: setup applies the template, the hook brackets a change, 25 pairs shrink to 20, prune removes old pairs only |
| `tests/e2e/test_snapshots_dnf_hook.sh` | build VM (sudo) | dnf5 calls a hook once before and once after install and remove, in order |
| `tests/iso/test_iso_contents.sh` | ISO rebuild | the package, snapper, the actions plugin and the presets are in the image; no root config ships; no timed snapshots |

## Not yet verified

- A real package install on an installed btrfs nisse system taking a real pair through dnf5 (the install-to-disk
  harness, `docs/install-harness.md`); queued with the next ISO rebuild.
- That `snapper create-config /` works on the installer's `root` subvolume layout at first boot (same queue).
- Discover (PackageKit or dnf5daemon) transactions run the same actions plugin: unchecked.
- `/boot` is outside the snapshots (N-307 to N-310).
