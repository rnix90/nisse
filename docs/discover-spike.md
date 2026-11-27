<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Discover and the Update Path Spike

Ledger task N-508b (spike part), 2026-11-27. Question: Discover is kept (N-507). What does it offer for hiding or redirecting RPM
updates, so that nisse-update stays the one way system updates are applied? Everything marked "verified" was run in the build VM
(Fedora 44) or in a live session of the previous ISO.

## Why it matters

`nisse-update` (`docs/safe-apply.md`) does more than run dnf: it takes the before snapshot, applies, takes the after snapshot, arms the boot
fallback on the before snapshot, reboots on request, runs the health check after the reboot and rolls back by itself if the machine is
unhealthy. A system update started from Discover would skip all of that except, as verified below, the snapshot pair.

## What Discover is made of (verified, package contents of 6.6.4-1.fc44)

| Package | Holds | Update-relevant |
|---|---|---|
| `plasma-discover` | the app | only RECOMMENDS `plasma-discover-packagekit`, `plasma-discover-flatpak` and `plasma-discover-offline-updates` (nothing requires them) |
| `plasma-discover-packagekit` | `discover/packagekit-backend.so` and `discover-notifier/DiscoverPackageKitNotifier.so` | THE RPM path: the backend lists and applies RPM updates through PackageKit, and the notifier's PackageKit part raises the "updates available" notice |
| `plasma-discover-flatpak` | the Flatpak backend | Flatpak apps and their updates (not RPM) |
| `plasma-discover-libs` | the fwupd backend, the KNS parts, `kcm_updates.so` (System Settings, Software Update) | firmware updates through fwupd; the update settings |
| `plasma-discover-notifier` | `/etc/xdg/autostart/org.kde.discover.notifier.desktop`, `DiscoverNotifier` | the tray notice and the unattended-update option; works with whatever backends exist |

The image today (resolved with the real dnf solver) has `plasma-discover`, `-flatpak`, `-kns`, `-libs`, `-notifier`, `-packagekit` and
`PackageKit` 1.3.4, no `plasma-discover-offline-updates`.

## What switches exist (verified)

- There is NO setting in Discover to hide or redirect RPM updates. The settings its library carries are `UseOfflineUpdates` and
  `useUnattendedUpdates` (both about HOW updates are applied, not whether they are offered): an unattended Discover would apply RPM
  updates by itself.
- Removing the one package `plasma-discover-packagekit` removes the RPM backend and the notifier's RPM part together. Verified in a live
  session of the previous ISO with `rpm -e --nodeps plasma-discover-packagekit`: `plasma-discover --listbackends` no longer lists the PackageKit
  backend, still lists the Flatpak one, and Discover starts and draws its Updates page ("Up to date", no RPM updates), screenshot
  `docs/screenshots/n508b-discover-updates-after.png`. Nothing in the image requires that package, so the kiwi description can leave it
  out with an `<ignore>` as N-508 does for the others (the dependency solver test proves it).
- Hiding the RPM updates while keeping the backend is not offered. The only other lever is polkit: PackageKit's update actions
  (`org.freedesktop.packagekit.package-update`, `system-update`, `upgrade-system`) could be denied, but Discover would still LIST the
  updates and then fail to apply them with an authorization error. Not tried; judged confusing.

## Does a Discover (PackageKit) update take a snapshot? (verified, with a caveat)

`docs/snapshots.md` listed this as unchecked. `tools/spike/pk_actions_probe.sh` in the build VM adds a marker hook to libdnf5's actions
plugin (the plugin nisse-snapshots uses) and installs one package with plain `dnf` and one through PackageKit (`pkcon`, the same
transactions Discover's backend starts). Both left the `pre_transaction` and `post_transaction` marker lines. So a PackageKit transaction DOES
take the snapshot pair. The caveat: the VM has PackageKit 1.4.0 (from updates) and the image has 1.3.4; not rerun on 1.3.4 (the image has
no `pkcon`). What a Discover update would still skip: arming the boot fallback, the reboot and the health check, the rollback, and
nisse-update's state (`/var/lib/nisse/update/state`), which would not know an update happened.

## What this leaves open

- Installing RPM apps through Discover goes away with the backend; Flatpak and KDE Store (KNS) installs remain. Whether that is wanted is
  Bert's call (N-508b design question).
- Firmware updates through fwupd stay in Discover (the backend is in `plasma-discover-libs`). They are not RPM updates and a snapshot cannot
  undo them; left alone unless Bert says otherwise.
- The tray notice from `DiscoverNotifier` keeps working for Flatpak and firmware updates; nisse's own update notices cover the system.
