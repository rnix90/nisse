# Kiwi Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `out/nisse-live.iso` with kiwi (Fedora's own image tool) instead of the retired kickstart, with no change to what the ISO contains or to how it is tested.

**Architecture:** A pruned, pinned copy of Fedora's f44 kiwi description is vendored under `build/kiwi/fedora/`. Our own files in `build/kiwi/nisse/` add one profile, `Nisse-Live`, our packages, and a repo list of Fedora's release repo plus our local repo (no `updates`). `build/build-iso.sh` renders the description and runs `kiwi-ng`.

**Tech Stack:** kiwi (`kiwi-ng`, `kiwi-systemdeps`, `distribution-gpg-keys`), dnf5, bash, xmllint, the existing QEMU/Python/RPM tooling.

**Spec:** `docs/superpowers/specs/2026-10-29-kiwi-build-design.md` (amends `2026-10-28-nisse-os-design.md`)

## Global Constraints

- Anaconda stays the installer; classic RPM remix; KDE Plasma; x86_64; one image for all machines.
- Fedora release comes from `build/FEDORA_RELEASE` (44). The image uses Fedora's release repo only, never `updates`.
- Claude Code is never inside the ISO.
- Output path stays `out/nisse-live.iso`; `tests/iso/test_iso_contents.sh`, `tools/vm/smoke-boot.sh` and `tests/e2e/test_hw_in_vm.sh` keep working.
- Build host is the Fedora 44 VM (`tools/build/vm.sh`), run by hand, never two builds at once.
- Vendored Fedora files keep their own license (`COPYING`, GPL-3.0); everything we write is GPL-2.0-or-later with an SPDX header.
- Plain ASCII in everything authored. Nothing personal in the repo.

## Review Focus

- The kiwi-built image must still carry the Anaconda post-script that runs hardware routing at install time (`/usr/share/anaconda/post-scripts/90-nisse-hwroute.ks`). Owner: Task 3.
- `updates` must not leak in: no `updates` repository in the rendered description, and the image's Qt must be the release version (6.10). Owner: Tasks 2 and 3.
- A failed or interrupted kiwi build must not leave an old `out/nisse-live.iso` that looks like a fresh success. Owner: Task 3.
- Nothing of Fedora's identity may remain in the image (`fedora-release-kde` absent, `ID=nisse`, volume id `Nisse-44`). Owner: Tasks 2 and 3.
- The vendored description must be reproducible: re-running the refresh script at the pinned commit must give a tree identical to the committed one. Owner: Task 1.

## File Structure

- `build/kiwi/fedora/` : pruned vendored copy of Fedora's f44 description, with `VENDORED.md`
- `build/kiwi/Nisse.kiwi`, `build/kiwi/nisse/` : our top-level description and overlay
- `build/render-kiwi.sh` : fills the placeholders and writes `out/kiwi-description/`
- `build/build-iso.sh` : rewritten to call kiwi
- `tools/build/vendor-kiwi.sh` : refreshes the vendored copy
- `tests/build/test_kiwi_description.sh`, `tests/iso/test_iso_contents.sh`

---

### Task 0: Spike - build Fedora's stock KDE live image with kiwi in the VM

**Files:**
- Create: `docs/kiwi-spike.md`

**Interfaces:**
- Produces: `docs/kiwi-spike.md` recording build time, peak disk, the ISO's internal layout and whether it boots. Later tasks read it.

- [ ] **Step 1:** In the VM install `kiwi kiwi-systemdeps distribution-gpg-keys erofs-utils`. Clone `https://pagure.io/fedora-kiwi-descriptions.git`, check out commit `dfc49a5a10f69941179fdadd96aa6a5984f7c677` (branch `f44`).
- [ ] **Step 2:** Run `sudo ./kiwi-build --kiwi-file=Fedora.kiwi --image-type=iso --image-profile=KDE-Desktop-Live --output-dir ~/kiwi-spike/out` detached (`setsid nohup ... &`), logging to a file. Expected: it finishes and leaves an ISO. If it fails, record the error and stop: later tasks cannot start until this works.
- [ ] **Step 3:** Record wall time, peak free-disk drop on `/`, and the ISO size. Record the ISO's file tree (`xorriso -indev ISO -find / -maxdepth 3`) and the root image format found under `LiveOS/` (`file`, and which tool lists or mounts it).
- [ ] **Step 4:** Pull the ISO to `D:\nisse-build-vm\out\kiwi-stock.iso` and boot it with `tools/vm/run-vm.sh` (window, no spoofing). Expected: it reaches the Plasma live desktop. Take a screenshot with the QEMU monitor.
- [ ] **Step 5:** Write the results into `docs/kiwi-spike.md` and commit `docs: kiwi spike results`.

### Task 1: Vendor the f44 description

**Files:**
- Create: `tools/build/vendor-kiwi.sh`, `build/kiwi/fedora/**`, `build/kiwi/fedora/VENDORED.md`, `tests/build/test_kiwi_description.sh`

**Interfaces:**
- Consumes: the layout facts in `docs/kiwi-spike.md`.
- Produces: `tools/build/vendor-kiwi.sh COMMIT` (clones the upstream project, copies exactly the pruned file list below, writes `VENDORED.md` with source URL, branch and commit); `build/kiwi/fedora/` containing `components/{common,boot,liveinstall,users}.xml`, `components/desktops/{common,kde}.xml`, `teams/kde.xml`, `config.sh`, `scripts/`, `root/`, `iso-esp-excludes.yaml`, `grub-x86.cfg.iso-template`, `COPYING`, and no cloud, server or other-desktop files. Later tasks include these by path.

- [ ] **Step 1:** Write `tests/build/test_kiwi_description.sh` (part 1, vendoring): every file in the list above exists under `build/kiwi/fedora/`; `xmllint --noout` passes on every `.xml`; `COPYING` is present; `VENDORED.md` contains the pinned commit `dfc49a5a10f69941179fdadd96aa6a5984f7c677`; no file under `build/kiwi/fedora/teams/` other than `kde.xml`; and re-running `vendor-kiwi.sh dfc49a5a10f69941179fdadd96aa6a5984f7c677` into a temp directory produces a tree with identical `sha256sum` output to the committed one.
- [ ] **Step 2:** Run it. Expected: FAIL (files missing).
- [ ] **Step 3:** Implement `vendor-kiwi.sh` with the file list as a variable at the top. Run it into `build/kiwi/fedora/`.
- [ ] **Step 4:** Run the test. Expected: PASS.
- [ ] **Step 5:** Commit `build: vendor Fedora f44 kiwi description`.

### Task 2: The Nisse overlay and renderer

**Files:**
- Create: `build/kiwi/Nisse.kiwi`, `build/kiwi/nisse/components/nisse-live.xml`, `build/kiwi/nisse/repositories/nisse.xml`, `build/render-kiwi.sh`
- Modify: `tests/build/test_kiwi_description.sh` (part 2)

**Interfaces:**
- Consumes: Task 1's vendored files.
- Produces: `build/render-kiwi.sh` writes `out/kiwi-description/` (a full description directory) replacing `@NISSE_REPO@` (the `dir://` URL of `out/repo`), `@RELEASE@` (from `build/FEDORA_RELEASE`) and `@KERNELCMDLINE@` (default `quiet rhgb console=ttyS0 systemd.log_target=console`, overridable with `NISSE_KERNELCMDLINE`). Profile name: `Nisse-Live`. ISO volume id: `Nisse-44`.

- [ ] **Step 1:** Extend the test (part 2, run in the VM after rendering): `kiwi-ng image info --description out/kiwi-description --list-profiles` lists `Nisse-Live`; the description's package list for that profile contains `nisse-release nisse-release-common nisse-branding nisse-fonts-nunito nisse-hw nisse-firstboot nisse-daemon nisse-panel` and `anaconda-live`; it does not contain `fedora-release-kde` or `fedora-release`; the rendered repositories contain an alias `fedora` and an alias `nisse` and no alias `updates`; the rendered `volid` is `Nisse-44`; no `@...@` placeholder is left.
- [ ] **Step 2:** Run it. Expected: FAIL (no description yet).
- [ ] **Step 3:** Write the overlay: `Nisse.kiwi` (name Nisse, version and release-version from the placeholder, dnf5, includes the vendored components and ours); `nisse-live.xml` (profile `Nisse-Live` requiring `BaseCommon`, `BootCoreLive`, `KDE-Desktop`; the iso type block adapted from `liveinstall.xml` with our volid, publisher and kernel command line; the live-install package set from Fedora's `liveinstall.xml`; bootstrap package `nisse-release`; our packages; `<ignore>` entries for Fedora's release and logo packages); `nisse.xml` (Fedora release repo from Fedora's metalink, signed with the Fedora key, plus the local repo with package signature checks off). Write `render-kiwi.sh` with `sed`.
- [ ] **Step 4:** Run the test. Expected: PASS. Resolve any profile-wiring errors `kiwi-ng` reports.
- [ ] **Step 5:** Commit `build: Nisse kiwi overlay and renderer`.

### Task 3: Build the ISO with kiwi

**Files:**
- Modify: `build/build-iso.sh` (rewrite), `tests/iso/test_iso_contents.sh`
- Delete: `build/kickstart/`

**Interfaces:**
- Consumes: `build/render-kiwi.sh`, `out/repo` (from `tools/rpm/make-repo.sh`).
- Produces: `build/build-iso.sh` (no arguments) leaves `out/nisse-live.iso` only on success; it deletes any old `out/nisse-live.iso` first and exits non-zero if kiwi fails. `build/build-all.sh` keeps calling it unchanged.

- [ ] **Step 1:** Run the existing `tests/iso/test_iso_contents.sh` against the kiwi stock ISO from Task 0 to see what in it assumes squashfs. Then extend the test for the kiwi layout (use the extraction method recorded in `docs/kiwi-spike.md`) and add assertions: `/usr/share/anaconda/post-scripts/90-nisse-hwroute.ks` exists; the image's `qt6-qtbase` version starts with `6.10`; `/usr/lib/os-release` has `ID=nisse`; no `fedora-release-kde` in the rpm database. Keep the existing assertions (our programs present, no `claude` file, Nunito present).
- [ ] **Step 2:** Run it against the kiwi build output once it exists (Step 3). First run it now. Expected: FAIL ("ISO not found").
- [ ] **Step 3:** Rewrite `build-iso.sh`: remove the old ISO, run `build/render-kiwi.sh`, run `kiwi-ng --profile Nisse-Live --type iso system build --description out/kiwi-description --target-dir out/kiwi-build` as root, copy the ISO to `out/nisse-live.iso`, fail loudly otherwise. Delete `build/kickstart/` and its references. Run `tools/rpm` builds and `make-repo.sh`, then `build-iso.sh` detached.
- [ ] **Step 4:** Run the contents test. Expected: PASS. Also run a deliberately broken build (point `NISSE_REPO` at an empty directory) and confirm the script exits non-zero and leaves no `out/nisse-live.iso`.
- [ ] **Step 5:** Commit `build: build the ISO with kiwi, drop the vendored kickstart`.

### Task 4: Boot and hardware tests on the kiwi ISO

**Files:**
- Modify: `tools/vm/smoke-boot.sh` only if the kiwi ISO needs a different serial marker.

**Interfaces:**
- Consumes: `out/nisse-live.iso`.

- [ ] **Step 1:** Pull the ISO to `D:\nisse-build-vm\out\nisse-live.iso` and run `tools/vm/smoke-boot.sh` with `--screenshot`. Expected: `login:` reached and the screenshot shows Plasma with "Welcome to Nisse!".
- [ ] **Step 2:** Run `tests/e2e/test_hw_in_vm.sh` on it. Expected: `PASS: hardware routing in VMs` (surface, apple-t2, apple-pre-t2, generic). If a marker differs on the kiwi image, fix the marker in the script and say why in the commit.
- [ ] **Step 3:** Commit any script change `tests: boot checks on the kiwi ISO`; if nothing changed, no commit.

### Task 5: Clean up and document

**Files:**
- Modify: `docs/build-host.md`, `docs/milestone-1-acceptance.md`, `docs/claude-cli-notes.md` (only if it mentions the kickstart), `docs/milestone-1-decisions.md` (append)

- [ ] **Step 1:** Update `docs/build-host.md`: new build steps (kiwi packages, `build-all.sh`), how to refresh the vendored description for a new Fedora release (`vendor-kiwi.sh COMMIT`, then build), and keep the Qt 6.10 pin section with the reason stated again. Remove the kickstart instructions and the `pkill`/anaconda warnings that no longer apply, keeping any that do.
- [ ] **Step 2:** Update the acceptance checklist: the install step also confirms the post-script ran from the kiwi image.
- [ ] **Step 3:** Run the whole suite (hw pytest, cargo, panel ctest, every RPM test, shell tests, panel e2e, ISO contents, boot, hardware e2e). Expected: all PASS.
- [ ] **Step 4:** Commit `docs: build host and acceptance for the kiwi build` and push `daily` to the public repo.

---

## Self-review notes

- **Spec coverage:** the switch (Tasks 1-3), release repo only (Tasks 2-3), unchanged test surface (Tasks 3-4), vendoring and refresh (Task 1), license note (Task 1 keeps `COPYING`), risks 1-2 retired by Task 0, risk 3 checked in Task 3 and the acceptance run, risk 5 by `vendor-kiwi.sh`.
- **Not in this plan:** the decided fix pass (CLI timeout and Stop, persistent sessions, live-boot fetch skip, hwroute error handling, os-release fields and ownership, message queue, permission-mode switch). It is its own plan, written next, and does not depend on the build tooling.
- **Unknowns the executor settles and records:** the exact `kiwi-ng` options for a root build in the VM; the root image format and how to read it; any packages the vendored KDE components pull that conflict with `nisse-release`.
