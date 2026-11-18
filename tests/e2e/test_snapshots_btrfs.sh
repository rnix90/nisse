#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-305: the nisse-snapshots scripts against the REAL snapper on a throwaway loop btrfs. Run in the Fedora build VM
# (needs sudo, btrfs-progs, snapper). Checks that setup applies the template, that the hook makes a real pre/post pair,
# that snapper's own cleanup keeps 20 pairs, and that the prune script removes pairs older than 14 days.
set -u
cd "$(dirname "$0")/../.."
dir="$PWD/packaging/rpm/nisse-snapshots"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

img="$(mktemp -u /tmp/nisse-snap-XXXXXX.img)"
mnt="$(mktemp -d /tmp/nisse-snap-mnt-XXXXXX)"
cfg=nissetest
state="$(mktemp -d)"
cleanup() {
    sudo snapper --no-dbus -c "$cfg" delete-config >/dev/null 2>&1
    sudo rm -f "/etc/snapper/configs/$cfg"
    sudo umount "$mnt" 2>/dev/null
    rm -rf "$img" "$mnt" "$state"
}
trap cleanup EXIT

truncate -s 1G "$img" && sudo mkfs.btrfs -q -f "$img" && sudo mount -o loop "$img" "$mnt" || { echo "FAIL: cannot make the loop btrfs"; exit 1; }
sudo chown "$(id -u)" "$mnt"

export NISSE_SNAPSHOT_CONFIG=$cfg NISSE_SNAPSHOT_SUBVOLUME="$mnt" NISSE_ROOT_FSTYPE=btrfs NISSE_STATE_DIR="$state" NISSE_FREE_PERCENT=90
export NISSE_SNAPSHOT_TEMPLATE="$dir/root.conf"
run() { sudo env "NISSE_SNAPSHOT_CONFIG=$cfg" "NISSE_SNAPSHOT_SUBVOLUME=$mnt" "NISSE_ROOT_FSTYPE=btrfs" "NISSE_STATE_DIR=$state" \
        "NISSE_FREE_PERCENT=90" "NISSE_SNAPSHOT_TEMPLATE=$dir/root.conf" "$@"; }

# ---- setup
run sh "$dir/nisse-snapshot-setup" >/dev/null 2>&1 && ok "setup: exit 0" || bad "setup failed"
conf="$(sudo snapper --no-dbus -c "$cfg" --csvout get-config 2>&1)"
for kv in TIMELINE_CREATE=no NUMBER_CLEANUP=yes NUMBER_LIMIT=40 EMPTY_PRE_POST_CLEANUP=yes; do
    k="${kv%%=*}"; v="${kv#*=}"
    got="$(awk -F',' -v k="$k" '$1==k {print $2}' <<< "$conf")"
    [ "$got" = "$v" ] && ok "setup: $k=$v on the real config" || bad "setup: $k is '$got', wanted '$v'"
done
run sh "$dir/nisse-snapshot-setup" >/dev/null 2>&1 && ok "setup: a second run is a no-op, exit 0" || bad "setup: second run failed"

# ---- hook: a real pair around a change
echo before | sudo tee "$mnt/f" >/dev/null
run sh "$dir/nisse-snapshot-hook" pre
echo after | sudo tee "$mnt/f" >/dev/null
run sh "$dir/nisse-snapshot-hook" post
list="$(sudo snapper --no-dbus -c "$cfg" --csvout list --columns number,type,pre-number,cleanup,userdata)"
echo "$list" | sed 's/^/     /'
grep -q '^1,pre,,number,nisse=package-transaction' <<< "$list" && ok "hook: snapshot 1 is a pre snapshot tagged number / package-transaction" || bad "hook: no pre snapshot"
grep -q '^2,post,1,number,nisse=package-transaction' <<< "$list" && ok "hook: snapshot 2 is the post snapshot paired with 1" || bad "hook: no paired post snapshot"
[ "$(sudo cat "$mnt/.snapshots/1/snapshot/f")" = before ] && [ "$(sudo cat "$mnt/.snapshots/2/snapshot/f")" = after ] \
    && ok "hook: the pair brackets the change (pre has 'before', post has 'after')" || bad "hook: the snapshots do not bracket the change"

# ---- snapper's own cleanup keeps 20 pairs (40 snapshots)
for i in $(seq 3 25); do
    run sh "$dir/nisse-snapshot-hook" pre
    echo "v$i" | sudo tee "$mnt/f" >/dev/null
    run sh "$dir/nisse-snapshot-hook" post
done
sudo snapper --no-dbus -c "$cfg" set-config NUMBER_MIN_AGE=0 >/dev/null   # test only: the template keeps fresh snapshots for an hour
sudo snapper --no-dbus -c "$cfg" cleanup number >/dev/null 2>&1
n="$(sudo snapper --no-dbus -c "$cfg" --csvout list --columns number,type | grep -c ',pre$\|,post$')"
pairs="$(sudo snapper --no-dbus -c "$cfg" --csvout list --columns number,type | grep -c ',post$')"
[ "$n" = 40 ] && [ "$pairs" = 20 ] && ok "cleanup: 25 pairs shrink to 20 pairs (40 snapshots)" || bad "cleanup: $n snapshots, $pairs pairs; wanted 40 and 20"

# ---- prune: age
sudo snapper --no-dbus -c "$cfg" create -t single -c "" -d "made by hand" >/dev/null
far=$(( $(date +%s) + 20 * 86400 ))
run env NISSE_NOW=$far sh "$dir/nisse-snapshot-prune" > "$state/prune.out" 2>&1 && ok "prune: exit 0" || bad "prune failed: $(cat "$state/prune.out")"
left="$(sudo snapper --no-dbus -c "$cfg" --csvout list --columns number,type,cleanup | tail -n +2)"
grep -q ',number$' <<< "$left" && bad "prune: pairs older than 14 days are still there: $(grep ',number$' <<< "$left" | head -3 | tr '\n' ' ')" || ok "prune: every pair older than 14 days is gone"
grep -q ',single,' <<< "$left" && ok "prune: left the snapshot made by hand" || bad "prune: removed a snapshot nisse did not make"
run env NISSE_NOW=$(date +%s) sh "$dir/nisse-snapshot-prune" >/dev/null 2>&1 && ok "prune: a second run with nothing old is exit 0" || bad "prune: second run failed"

echo
[ "$failures" = 0 ] && echo "PASS: snapshots on a real btrfs" || { echo "$failures failed"; exit 1; }
