# Nisse build tooling: move from kickstart to kiwi (design amendment)

Date: 2026-10-29. Status: draft for review. Amends section 5 and 6.12 of
`2026-10-28-nisse-os-design.md` (image built "with kickstart and the Anaconda installer").

"Decided" means Bert chose it. "Call" means Claude chose it and Bert has not seen it yet.

## 1. Why

Fedora retired its kickstart repository. Fedora 44 images are built with kiwi, from the
`fedora-kiwi-descriptions` project (branch `f44`). Milestone 1 vendored the last kickstart (f43) and patched it for
F44 with several `sed` edits in `build/build-iso.sh`. That works today, but every Fedora release would mean porting
it by hand with no upstream to follow. Decided (2026-10-29, after the Milestone 1 review): switch the build to kiwi now.

## 2. What changes and what does not

Changes:
- The image is described with a kiwi description under `build/kiwi/` and built with `kiwi-ng` in the Fedora build VM.
- `build/kickstart/` (the vendored f43 kickstart and its overlay) and the `sed` patches in `build/build-iso.sh` go away.
- `build/build-iso.sh` keeps its name and its output (`out/nisse-live.iso`) so every script that uses the ISO still works.

Does not change:
- Classic RPM remix, Anaconda as the installer, KDE Plasma, x86_64, btrfs, one image for all machines.
- Our RPMs, their tests, the local repo (`out/repo`), the Nisse release package, the hardware routing, the daemon and panel.
- The test surface: `tests/iso/test_iso_contents.sh`, `tools/vm/smoke-boot.sh`, `tests/e2e/test_hw_in_vm.sh`.
  The ISO contents test needs to learn the new image layout (kiwi uses an erofs root, not squashfs).
- Where the build runs: the Fedora VM on RN-DESKTOP, run by hand.

## 3. Decisions

- Decided: switch to kiwi now (not a spike-first, not staying on f43).
- Decided: the image uses Fedora's **release repo only**, not `updates` (a frozen snapshot, as today). Fedora's own
  description lists both repos, so ours must leave `updates` out. The image therefore ships Qt 6.10 and Plasma 6.6.
  Consequence: our RPMs must keep being built against Qt 6.10 (the VM's Qt pin in `docs/build-host.md` stays,
  until RPMs are built in a mock chroot against the same repos).
- Decided earlier and unchanged: Fedora latest stable (44), upgrade each release; Claude Code is never in the ISO.

## 4. Design

**Vendored description (call).** A pruned, pinned copy of the `f44` kiwi description lives in `build/kiwi/fedora/`,
with provenance (source URL, branch, commit `dfc49a5a10f69941179fdadd96aa6a5984f7c677`) in a header file and a
refresh script, `tools/build/vendor-kiwi.sh COMMIT`, that re-creates it. Only what a KDE live image needs is kept:
the common, boot, desktop-common, KDE and live-install components, the live-install files (ISO template,
exclusion list), users, and the post-build scripts. The cloud, server and other desktop variants are dropped.
Fedora's `COPYING` (GPL-3.0) stays with the vendored files; they keep their own license inside our
GPL-2.0-or-later repository (call: acceptable, they are build configuration, not linked code).

**Nisse overlay (call).** Our own files sit beside the vendored ones and never edit them:
- `build/kiwi/Nisse.kiwi`: the top-level description (name Nisse, version from `build/FEDORA_RELEASE`, dnf5), which
  includes the vendored components plus ours.
- `build/kiwi/nisse/components/nisse-live.xml`: a profile `Nisse-Live` requiring `BaseCommon`, `BootCoreLive` and
  `KDE-Desktop`. It deliberately does not use Fedora's `KDE-Desktop-Live` profile, which pulls in
  `fedora-release-kde` and Fedora's volume id and publisher. It carries our ISO type block (volume id `Nisse-44`,
  publisher Nisse, erofs root, UEFI, GRUB, a serial console on the kernel line for the boot tests), the live-install
  package set copied from Fedora's, and our packages: `nisse-release`, `nisse-release-common`, `nisse-branding`,
  `nisse-fonts-nunito`, `nisse-hw`, `nisse-firstboot`, `nisse-daemon`, `nisse-panel`.
- `build/kiwi/nisse/repositories/nisse.xml`: the release repo (Fedora metalink, signed) and our local repo
  `out/repo`; the build script renders the local path into it. No `updates` repository.
- Anything the kickstart patched by `sed` is handled here: the root account is locked in users, the removed
  `kde-spin-initial-setup` group simply is not referenced, Fedora's release packages are excluded.

**Build (call).** `build/build-iso.sh` renders the description into `out/kiwi-description/`, runs
`kiwi-ng --profile Nisse-Live --type iso system build` as root in the VM (kiwi needs the host's
`kiwi-systemdeps`), and copies the resulting ISO to `out/nisse-live.iso`.

## 5. Risks and unknowns (the plan starts by retiring the first two)

1. Whether kiwi builds the stock Fedora KDE live image in our VM at all (disk, memory, loop devices, time).
2. The layout of the kiwi ISO (erofs root inside `LiveOS/`), which the contents test must handle.
3. Whether the Anaconda post-script hook (`/usr/share/anaconda/post-scripts/*ks`) still runs from a kiwi-built live image.
   It is part of the live-install package set, so it should; it is checked in the manual acceptance run.
4. Package conflicts between our release package and anything the vendored KDE components pull in.
5. Each Fedora release now needs the vendored description refreshed and re-pruned (one script run, then a build).

## 6. Left to the builder

- The exact pruned file list, the kiwi profile wiring details, XML formatting, the render mechanism for the repo path.
- Build time and disk tuning inside the VM.
