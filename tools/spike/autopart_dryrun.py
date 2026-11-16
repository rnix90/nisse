#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-301 spike: what does the installer's own automatic partitioning plan for a nisse disk?

Run as root in the Fedora build VM (anaconda-core, libblockdev-btrfs and libblockdev-lvm installed; no ISO install and
no nested virtualization needed). It attaches a sparse file as a loop disk, loads Anaconda's configuration the way
/usr/sbin/anaconda does at start-up (profile detection from the os-release ID, then conf.d), asks Anaconda's real
AutomaticPartitioningTask for a plan, and prints the planned devices. NOTHING is written to the disk: the plan is only
scheduled in blivet's device tree.

    sudo python3 autopart_dryrun.py --id nisse                    what the image does today (os-release ID=nisse)
    sudo python3 autopart_dryrun.py --id nisse --extra FILE.conf  the same, with an extra config layered on top
    sudo python3 autopart_dryrun.py --profile fedora-kde          force a shipped profile (like inst.profile=)
"""
import argparse
import os
import subprocess
import sys

IMG = "/var/tmp/nisse-spike-disk.img"


def sh(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", default="nisse", help="the os-release ID to detect the profile from")
    ap.add_argument("--variant", default=None, help="the os-release VARIANT_ID")
    ap.add_argument("--profile", default="", help="force this profile id instead of detecting")
    ap.add_argument("--extra", default="", help="an extra config file read after the profile (like conf.d)")
    ap.add_argument("--size", default="60G")
    ap.add_argument("--bios", action="store_true", help="plan for a BIOS machine (the default is UEFI, what the VM and real hardware use)")
    args = ap.parse_args()

    if not args.bios:
        import blivet.arch
        blivet.arch.is_efi = lambda: True           # the platform is chosen at import time of pyanaconda's platform module

    from pyanaconda.core.configuration.anaconda import conf

    if args.profile:
        conf.set_from_profile(args.profile)
    else:
        conf.set_from_detected_profile(args.id, args.variant)
    if args.extra:
        conf.read(args.extra)
        conf.validate()
    print("== configuration the installer ends up with")
    print("   profile_id        :", conf.profile.profile_id if hasattr(conf, "profile") else "?")
    print("   default_scheme    :", conf.storage.default_scheme)
    print("   btrfs_compression :", conf.storage.btrfs_compression or "(none)")
    print("   file_system_type  :", conf.storage.file_system_type or "(blivet default)")
    print("   default_partitioning:")
    for attrs in conf.storage.default_partitioning:
        print("      ", dict(attrs))

    # attach a disk
    if os.path.exists(IMG):
        os.remove(IMG)
    sh("truncate", "-s", args.size, IMG)
    loop = sh("losetup", "--find", "--show", IMG)
    name = os.path.basename(loop)
    try:
        from blivet import arch
        from pyanaconda.modules.common.structures.partitioning import PartitioningRequest
        from pyanaconda.modules.storage.devicetree.model import create_storage
        from pyanaconda.modules.storage.partitioning.automatic.automatic_partitioning import AutomaticPartitioningTask

        print("== platform: efi =", arch.is_efi())
        storage = create_storage()
        storage._get_hostname = lambda: None        # the network module is a D-Bus service; a live image has no real hostname
        storage.exclusive_disks = [name]
        storage.reset()
        disks = [d for d in storage.disks if d.name == name]
        if not disks:
            print("loop disk not seen by blivet; disks:", [d.name for d in storage.disks])
            return 2
        storage.select_disks([disks[0].device_id])   # hide every other disk, as the installer does after the disk spoke
        # The build VM is itself btrfs (subvolumes root, home, var, boot) and blivet counts those names as taken, which
        # would turn the plan's names into root00 and home00. A real install target has none of them: forget them.
        vm_names = {"root", "home", "var", "boot", "fedora"}
        type(storage).names = property(lambda self: [n for n in self.devicetree.names if n not in vm_names])
        request = PartitioningRequest()
        from blivet.static_data import luks_data  # noqa: F401
        from pyanaconda.modules.storage.disk_initialization import DiskInitializationConfig

        class DryRunTask(AutomaticPartitioningTask):
            """The real task, except the disk-init settings (normally a D-Bus service) are fixed: clear everything."""

            def _get_initialization_config(self):
                config = DiskInitializationConfig()
                config.initialization_mode = 1          # CLEAR_ALL
                config.drives_to_clear = [name]
                config.initialize_labels = True
                config.format_unrecognized = True
                config.clear_non_existent = True
                return config

            def _prepare_bootloader(self, storage):    # D-Bus again; the boot partitions come from platform.partitions
                pass

            def _setup_bootloader(self, storage):
                pass

        task = DryRunTask(storage, request)
        print("== partitioning request: scheme", request.partitioning_scheme)
        task.run()
        print("== planned devices (nothing written)")
        for dev in sorted(storage.devices, key=lambda d: (len(d.parents) if hasattr(d, "parents") else 0, d.name)):
            if dev.name == name:
                continue
            fmt = dev.format.type if dev.format else None
            mp = getattr(dev.format, "mountpoint", None) if dev.format else None
            extra = ""
            if getattr(dev, "type", "") == "btrfs subvolume":
                extra = " subvol_name=%s" % getattr(dev, "name", "?")
            opts = getattr(dev.format, "options", None) if dev.format else None
            print("   %-24s %-16s fs=%-8s mount=%-10s size=%s%s opts=%s" % (
                dev.name, dev.type, fmt, mp, dev.size, extra, opts))
        return 0
    finally:
        subprocess.run(["losetup", "-d", loop])
        if os.path.exists(IMG):
            os.remove(IMG)


if __name__ == "__main__":
    sys.exit(main())
