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
