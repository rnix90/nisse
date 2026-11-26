# Build host

nisse images are built in a Fedora VM running under QEMU on RN-DESKTOP. WSL2 is not installed
on that machine and installing it needs admin rights and a reboot, so the VM was chosen
(decision by Bert, 2026-10-28, Task 0 of the Milestone 1 plan).

## What it is

- Fedora 44 Cloud Base (the newest stable release; 45 was still beta). `build/FEDORA_RELEASE` pins it.
- QEMU 11 with the Windows Hypervisor Platform (`whpx`) acceleration, 8 vCPUs, 16 GB RAM, 120 GB sparse disk.
- Files live in `D:\nisse-build-vm\` (disk `nisse-build.qcow2`, serial log, pid file).
- Login: user `builder` (passwordless sudo), key `~/.ssh/nisse_build`, SSH on `127.0.0.1:2222`.
- The VM has no nested virtualization. Anything that needs to boot an image (the smoke tests)
  runs on the Windows host with QEMU, not inside the VM.

## Daily use (from Git Bash in the repo root)

    powershell -File tools/build/build-vm.ps1 start     # boot the VM (SSH ready in ~30 s)
    bash tools/build/vm.sh sync                          # copy this repo into ~/nisse
    bash tools/build/vm.sh ssh 'cd ~/nisse && ...'       # run something in the VM
    bash tools/build/vm.sh pull out/nisse-live.iso .     # fetch a build result
    powershell -File tools/build/build-vm.ps1 stop

## Check it is ready

    bash tools/build/vm.sh ssh 'cd ~/nisse && bash tools/build/check-host.sh'   # expect exit 0

The check needs Fedora, the image tools (kiwi, kiwi-systemdeps, rpm-build, createrepo_c, xorriso, erofs-utils,
rpmlint, edk2-ovmf) and SELinux not in enforcing mode (see "SELinux" below).
`bash tools/build/provision-vm.sh` installs all of it, sets SELinux permissive and pins Qt (safe to re-run).

## SELinux must be permissive in the build VM

kiwi's bootstrap fails under SELinux enforcing ("%sysusers scriptlet failed, exit status 127"). `provision-vm.sh`
runs `setenforce 0` and edits `/etc/selinux/config` so it survives a reboot. This only affects the build VM, not the
image it builds. Details: `docs/kiwi-spike.md`.

## Rebuilding the VM from scratch

1. Download the Fedora Cloud Base Generic qcow2 for the pinned release from
   `https://fedoraproject.org/releases.json` and check its sha256.
2. `qemu-img convert -O qcow2` it to `nisse-build.qcow2`, then `qemu-img resize ... 120G`.
3. First boot only: serve a cloud-init `user-data` / `meta-data` pair from `http://10.0.2.2:8000/`
   and pass `-smbios type=1,serial=ds=nocloud-net;s=http://10.0.2.2:8000/`. The user-data creates
   `builder`, grants sudo, and installs the public half of `~/.ssh/nisse_build`.
4. Run `bash ~/nisse/tools/build/provision-vm.sh` (after `vm.sh sync`): installs the packages, makes SELinux
   permissive and pins Qt.

## Two version numbers

- `build/PRODUCT_VERSION` is nisse's own version (0.2 now). It is what the system calls itself: os-release `VERSION`,
  `PRETTY_NAME` and `BUILD_ID`, the CPE name, `/usr/lib/fedora-release` and the ISO volume id (`nisse-0.2`, which the boot
  menu's `root=live:CDLABEL=` must match). Bump it by hand when a milestone ships; there is no "alpha" label.
- `build/FEDORA_RELEASE` is the Fedora base (44). It stays in os-release `VERSION_ID` and as the `nisse-release` RPM
  `Version`, because dnf's `$releasever`, the COPR plugin and the `%fedora` macro are derived from them. Change it only
  when moving to a new Fedora release (see "Refreshing the vendored Fedora description").

## Building and boot-testing the ISO

The ISO is built with kiwi-ng from the Fedora kiwi description vendored in `build/kiwi/fedora/` plus the nisse overlay
(`build/kiwi/Nisse.kiwi`, `build/kiwi/nisse/`). `build/render-kiwi.sh` assembles `out/kiwi-description/`.

    bash tools/build/vm.sh sync
    bash tools/build/vm.sh ssh 'cd ~/nisse && setsid nohup bash build/build-all.sh > out/build-all.log 2>&1 < /dev/null &'   # RPMs, repo, ISO: about 35 min
    bash tools/build/vm.sh ssh 'cd ~/nisse && bash tests/iso/test_iso_contents.sh out/nisse-live.iso'
    mkdir -p /d/nisse-build-vm/out && bash tools/build/vm.sh pull out/nisse-live.iso /d/nisse-build-vm/out/nisse-live.iso
    bash tools/vm/smoke-boot.sh /d/nisse-build-vm/out/nisse-live.iso --out /d/nisse-build-vm/out/vm \
        --screenshot /d/nisse-build-vm/out/vm/desktop.png        # boots on the Windows host
    python tests/e2e/check_start_button.py /d/nisse-build-vm/out/vm/desktop.png   # no Fedora hot dog on the start button
    bash tests/e2e/test_hw_in_vm.sh /d/nisse-build-vm/out/nisse-live.iso   # 4 boots with spoofed hardware, slow

`build/build-iso.sh` alone rebuilds only the ISO from the current `out/repo`. A package that changed needs a new
Release in its spec (kiwi may serve a cached RPM of the same name-version-release) before `build-rpm.sh` and
`make-repo.sh`.

Keep the ISO on a local drive, not on the T: share. Never run two builds at once.

Lessons from the kiwi migration (details in `docs/kiwi-spike.md`):

- Never `rm -rf` a kiwi install root or `out/kiwi-build` while anything is mounted under it: os-prober mounts the
  host's filesystems there and the delete reaches into them. This wrecked the VM once. `build-iso.sh` refuses to
  delete the directory while `findmnt` shows a mount under it.
- The root filesystem is an EROFS image at `/LiveOS/squashfs.img` inside the ISO (the name is historical). Extract it
  with `xorriso -osirrox on -indev ISO -extract /LiveOS/squashfs.img OUT` and `mount -t erofs -o loop,ro`.
- The nisse ISO's GRUB menu (N-502) defaults to "nisse", which starts at once. `smoke-boot.sh` presses Up (it stops the
  countdown) and then Enter; pass `--mediacheck` to open More Ways to Start with the hotkey m and start "Check This Media and Start nisse"
  (a checksum of the whole ISO, very slow under emulation).
- `nisse-release` replaced Fedora's `90-default.preset`, so anything Fedora enables there that nisse needs must be in
  `packaging/rpm/nisse-release/80-nisse-desktop.preset` (the live session needs `livesys` and `livesys-late`).
- The vendored files must have Unix line endings. `vendor-kiwi.sh` clones with `core.autocrlf=false`; the Windows
  default converts them and breaks `config.sh` inside the VM.

## Brand art review page

After a new ISO, refresh the review page's inventory with `bash tools/brandart/extract_in_vm.sh` and
`python tools/brandart/previews.py out/brandart`; comments survive. Details: `docs/brand-art.md`.

## Refreshing the vendored Fedora description

Fedora maintains the live-image description at `https://pagure.io/fedora-kiwi-descriptions` (one branch per release).
To move to a new release or pick up fixes:

    bash tools/build/vendor-kiwi.sh COMMIT [BRANCH]    # e.g. a commit on branch f45; rewrites build/kiwi/fedora/
    # update PIN in tests/build/test_kiwi_description.sh, set build/FEDORA_RELEASE, run the tests, rebuild the ISO

`build/kiwi/fedora/VENDORED.md` records the pinned commit. `nisse-live.xml` holds a hand-copy of the `<packages type="iso">`
block of `components/liveinstall.xml`; after a refresh the description test fails if that block changed, and you re-merge
it into `nisse-live.xml` on purpose. The files are GPL-3.0 (upstream ships the GPL-3.0 text as `COPYING`, which stays with them), and `build/kiwi/nisse/components/nisse-live.xml`, which copies a block from them, is labelled GPL-3.0-only.

## Build the panel against the same Qt as the ISO

The ISO is built from Fedora's release repository only (a frozen snapshot: no `updates` repository is configured, by
decision of 2026-10-29), so it ships Qt 6.10 and Plasma 6.6 while a freshly updated build VM has Qt 6.11. An RPM
built against Qt 6.11 cannot be installed into the ISO ("nothing provides libQt6Core.so.6(Qt_6.11)"). Keep the VM's
Qt at the release version:

    sudo dnf --repo=fedora distro-sync -y 'qt6-*'

Re-run it after any `dnf upgrade` in the VM, and rebuild `nisse-panel`. When the ISO starts using the updates
repository, remove this section.

**Never `dnf install` from the `updates` repository in the build VM** (2026-11-19: installing `layer-shell-qt-devel` 6.8.3 from
updates pulled Qt 6.11 and a whole Plasma 6.8 into the VM in the middle of a build, the panel came out built against Qt 6.11 and
the ISO build failed at its package step). The `updates` and `updates-testing` repositories are now disabled in the VM
(`sudo dnf config-manager setopt updates.enabled=0 updates-testing.enabled=0`), so installs come from the release repository the
image uses. The VM was put back on the release set with `sudo dnf downgrade -y --allowerasing 'qt6-*'`.

`build/build-all.sh` now runs `tools/rpm/check-installable.sh` before kiwi: it resolves every nisse package of the image against the
Fedora release repository plus `out/repo` in an empty install root, so this kind of drift fails in seconds with the missing provides
named (unit test: `tests/build/test_check_installable.sh`). `build/build-all.sh` rebuilds every package and the ISO in one go.

## GATE 2 checks inside the live image

`python tools/vm/gate2.py --iso D:/nisse-build-vm/out/nisse-live.iso --tools out/gate2/tools --out out/gate2` boots the ISO under
QEMU, serves the test binaries to the guest over its network (build them in the VM first: the `schema` and `dbus` test binaries and
the `device_probe` example from `services/`, stripped, plus `tests/e2e/devices_inner.sh`), and runs the AI core checks on the image
itself, with screenshots of each panel page in `out/gate2/shots`. It cannot run a real `claude` (needs a sign-in).
