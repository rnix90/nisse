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

The check needs Fedora, the image tools (lorax-lmc-novirt, rpm-build, createrepo_c, xorriso,
squashfs-tools, pykickstart, rpmlint, edk2-ovmf) and working loop devices.

## Rebuilding the VM from scratch

1. Download the Fedora Cloud Base Generic qcow2 for the pinned release from
   `https://fedoraproject.org/releases.json` and check its sha256.
2. `qemu-img convert -O qcow2` it to `nisse-build.qcow2`, then `qemu-img resize ... 120G`.
3. First boot only: serve a cloud-init `user-data` / `meta-data` pair from `http://10.0.2.2:8000/`
   and pass `-smbios type=1,serial=ds=nocloud-net;s=http://10.0.2.2:8000/`. The user-data creates
   `builder`, grants sudo, and installs the public half of `~/.ssh/nisse_build`.
4. Install the packages listed above with `dnf`.

## Building and boot-testing the ISO

    bash tools/build/vm.sh sync
    bash tools/build/vm.sh ssh 'cd ~/nisse && for p in nisse-release nisse-branding nisse-fonts-nunito; do tools/rpm/build-rpm.sh $p; done && tools/rpm/make-repo.sh'
    bash tools/build/vm.sh ssh 'cd ~/nisse && setsid nohup bash build/build-iso.sh > out/build-iso.log 2>&1 < /dev/null &'   # about 25 min
    bash tools/build/vm.sh ssh 'cd ~/nisse && bash tests/iso/test_iso_contents.sh out/nisse-live.iso'
    mkdir -p /d/nisse-build-vm/out && bash tools/build/vm.sh pull out/nisse-live.iso /d/nisse-build-vm/out/nisse-live.iso
    bash tools/vm/smoke-boot.sh /d/nisse-build-vm/out/nisse-live.iso --out /d/nisse-build-vm/out/vm \
        --screenshot /d/nisse-build-vm/out/vm/desktop.png        # boots on the Windows host

Keep the ISO on a local drive, not on the T: share. Never run two builds at once, and never `pkill -f anaconda`
over SSH (the pattern matches your own shell). A hung build can be cleared with `sudo kill -9` on the
`anaconda` and `livemedia-creat` PIDs, then `sudo rm -f /run/anaconda.pid` and `sudo losetup -D`.

## Build the panel against the same Qt as the ISO

The ISO is built from Fedora's release repository only (the installer does not pick up the `updates` repository),
so it ships Qt 6.10 and Plasma 6.6 while a freshly updated build VM has Qt 6.11. An RPM built against Qt 6.11
cannot be installed into the ISO ("nothing provides libQt6Core.so.6(Qt_6.11)"). Keep the VM's Qt at the release
version:

    sudo dnf --repo=fedora distro-sync -y 'qt6-*'

Re-run it after any `dnf upgrade` in the VM, and rebuild `nisse-panel`. When the ISO starts using the updates
repository, remove this section. `build/build-all.sh` rebuilds every package and the ISO in one go.
