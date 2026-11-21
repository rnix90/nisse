#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# N-310 spike: can a rollback be a swap of subvolumes at the btrfs top level, so that the unchanged `subvol=root` in fstab and
# on the kernel line then boots the old state? Runs INSIDE an installed nisse disk (as root). Prints findings, one per line.
#   stage 1: make a snapshot, change the system, swap, print what the swap did (the machine is still running on the old root)
#   stage 2: after a power cycle, show which root booted and that snapper and the old snapshots still work
set -u
stage="${1:-1}"
dev="$(findmnt -no SOURCE / | sed 's/\[.*//')"
top=/mnt/top
say() { echo "SPIKE: $*"; }

if [ "$stage" = 1 ]; then
    command -v snapper >/dev/null || dnf install -y snapper btrfs-progs >/dev/null 2>&1
    [ -f /etc/snapper/configs/root ] || snapper -c root create-config / || say "create-config failed"
    before="$(snapper -c root create -p -d spike-before)"
    echo state-before > /etc/spike-marker
    echo "kept" > /etc/spike-keep-then-lost        # exists in the failed root only
    after="$(snapper -c root create -p -d spike-after)"
    say "before=$before after=$after"
    mkdir -p "$top"
    mount -o subvolid=5 "$dev" "$top" || { say "top-level mount failed"; exit 1; }
    say "top level: $(ls "$top" | tr '\n' ' ')"
    ts=failed-spike
    mv "$top/root" "$top/root.$ts" && say "rename of the RUNNING root: ok" || { say "rename of the running root FAILED"; exit 1; }
    say "the running system still answers: $(cat /etc/spike-marker)"
    btrfs subvolume snapshot "$top/root.$ts/.snapshots/$before/snapshot" "$top/root" >/dev/null && say "writable copy of snapshot $before as the new root: ok"
    btrfs property get -ts "$top/root" ro | sed 's/^/SPIKE: new root /'
    say "new root has /.snapshots as: $(stat -c %F "$top/root/.snapshots" 2>&1) inode $(stat -c %i "$top/root/.snapshots" 2>&1)"
    rmdir "$top/root/.snapshots" && say "empty placeholder removed"
    mv "$top/root.$ts/.snapshots" "$top/root/.snapshots" && say "moved the nested .snapshots subvolume across parents: ok" || say "moving .snapshots FAILED"
    say "subvolumes now: $(btrfs subvolume list "$top" | sed 's/ID [0-9]* gen [0-9]* top level //' | tr '\n' ';')"
    sync
    umount "$top"
    say "stage 1 done; power-cycle and run stage 2"
else
    say "root is: $(findmnt -no SOURCE,OPTIONS / | cut -c1-120)"
    say "marker: $(cat /etc/spike-marker 2>&1)"
    say "lost file: $(ls /etc/spike-keep-then-lost 2>&1)"
    say "snapper list: $(snapper -c root --csvout list --columns number,description 2>&1 | tr '\n' ';')"
    snapper -c root create -d spike-after-swap >/dev/null 2>&1 && say "snapper can still create a snapshot on the new root: ok" || say "snapper create FAILED"
    touch /etc/spike-write-test && say "new root is writable: ok" || say "new root NOT writable"
fi
