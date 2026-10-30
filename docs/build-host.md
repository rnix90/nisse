# Build host

Nisse images are built in a Fedora VM running under QEMU on RN-DESKTOP. WSL2 is not installed
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

## Building and boot-testing the ISO

The ISO is built with kiwi-ng from the Fedora kiwi description vendored in `build/kiwi/fedora/` plus the Nisse overlay
(`build/kiwi/Nisse.kiwi`, `build/kiwi/nisse/`). `build/render-kiwi.sh` assembles `out/kiwi-description/`.

    bash tools/build/vm.sh sync
    bash tools/build/vm.sh ssh 'cd ~/nisse && setsid nohup bash build/build-all.sh > out/build-all.log 2>&1 < /dev/null &'   # RPMs, repo, ISO: about 35 min
    bash tools/build/vm.sh ssh 'cd ~/nisse && bash tests/iso/test_iso_contents.sh out/nisse-live.iso'
    mkdir -p /d/nisse-build-vm/out && bash tools/build/vm.sh pull out/nisse-live.iso /d/nisse-build-vm/out/nisse-live.iso
    bash tools/vm/smoke-boot.sh /d/nisse-build-vm/out/nisse-live.iso --out /d/nisse-build-vm/out/vm \
        --screenshot /d/nisse-build-vm/out/vm/desktop.png        # boots on the Windows host
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
- Fedora's GRUB menu defaults to "Test this media & start" (a checksum of the whole ISO). `smoke-boot.sh` presses
  Up+Enter to start the live system instead; pass `--mediacheck` to keep the default.
- `nisse-release` replaced Fedora's `90-default.preset`, so anything Fedora enables there that Nisse needs must be in
  `packaging/rpm/nisse-release/80-nisse-desktop.preset` (the live session needs `livesys` and `livesys-late`).
- The vendored files must have Unix line endings. `vendor-kiwi.sh` clones with `core.autocrlf=false`; the Windows
  default converts them and breaks `config.sh` inside the VM.

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
repository, remove this section. `build/build-all.sh` rebuilds every package and the ISO in one go.
