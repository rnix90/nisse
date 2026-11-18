#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306: the nisse daemon's snapshot pair around an AI turn, against the REAL nisse-snapshot-batch helper (through
# sudo) and the REAL snapper, on a throwaway loop btrfs. Run in the Fedora build VM (needs sudo, btrfs-progs, snapper,
# cargo). The tests it runs are the ignored "real_" tests of services/crates/nisse-daemon/tests/snapshots.rs.
set -u
cd "$(dirname "$0")/../.."
root="$PWD"
img="$(mktemp -u /tmp/nisse-dsnap-XXXXXX.img)"
mnt="$(mktemp -d /tmp/nisse-dsnap-mnt-XXXXXX)"
cfg=nissedaemon
cleanup() {
    sudo snapper --no-dbus -c "$cfg" delete-config >/dev/null 2>&1
    sudo rm -f "/etc/snapper/configs/$cfg"
    sudo umount "$mnt" 2>/dev/null
    rm -rf "$img" "$mnt"
}
trap cleanup EXIT

truncate -s 1G "$img" && sudo mkfs.btrfs -q -f "$img" && sudo mount -o loop "$img" "$mnt" || { echo "FAIL: cannot make the loop btrfs"; exit 1; }
sudo env NISSE_SNAPSHOT_CONFIG="$cfg" NISSE_SNAPSHOT_SUBVOLUME="$mnt" NISSE_ROOT_FSTYPE=btrfs \
    NISSE_SNAPSHOT_TEMPLATE="$root/packaging/rpm/nisse-snapshots/root.conf" \
    sh "$root/packaging/rpm/nisse-snapshots/nisse-snapshot-setup" >/dev/null || { echo "FAIL: setup"; exit 1; }

cd "$root/services" || exit 1
NISSE_E2E_CONFIG="$cfg" NISSE_E2E_SCRIPT="$root/packaging/rpm/nisse-snapshots/nisse-snapshot-batch" \
    cargo test -p nisse-daemon --test snapshots -- --ignored --test-threads=1 real_ 2>&1 | tail -15
rc=${PIPESTATUS[0]}
echo
[ "$rc" = 0 ] && echo "PASS: the daemon snapshots AI turns on a real btrfs" || { echo "FAIL (cargo test exit $rc)"; exit 1; }
