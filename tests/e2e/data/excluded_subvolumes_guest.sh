#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The steps tests/e2e/test_excluded_subvolumes.sh (N-312) runs INSIDE the installed nisse disk, as root. Stages:
#   setup     make a data subvolume mounted from fstab and a nested subvolume, write a file into home, var_log, var_cache, the data
#             subvolume and the nested subvolume, then take the snapshot to go back to; prints N=<snapshot number>
#   after     change the root, and write more into every one of those; make a nested subvolume under parents the snapshot does not
#             have; make a second data subvolume whose fstab line is added only now
#   rollback  nisse-rollback run N --reboot (its output goes to /home, which survives)
#   check     print "CHECK name=value" lines about what the restored system holds
set -u
dev="$(findmnt -no SOURCE / | sed 's/\[.*//')"
uuid="$(findmnt -no UUID /)"
top=/mnt/top
mount_top() { mkdir -p "$top" && mount -o subvolid=5 "$dev" "$top"; }

case "${1:-}" in
    setup)
        mount_top || exit 1
        btrfs subvolume create "$top/e2e_data" >/dev/null
        mkdir -p /srv/e2e-data /opt
        printf 'UUID=%s /srv/e2e-data btrfs subvol=e2e_data,compress=zstd:1 0 0\n' "$uuid" >> /etc/fstab
        systemctl daemon-reload
        mount /srv/e2e-data || { echo "ERROR: cannot mount the data subvolume"; exit 1; }
        btrfs subvolume create /opt/e2e-nested >/dev/null
        mkdir -p /home/e2e
        echo home-before > /home/e2e/before
        echo log-before > /var/log/e2e-before
        echo cache-before > /var/cache/e2e-before
        echo data-before > /srv/e2e-data/before
        echo nested-before > /opt/e2e-nested/before
        umount "$top"
        sync
        echo "N=$(snapper -c root create -p -d e2e-target)"
        ;;
    after)
        echo root-change > /etc/e2e-root-change
        echo home-after >> /home/e2e/before; echo home-new > /home/e2e/after
        echo log-after >> /var/log/e2e-before; echo log-new > /var/log/e2e-after
        echo cache-after >> /var/cache/e2e-before; echo cache-new > /var/cache/e2e-after
        echo data-after >> /srv/e2e-data/before; echo data-new > /srv/e2e-data/after
        echo nested-after >> /opt/e2e-nested/before; echo nested-new > /opt/e2e-nested/after
        mkdir -p /srv/e2e-late/deeper
        btrfs subvolume create /srv/e2e-late/deeper/vol >/dev/null
        echo late > /srv/e2e-late/deeper/vol/file
        mount_top || exit 1
        btrfs subvolume create "$top/e2e_data2" >/dev/null
        mkdir -p /srv/e2e-data2
        printf 'UUID=%s /srv/e2e-data2 btrfs subvol=e2e_data2 0 0\n' "$uuid" >> /etc/fstab
        systemctl daemon-reload
        mount /srv/e2e-data2
        echo data2 > /srv/e2e-data2/file
        umount "$top"
        sync
        echo "after done"
        ;;
    rollback)
        nisse-rollback run "${2:?snapshot number}" --reason "e2e: excluded subvolumes" --reboot > /home/e2e-rollback.out 2>&1
        echo "rollback exit $?"
        ;;
    check)
        flat() { tr '\n' ',' | sed 's/,$//'; }
        echo "CHECK root-change=$(test -e /etc/e2e-root-change && echo present || echo gone)"
        echo "CHECK root-subvol=$(findmnt -no OPTIONS / | grep -o 'subvol=[^,]*')"
        echo "CHECK home-before=$(flat < /home/e2e/before 2>/dev/null)"
        echo "CHECK home-after=$(flat < /home/e2e/after 2>/dev/null)"
        echo "CHECK log-before=$(flat < /var/log/e2e-before 2>/dev/null)"
        echo "CHECK log-after=$(flat < /var/log/e2e-after 2>/dev/null)"
        echo "CHECK cache-before=$(flat < /var/cache/e2e-before 2>/dev/null)"
        echo "CHECK cache-after=$(flat < /var/cache/e2e-after 2>/dev/null)"
        echo "CHECK data-mount=$(findmnt -no OPTIONS /srv/e2e-data 2>/dev/null | grep -o 'subvol=[^,]*')"
        echo "CHECK data-before=$(flat < /srv/e2e-data/before 2>/dev/null)"
        echo "CHECK data-after=$(flat < /srv/e2e-data/after 2>/dev/null)"
        echo "CHECK nested-is-subvolume=$(btrfs subvolume show /opt/e2e-nested >/dev/null 2>&1 && echo yes || echo no)"
        echo "CHECK nested-before=$(flat < /opt/e2e-nested/before 2>/dev/null)"
        echo "CHECK nested-after=$(flat < /opt/e2e-nested/after 2>/dev/null)"
        echo "CHECK late-is-subvolume=$(btrfs subvolume show /srv/e2e-late/deeper/vol >/dev/null 2>&1 && echo yes || echo no)"
        echo "CHECK late-file=$(flat < /srv/e2e-late/deeper/vol/file 2>/dev/null)"
        echo "CHECK data2-mounted=$(findmnt -no TARGET /srv/e2e-data2 >/dev/null 2>&1 && echo yes || echo no)"
        echo "CHECK nested-left=$(sed -n 's/^nested-left=//p' /var/lib/nisse/update/state 2>/dev/null)"
        echo "CHECK rollback-out=$(head -c 600 /home/e2e-rollback.out 2>/dev/null | tr '\n' '|')"
        mount_top || exit 1
        echo "CHECK failed-root-nested=$(ls -d "$top"/root.failed-*/opt/e2e-nested/before 2>/dev/null | wc -l)"
        echo "CHECK failed-root-late=$(ls -d "$top"/root.failed-*/srv/e2e-late/deeper/vol/file 2>/dev/null | wc -l)"
        echo "CHECK data2-still-there=$(flat < "$top/e2e_data2/file" 2>/dev/null)"
        echo "CHECK top-level=$(ls "$top" | tr '\n' ' ')"
        umount "$top"
        ;;
    *)
        echo "usage: excluded_subvolumes_guest.sh setup | after | rollback N | check" >&2
        exit 2
        ;;
esac
