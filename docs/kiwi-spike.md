# Kiwi spike results (2026-10-29)

Question: does Fedora's own kiwi build of the KDE live image work in our build VM, and what do we need to know before
building Nisse the same way? Answer: yes, with one host setting.

## What was built

- Source: `https://pagure.io/fedora-kiwi-descriptions.git`, branch `f44`, commit
  `dfc49a5a10f69941179fdadd96aa6a5984f7c677`.
- Tool: `kiwi-ng` 11.1.1 with dnf5, from the Fedora 44 packages `kiwi kiwi-systemdeps distribution-gpg-keys erofs-utils`.
- Command: `sudo ./kiwi-build --kiwi-file=Fedora.kiwi --image-type=iso --image-profile=KDE-Desktop-Live --output-dir ...`
  (the repo's wrapper around `kiwi-ng ... system build`).
- Result: `Fedora.x86_64-44.iso`, 3.44 GB, volume id `Fedora-KDE-Live-44`. It boots under QEMU/UEFI to the Plasma live
  desktop ("Welcome to Fedora Linux!" with the install launcher).

## The one thing that went wrong: SELinux

On the Fedora Cloud VM (SELinux enforcing) the build died in the bootstrap stage:
`%sysusers(setup) scriptlet failed, exit status 127`, ten times, then `Transaction failed: Rpm transaction failed`.
The same transaction run by hand with `dnf5 --installroot` works, so it is something about how kiwi runs it, and
SELinux is what matters: after `sudo setenforce 0` the identical build ran to the end with zero sysusers errors.
The build host therefore runs SELinux permissive (`provision-vm.sh` sets it, also in `/etc/selinux/config`).
This is a property of the build host only; the image's own SELinux configuration comes from the image description.

## Cost

- Wall time: about 29 minutes (16:05 to 16:34), most of it downloading and installing ~2,200 packages and packing the root.
- Disk: the build used about 11 GB of the VM's 120 GB, including kiwi's cache.
- Memory: fine within the VM's 16 GB.

## What the ISO looks like inside

- Boot: `/EFI/BOOT/` (shim and GRUB, ia32 and x64) and `/EFI/fedora/`, plus `/boot` and `/System` for BIOS and Mac boot.
- Root filesystem: `/LiveOS/squashfs.img`. Despite the name it is an **EROFS** image, and it is the root filesystem
  itself, not a nested `rootfs.img` inside a squashfs as in the kickstart-built ISO.
- Reading it: extract it with `xorriso -osirrox on -indev ISO -extract /LiveOS/squashfs.img OUT`, then
  `sudo mount -t erofs -o loop,ro OUT MOUNTPOINT` (the VM kernel has erofs); `fsck.erofs` and `erofsfuse` also exist.
- Package database: `usr/lib/sysimage/rpm/rpmdb.sqlite`, readable with `rpm --dbpath MOUNTPOINT/usr/lib/sysimage/rpm -q ...`.
- Identity: `ID=fedora`, `VERSION_ID=44`; no package named `fedora-release-kde` (Fedora 44 splits the release packages).

## Repositories (matters for the "release repo only" decision)

Fedora's description uses both the release repo and `updates` (`repositories/core-nonrawhide.xml`). The stock ISO
therefore ships Qt 6.11.2 and Plasma 6.7.5. To get the release-only image Bert chose (Qt 6.10, Plasma 6.6) the Nisse
description must carry its own repository list without `updates`.

## Pitfalls to remember

- Kiwi's grub scriptlet runs os-prober inside the build root; with `/dev`, `/proc` and `/sys` bind-mounted, os-prober
  mounts the host's own filesystems under `var/lib/os-prober/mount/` in that root. Never `rm -rf` a bind-mounted
  install root by hand: `rm` descends into those mounts. (A hand-made test root did exactly that and wrecked the
  build VM, which had to be recreated: `tools/build/build-vm.ps1 recreate`, then `provision-vm.sh`.) Kiwi unmounts and
  cleans its own root; use `findmnt` first if you must remove one.
- `kiwi-build --isolated` (kiwi's boxed VM mode) needs KVM, which the VM does not have (no nested virtualization),
  so builds run directly in the VM.
- Kiwi prints `No matches were found for the following plugin name patterns ... priorities, versionlock` on every dnf5
  call. It is harmless noise.
