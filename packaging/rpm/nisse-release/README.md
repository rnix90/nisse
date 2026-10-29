# nisse-release

Release files for Nisse, derived from Fedora's `generic-release` (the package Fedora provides
for remixes that cannot use the trademarked `fedora-release`). The presets and LICENSE are
copied unchanged from generic-release 44-0.2 (MIT).

- `nisse-release`: `/usr/lib/os-release`, provides `system-release`.
- `nisse-release-common`: the other release files, systemd presets, the update channel file
  `/etc/nisse/channel` (`stable` or `daily`) and the two repo definitions. The repos ship
  disabled with a placeholder host until the GitHub-hosted channels exist.
