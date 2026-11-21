#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# N-312 spike: what happens to a subvolume NESTED inside the root when the root is swapped for a copy of a snapshot (N-310)?
# Runs INSIDE an installed nisse disk, as root. It checks four things on the real btrfs and prints one finding per line:
#   1. a copy (snapshot) of the root holds only an empty placeholder directory where the nested subvolume is
#   2. `btrfs subvolume list -o` lists the nested subvolumes of a subvolume, with paths relative to the top level
#   3. the empty placeholder can be removed and the nested subvolume moved into its place, across parents, while the old root runs
#   4. the same works for a nested subvolume that did not exist when the copy was made (its parent directory is created)
set -u
say() { echo "SPIKE: $*"; }
dev="$(findmnt -no SOURCE / | sed 's/\[.*//')"
top=/mnt/top
mkdir -p "$top"
mount -o subvolid=5 "$dev" "$top" || { say "top-level mount failed"; exit 1; }

# a nested subvolume with a file, in a directory that exists in the copy
mkdir -p /opt
btrfs subvolume create /opt/e2e-nested >/dev/null && say "created the nested subvolume /opt/e2e-nested"
echo before-snapshot > /opt/e2e-nested/file
# the copy, as nisse-rollback makes it
btrfs subvolume snapshot "$top/root" "$top/root.spike-new" >/dev/null && say "copy of the root made (writable)"
# a nested subvolume created AFTER the copy, under a parent that does not exist in it
mkdir -p /srv/e2e-after/deeper
btrfs subvolume create /srv/e2e-after/deeper/vol >/dev/null
echo after-snapshot > /srv/e2e-after/deeper/vol/file

say "1. in the copy, /opt/e2e-nested is: $(stat -c '%F, inode %i' "$top/root.spike-new/opt/e2e-nested" 2>&1); its content: $(ls -A "$top/root.spike-new/opt/e2e-nested" 2>&1 | wc -l) entries"
say "1. in the copy, /srv/e2e-after exists: $(test -e "$top/root.spike-new/srv/e2e-after" && echo yes || echo no)"
say "2. subvolume list -o of the old root: $(btrfs subvolume list -o "$top/root" | sed 's/^ID [0-9]* gen [0-9]* top level [0-9]* path //' | tr '\n' ';')"

# 3. a placeholder to replace
rmdir "$top/root.spike-new/opt/e2e-nested" && say "3. the empty placeholder directory was removed"
mv "$top/root/opt/e2e-nested" "$top/root.spike-new/opt/e2e-nested" && say "3. moved the nested subvolume across parents: ok" || say "3. moving the nested subvolume FAILED"
say "3. it is now at: $(btrfs subvolume list "$top" | grep 'e2e-nested' | sed 's/^ID [0-9]* gen [0-9]* top level [0-9]* path //'); file says: $(cat "$top/root.spike-new/opt/e2e-nested/file" 2>&1)"
say "3. and the old root still runs: $(ls /opt | tr '\n' ' ')"

# 4. one whose parent is missing in the copy
mkdir -p "$top/root.spike-new/srv/e2e-after/deeper" && mv "$top/root/srv/e2e-after/deeper/vol" "$top/root.spike-new/srv/e2e-after/deeper/vol" && say "4. moved a nested subvolume into a parent created for it: ok" || say "4. FAILED"
say "4. file says: $(cat "$top/root.spike-new/srv/e2e-after/deeper/vol/file" 2>&1)"

# what a path that is a regular, non-empty directory in the copy does to a move
mkdir -p "$top/root.spike-new/srv/conflict" && echo x > "$top/root.spike-new/srv/conflict/in-the-way"
btrfs subvolume create /srv/conflict-vol >/dev/null
if mv "$top/root/srv/conflict-vol" "$top/root.spike-new/srv/conflict" 2>/dev/null; then say "5. moving a subvolume ONTO a non-empty directory: succeeded (unexpected)"; else say "5. moving a subvolume onto a non-empty directory is refused (so a conflict can be detected and left alone)"; fi

# clean up everything this made
for d in "$top/root.spike-new/opt/e2e-nested" "$top/root.spike-new/srv/e2e-after/deeper/vol" /srv/conflict-vol; do btrfs subvolume delete "$d" >/dev/null 2>&1; done
btrfs subvolume delete "$top/root.spike-new" >/dev/null 2>&1
rm -rf /srv/e2e-after
umount "$top"
say "done"
