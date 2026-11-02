# nisse-release

Release files for Nisse, derived from Fedora's `generic-release` (the package Fedora provides
for remixes that cannot use the trademarked `fedora-release`); the LICENSE is copied from
generic-release 44-0.2 (MIT).

## Presets

`90-default.preset`, `85-display-manager.preset` and `90-default-user.preset` are Fedora's own files from
`fedora-release-common 44-18` (MIT), unchanged except for a first provenance line, so Nisse enables the same services
as stock Fedora (tuned, thermald, systemd-oomd, flatpak remotes, audit rules, PipeWire for the session, and so on).
Nisse's deviations live only in `80-nisse-desktop.preset`, which sorts first and therefore wins:

- `plasmalogin.service`, `livesys.service`, `livesys-late.service` enabled (live media and the Plasma login).
- `plasma-setup.service` disabled (Nisse has its own first-boot flow).

To refresh after Fedora ships a new `fedora-release-common`: `dnf download fedora-release-common`, extract the three
files with `rpm2cpio | cpio -idm`, put the provenance line (with the new version) on top, and update the version in
`tests/rpm/test_nisse_release.sh`. Then compare the new enables against Nisse's deviations.

- `nisse-release`: `/usr/lib/os-release`, provides `system-release`.
- `nisse-release-common`: the other release files, systemd presets, the update channel file
  `/etc/nisse/channel` (`stable` or `daily`) and the two repo definitions. The repos ship
  disabled with a placeholder host until the GitHub-hosted channels exist.
