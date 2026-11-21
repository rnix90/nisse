#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-310: tests nisse-rollback (the swap of the root subvolume for a copy of a snapshot) against a directory standing in for the
# btrfs top level, a fake btrfs, nisse-boot, grub2-editenv and systemctl. No btrfs, no root. The real btrfs, snapper and GRUB
# are tests/e2e/test_rollback.sh. The mechanism itself was proven on an installed disk first (tools/spike/rollback_swap_spike.sh).
set -u
cd "$(dirname "$0")/../.."
tool="$PWD/packaging/rpm/nisse-update/nisse-rollback"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

KVER=6.19.10-300.fc44.x86_64
NEWK=7.3.4-200.fc44.x86_64

# A fresh sandbox: a top level with the running root (`root`, holding .snapshots/41/snapshot and .snapshots/42/snapshot), a /boot
# with the kernel snapshot 41 has modules for, and fakes that log every call to $work/calls.
fresh() {
    work="$(mktemp -d)"
    top="$work/top"
    boot="$work/boot"
    mkdir -p "$top/root/etc" "$top/root/var/lib/nisse/update" "$top/root/var/lib/nisse/boot" "$top/home" "$top/var_log"
    mkdir -p "$top/root/.snapshots/41/snapshot/etc" "$top/root/.snapshots/41/snapshot/usr/lib/modules/$KVER" "$top/root/.snapshots/41/snapshot/.snapshots"
    mkdir -p "$top/root/.snapshots/41/snapshot/var/lib/nisse/update"
    mkdir -p "$top/root/.snapshots/42/snapshot/etc" "$top/root/.snapshots/42/snapshot/usr/lib/modules/$KVER" "$top/root/.snapshots/42/snapshot/.snapshots"
    echo old > "$top/root/.snapshots/41/snapshot/etc/marker"
    echo post > "$top/root/.snapshots/42/snapshot/etc/marker"
    echo new > "$top/root/etc/marker"
    echo only-in-failed > "$top/root/etc/failed-only"
    printf 'state=pending-verify\nsnapshot=41\nfingerprint=abc123\nchanged=2\n' > "$top/root/var/lib/nisse/update/state"
    printf 'firefox-131-1\nkernel-core-7.3.4-200\n' > "$top/root/var/lib/nisse/update/changed.txt"
    printf 'result=unhealthy\nfailed=20-network\nmessage-20-network=NetworkManager does not answer\n' > "$top/root/var/lib/nisse/update/health"
    echo 41 > "$top/root/var/lib/nisse/boot/armed"
    mkdir -p "$boot/loader/entries" "$boot/grub2"
    touch "$boot/vmlinuz-$KVER" "$boot/initramfs-$KVER.img"
    echo "title old" > "$boot/loader/entries/0123abcd-$KVER.conf"
    export NISSE_TOP_DIR="$top"
    export NISSE_BOOT_DIR="$boot"
    export NISSE_BTRFS="$work/btrfs"
    export NISSE_BOOT_TOOL="$work/nisse-boot"
    export NISSE_GRUB_EDITENV="$work/grub2-editenv"
    export NISSE_SYSTEMCTL="$work/systemctl"
    export NISSE_ROOT_FSTYPE=btrfs
    export NISSE_FSROOT=/root
    export NISSE_CMDLINE_FILE="$work/cmdline"
    export NISSE_NOW=1700000000
    export STUB_DIR="$work"
    export TZ=UTC
    echo "BOOT_IMAGE=x root=UUID=1 ro rootflags=subvol=root" > "$work/cmdline"
    : > "$work/calls"
    echo "saved_entry=0123abcd-$KVER" > "$work/env"
    echo "boot_counter=2" >> "$work/env"
    unset BTRFS_FAIL
    cat > "$work/btrfs" <<'STUB'
#!/bin/sh
echo "btrfs $*" >> "$STUB_DIR/calls"
if [ "$1 $2" = "subvolume list" ]; then
    # list -o PATH: the subvolumes nested under PATH, printed the way btrfs prints them (the path from the top level). In this fake
    # a directory is a subvolume when it holds a file called .nisse-subvol.
    [ "$3" = "-o" ] || exit 1
    find "$4" -name .nisse-subvol | sort | while read -r m; do
        d="${m%/.nisse-subvol}"
        echo "ID 300 gen 9 top level 5 path ${d#$NISSE_TOP_DIR/}"
    done
    [ -f "$STUB_DIR/list.extra" ] && cat "$STUB_DIR/list.extra"
    exit 0
fi
[ "$1 $2" = "subvolume snapshot" ] || [ "$1 $2" = "subvolume delete" ] || exit 1
if [ "$2" = snapshot ]; then
    [ -n "${BTRFS_FAIL:-}" ] && { echo "ERROR: cannot snapshot" >&2; exit 1; }
    cp -a "$3" "$4"
else
    rm -rf "$3"
fi
STUB
    cat > "$work/nisse-boot" <<'STUB'
#!/bin/sh
# records what the top level looks like at the moment GRUB is disarmed: the swap must be done by then
state=old-root-in-place
[ -f "$NISSE_TOP_DIR/root/etc/marker" ] && [ "$(cat "$NISSE_TOP_DIR/root/etc/marker")" = old ] && state=new-root-in-place
echo "nisse-boot $* ($state)" >> "$STUB_DIR/calls"
exit 0
STUB
    cat > "$work/grub2-editenv" <<'STUB'
#!/bin/sh
echo "grub2-editenv $*" >> "$STUB_DIR/calls"
if [ "$1" = list ]; then cat "$STUB_DIR/env"; exit 0; fi
if [ "$1 $2" = "- set" ]; then
    shift 2
    for kv in "$@"; do
        k="${kv%%=*}"
        grep -v "^$k=" "$STUB_DIR/env" > "$STUB_DIR/env.new"; echo "$kv" >> "$STUB_DIR/env.new"; mv "$STUB_DIR/env.new" "$STUB_DIR/env"
    done
fi
exit 0
STUB
    cat > "$work/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >> "$STUB_DIR/calls"
exit 0
STUB
    chmod +x "$work/btrfs" "$work/nisse-boot" "$work/grub2-editenv" "$work/systemctl"
}
has_call() { grep -q -- "$1" "$work/calls"; }
call_line() { grep -n -- "$1" "$work/calls" | head -1 | cut -d: -f1; }
run() { sh "$tool" "$@" 2>&1; }
new_state() { cat "$top/root/var/lib/nisse/update/state" 2>/dev/null; }
new_has() { new_state | grep -qx -- "$1"; }
failed_dir() { ls -d "$top"/root.failed-* 2>/dev/null | head -1; }
# the top level exactly as it was: nothing was swapped
untouched() { [ "$(cat "$top/root/etc/marker")" = new ] && [ -d "$top/root/.snapshots/41/snapshot" ] && [ -z "$(failed_dir)" ] && [ ! -e "$top/root.rollback-new" ]; }

# ---- the swap
fresh
out="$(run run 41 --reason "the network check failed")"; rc=$?
[ "$rc" = 0 ] && ok "run: exit 0" || bad "run: exit $rc: $out"
[ "$(cat "$top/root/etc/marker" 2>/dev/null)" = old ] && ok "run: the new root is a copy of snapshot 41 (its file, not the failed root's)" || bad "run: root marker is '$(cat "$top/root/etc/marker" 2>&1)'"
[ ! -e "$top/root/etc/failed-only" ] && ok "run: what only the failed root had is gone from the new root" || bad "run: the failed root's file leaked into the new root"
fd="$(failed_dir)"
[ "$fd" = "$top/root.failed-1700000000" ] && ok "run: the failed root is kept for inspection as root.failed-<time>" || bad "run: failed dir '$fd'"
[ -n "$fd" ] && [ "$(cat "$fd/etc/failed-only" 2>/dev/null)" = only-in-failed ] && ok "run: the kept root is the old running one" || bad "run: the kept root is wrong"
[ -d "$top/root/.snapshots/41/snapshot" ] && [ -d "$top/root/.snapshots/42/snapshot" ] && ok "run: .snapshots moved into the new root with every snapshot" || bad "run: snapshots are not under the new root"
[ -n "$fd" ] && [ ! -e "$fd/.snapshots" ] && ok "run: the failed root no longer holds .snapshots" || bad "run: the failed root still has .snapshots"
[ ! -e "$top/root.rollback-new" ] && ok "run: no temporary name is left" || bad "run: root.rollback-new is still there"
[ -d "$top/home" ] && [ -d "$top/var_log" ] && ok "run: the excluded subvolumes (home, var_log) were not touched" || bad "run: home or var_log vanished"
has_call 'btrfs subvolume snapshot .*/root/.snapshots/41/snapshot ' && ok "run: the copy is a writable btrfs snapshot (no -r) of snapshot 41" || bad "run: btrfs calls: $(grep btrfs "$work/calls")"
has_call 'btrfs subvolume snapshot -r' && bad "run: the new root was made read-only" || ok "run: the new root is not read-only"

# ---- what the new root records
new_has "state=idle" && new_has "last=rolled-back" && ok "run: the new root's state is idle with last=rolled-back" || bad "run: new state: $(new_state)"
new_has "rolled-back-at=1700000000" && ok "run: records when" || bad "run: rolled-back-at"
new_has "snapshot=41" && ok "run: records the snapshot it went back to" || bad "run: snapshot"
new_has "reason=the network check failed" && ok "run: records the reason in one line" || bad "run: reason: $(new_state)"
new_has "rolled-back-from=root.failed-1700000000" && ok "run: records where the failed root is" || bad "run: rolled-back-from"
new_has "blocked-fingerprint=abc123" && ok "run: carries the failed update's fingerprint so the same update is not tried again" || bad "run: blocked-fingerprint: $(new_state)"
cmp -s "$top/root/var/lib/nisse/update/failed-changed.txt" "$fd/var/lib/nisse/update/changed.txt" && ok "run: keeps the failed update's package list as failed-changed.txt" || bad "run: failed-changed.txt"
grep -q 'message-20-network=NetworkManager does not answer' "$top/root/var/lib/nisse/update/failed-health" 2>/dev/null && ok "run: keeps the failing health result as failed-health" || bad "run: failed-health"
[ "$(cat "$top/root/var/lib/nisse/boot/armed" 2>/dev/null)" = 41 ] && ok "run: hands the arm record to the new root so the next boot's reconcile hands snapshot 41 back to cleanup" || bad "run: armed record: '$(cat "$top/root/var/lib/nisse/boot/armed" 2>&1)'"

# ---- GRUB, the boot entry, the reboot
l="$(call_line 'nisse-boot clear')"
[ -n "$l" ] && grep -q 'nisse-boot clear (new-root-in-place)' "$work/calls" && ! grep -q 'nisse-boot clear (old-root-in-place)' "$work/calls" && ok "run: GRUB is disarmed only AFTER the swap (nisse-boot clear saw the new root in place)" || bad "run: clear: $(grep nisse-boot "$work/calls")"
has_call 'systemctl reboot' && bad "run: rebooted without --reboot" || ok "run: does not reboot unless told to"
case "$out" in *"reboot"*) ok "run: says a reboot is needed" ;; *) bad "run: no word about the reboot: $out" ;; esac
grep -qx "saved_entry=0123abcd-$KVER" "$work/env" && ok "run: the default entry is the snapshot's own kernel (it already was)" || bad "run: saved_entry: $(cat "$work/env")"
! has_call 'grub2-editenv - set saved_entry' && ok "run: the default entry is left alone when it is already right" || bad "run: touched saved_entry needlessly"

fresh
run run 41 --reboot >/dev/null
r="$(call_line 'systemctl reboot')"; c="$(call_line 'nisse-boot clear')"
[ -n "$r" ] && [ "$c" -lt "$r" ] && ok "run --reboot: disarms GRUB first, then reboots" || bad "run --reboot: order $c $r"

# ---- a newer kernel was installed by the failed update: the default entry must go back to the snapshot's kernel
fresh
touch "$boot/vmlinuz-$NEWK" "$boot/initramfs-$NEWK.img"
echo "title new" > "$boot/loader/entries/0123abcd-$NEWK.conf"
echo "saved_entry=0123abcd-$NEWK" > "$work/env"; echo "boot_counter=2" >> "$work/env"
out="$(run run 41)"; rc=$?
[ "$rc" = 0 ] && grep -qx "saved_entry=0123abcd-$KVER" "$work/env" && ok "newer kernel: the default boot entry is set back to the snapshot's kernel ($KVER)" || bad "newer kernel: rc=$rc env=$(cat "$work/env")"
fresh
touch "$boot/vmlinuz-$NEWK" "$boot/initramfs-$NEWK.img"
echo "title new" > "$boot/loader/entries/0123abcd-$NEWK.conf"
: > "$work/env"
out="$(run run 41)"; rc=$?
grep -qx "saved_entry=0123abcd-$KVER" "$work/env" && ok "newer kernel, no saved entry: GRUB would pick the newest, so the entry is set to the snapshot's kernel" || bad "newer kernel, unset: rc=$rc env=$(cat "$work/env")"
fresh
touch "$boot/vmlinuz-$NEWK" "$boot/initramfs-$NEWK.img"
echo "saved_entry=0123abcd-$NEWK" > "$work/env"
rm -f "$boot/loader/entries/0123abcd-$KVER.conf"
out="$(run run 41)"; rc=$?
[ "$rc" != 0 ] && untouched && ok "newer kernel with no boot entry for the old one: refused before anything is swapped" || bad "no old entry: rc=$rc"

# ---- refusals leave everything as it was
fresh
out="$(run run 99)"; rc=$?
[ "$rc" != 0 ] && untouched && ok "refuse: a snapshot that does not exist" || bad "refuse: missing snapshot rc=$rc"
fresh
for arg in 0 abc "" "4 1" -5; do
    out="$(run run $arg 2>&1)"; rc=$?
    [ "$rc" != 0 ] && untouched || { bad "refuse: argument '$arg' accepted (rc=$rc)"; fresh; }
done
ok "refuse: snapshot 0, words, nothing, two numbers and a negative are all refused"
fresh
echo "BOOT_IMAGE=x root=live:CDLABEL=x rd.live.image" > "$work/cmdline"
out="$(run run 41)"; rc=$?
[ "$rc" != 0 ] && untouched && ok "refuse: live media" || bad "refuse: live media rc=$rc"
fresh
export NISSE_ROOT_FSTYPE=ext4
out="$(run run 41)"; rc=$?
[ "$rc" != 0 ] && untouched && ok "refuse: a root that is not btrfs" || bad "refuse: ext4 rc=$rc"
fresh
rm -f "$boot/vmlinuz-$KVER"
out="$(run run 41)"; rc=$?
[ "$rc" != 0 ] && untouched && case "$out" in *"snapshot 41 has no kernel that is still in"*) ok "refuse: a snapshot whose kernel is gone from /boot (it could not boot), and it says why" ;; *) bad "refuse: wrong reason: $out" ;; esac || bad "refuse: no kernel rc=$rc"
fresh
export BTRFS_FAIL=1
out="$(run run 41)"; rc=$?
[ "$rc" != 0 ] && untouched && ! has_call 'nisse-boot clear' && ok "a failed copy: nothing is swapped and GRUB stays armed" || bad "failed copy: rc=$rc"
unset BTRFS_FAIL

# ---- a leftover of a crashed run, and only the newest failed root is kept
fresh
mkdir -p "$top/root.rollback-new/stale"
out="$(run run 41)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$top/root.rollback-new" ] && [ "$(cat "$top/root/etc/marker")" = old ] && ok "a stale root.rollback-new from a crashed run is cleared and the run succeeds" || bad "stale: rc=$rc"
fresh
mkdir -p "$top/root.failed-1600000000/etc" "$top/root.failed-1650000000/etc"
out="$(run run 41)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$top/root.failed-1600000000" ] && [ ! -e "$top/root.failed-1650000000" ] && [ -d "$top/root.failed-1700000000" ] && ok "older failed roots are deleted; only the newest one is kept" || bad "old failed roots: $(ls "$top")"
fresh
mkdir -p "$top/root.failed-1600000000/etc"
export BTRFS_FAIL=1
run run 41 >/dev/null
[ -d "$top/root.failed-1600000000" ] && ok "an older failed root is NOT deleted when the run fails" || bad "older failed root deleted by a failed run"
unset BTRFS_FAIL

# ---- from the fallback boot: the running root is a read-only snapshot inside the real root
fresh
export NISSE_FSROOT=/root/.snapshots/41/snapshot
out="$(run run 41 --reason "the updated system never finished starting")"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$top/root/etc/marker")" = old ] && [ -d "$top/root/.snapshots/42/snapshot" ] && ok "from a snapshot boot: the same swap works on the real root" || bad "snapshot boot: rc=$rc $out"
new_has "blocked-fingerprint=abc123" && ok "from a snapshot boot: the failed update's state is read from the real root, not from the running snapshot" || bad "snapshot boot: state $(new_state)"
export NISSE_FSROOT=/root

# ---- nested subvolumes (N-312): a subvolume nested inside the root is not in a snapshot (the copy holds an empty placeholder
# directory where it was), so the swap carries it across, or it would stay behind in the kept old root and its files would seem to
# vanish. Checked first on a real btrfs (tools/spike/nested_subvolume_spike.sh): the placeholder is removed, then the subvolume is
# moved to the path that is now free (mv onto an existing directory moves it INSIDE that directory, so a path is never moved onto).
nested_fresh() {
    fresh
    # the copy of snapshot 41 has an empty placeholder where /opt/data was a subvolume
    mkdir -p "$top/root/.snapshots/41/snapshot/opt/data"
    # in the running root /opt/data is a subvolume (a directory holding .nisse-subvol in this fake) with a file
    mkdir -p "$top/root/opt/data"; touch "$top/root/opt/data/.nisse-subvol"; echo precious > "$top/root/opt/data/file"
    # .snapshots and every snapshot are subvolumes too: they move on their own and must never be carried as nested ones
    touch "$top/root/.snapshots/.nisse-subvol" "$top/root/.snapshots/41/snapshot/.nisse-subvol" "$top/root/.snapshots/42/snapshot/.nisse-subvol"
}
nested_fresh
out="$(run run 41)"; rc=$?
fd="$(failed_dir)"
[ "$rc" = 0 ] && [ "$(cat "$top/root/opt/data/file" 2>/dev/null)" = precious ] && [ -e "$top/root/opt/data/.nisse-subvol" ] && ok "nested: a subvolume nested in the old root is carried to the same place in the restored root, with its files" || bad "nested: rc=$rc file='$(cat "$top/root/opt/data/file" 2>&1)' out=$out"
[ -n "$fd" ] && [ ! -e "$fd/opt/data" ] && ok "nested: it is no longer in the kept old root" || bad "nested: still in the kept root: $(ls "$fd/opt" 2>&1)"
case "$out" in *"carried 1 nested subvolume"*"opt/data"*) ok "nested: the output says what was carried" ;; *) bad "nested: no word about the carried subvolume: $out" ;; esac
[ -d "$top/root/.snapshots/41/snapshot" ] && [ -e "$top/root/.snapshots/.nisse-subvol" ] && [ -e "$top/root/.snapshots/41/snapshot/.nisse-subvol" ] && ok "nested: .snapshots and the snapshots in it are not treated as nested subvolumes (they moved on their own, once)" || bad "nested: the snapshots were disturbed"
printf '%s\n' "$out" | grep -q 'carried.*\.snapshots' && bad "nested: .snapshots was carried as a nested subvolume" || ok "nested: .snapshots is not in the list of carried subvolumes"
has_call 'btrfs subvolume list -o ' && ok "nested: the old root's nested subvolumes come from btrfs subvolume list -o" || bad "nested: no list -o call: $(grep btrfs "$work/calls")"
nested_fresh
mkdir -p "$top/root/srv/new/deeper/vol"; touch "$top/root/srv/new/deeper/vol/.nisse-subvol"; echo late > "$top/root/srv/new/deeper/vol/file"
out="$(run run 41)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$top/root/srv/new/deeper/vol/file" 2>/dev/null)" = late ] && ok "nested: one made AFTER the snapshot, under parents the restored root does not have, is carried too (its parents are made)" || bad "nested after the snapshot: rc=$rc $out"
case "$out" in *"carried 2 nested"*) ok "nested: both are counted" ;; *) bad "nested: count: $out" ;; esac
nested_fresh
mkdir -p "$top/root/opt/data/inner"; touch "$top/root/opt/data/inner/.nisse-subvol"; echo deep > "$top/root/opt/data/inner/file"
out="$(run run 41)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$top/root/opt/data/inner/file" 2>/dev/null)" = deep ] && ok "nested: a subvolume inside a nested one goes with it" || bad "nested in nested: rc=$rc $out"
case "$out" in *"carried 1 nested"*) ok "nested: only the outer one is moved (it takes the inner one along)" ;; *) bad "nested in nested: moved separately: $out" ;; esac
case "$out" in *left*) bad "nested in nested: the inner one was reported as left behind: $out" ;; *) ok "nested: the inner one is not reported as left behind (it went with the outer one)" ;; esac
new_state | grep -q '^nested-left=' && bad "nested in nested: the record says something was left: $(new_state)" || ok "nested: and the record names nothing as left"
# the listing may name .snapshots or a snapshot in it (a real btrfs does until .snapshots has been moved): never carried
nested_fresh
printf 'ID 301 gen 9 top level 5 path root/.snapshots\nID 302 gen 9 top level 5 path root/.snapshots/41/snapshot\nID 303 gen 9 top level 5 path root/.snapshots/42/snapshot\n' > "$work/list.extra"
out="$(run run 41)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$top/root/opt/data/file" 2>/dev/null)" = precious ] && ok "nested: .snapshots and the snapshots named in the listing are skipped, the real nested subvolume is still carried" || bad "nested with .snapshots in the listing: rc=$rc $out"
case "$out" in *"carried 1 nested"*) ok "nested: and only that one is counted" ;; *) bad "nested with .snapshots in the listing: $out" ;; esac
case "$out" in *left*) bad "nested: .snapshots was reported as a nested subvolume left behind: $out" ;; *) ok "nested: nothing about .snapshots is reported as left behind" ;; esac
new_state | grep -q '^nested-left=' && bad "nested: the record names .snapshots as left: $(new_state)" || ok "nested: and the record names nothing as left"
fresh
out="$(run run 41)"
printf '%s\n' "$out" | grep -qi 'nested' && bad "nested: said something about nested subvolumes when there are none: $out" || ok "nested: nothing nested, nothing said"

# a conflict: something is already at that path in the restored root. The subvolume is LEFT in the kept old root, the rollback still
# goes through, and the record says which were left.
nested_fresh
echo x > "$top/root/.snapshots/41/snapshot/opt/data/in-the-way"
out="$(run run 41)"; rc=$?
fd="$(failed_dir)"
[ "$rc" = 0 ] && [ "$(cat "$top/root/opt/data/in-the-way" 2>/dev/null)" = x ] && [ ! -e "$top/root/opt/data/file" ] && ok "nested conflict: a non-empty directory in the way is left alone (nothing is moved into it or over it)" || bad "nested conflict: rc=$rc $out"
[ -n "$fd" ] && [ "$(cat "$fd/opt/data/file" 2>/dev/null)" = precious ] && ok "nested conflict: the subvolume stays in the kept old root, files intact" || bad "nested conflict: not kept: $(ls "$fd/opt" 2>&1)"
case "$out" in *"left"*"opt/data"*) ok "nested conflict: the output says it was left, and where" ;; *) bad "nested conflict: no word: $out" ;; esac
new_has "nested-left=opt/data" && ok "nested conflict: the record names it (nested-left=)" || bad "nested conflict: state $(new_state)"
nested_fresh
rm -rf "$top/root/.snapshots/41/snapshot/opt/data"; echo x > "$top/root/.snapshots/41/snapshot/opt/data"
out="$(run run 41)"; rc=$?
[ "$rc" = 0 ] && [ -f "$top/root/opt/data" ] && new_has "nested-left=opt/data" && ok "nested conflict: a regular file in the way is left alone too" || bad "nested conflict with a file: rc=$rc $out"

# a failure while carrying, or in the renames after it, undoes everything: the machine is as it was
nested_fresh
cat > "$work/mv" <<'STUB'
#!/bin/sh
# fails when the destination is /opt/data (the carried subvolume), otherwise really moves
case "$2" in */opt/data) echo "mv: cannot move" >&2; exit 1 ;; esac
exec mv "$@"
STUB
chmod +x "$work/mv"; export NISSE_MV="$work/mv"
out="$(run run 41)"; rc=$?
[ "$rc" != 0 ] && untouched && [ -e "$top/root/opt/data/.nisse-subvol" ] && [ "$(cat "$top/root/opt/data/file")" = precious ] && ok "nested failure: a failed move undoes everything (.snapshots is back, the subvolume is where it was, no new root is left)" || bad "nested failure: rc=$rc out=$out top=$(ls "$top")"
! has_call 'nisse-boot clear' && ok "nested failure: GRUB stays armed" || bad "nested failure: disarmed GRUB"
nested_fresh
cat > "$work/mv" <<'STUB'
#!/bin/sh
# fails when the running root is renamed away
case "$2" in */root.failed-*) echo "mv: cannot rename" >&2; exit 1 ;; esac
exec mv "$@"
STUB
out="$(run run 41)"; rc=$?
[ "$rc" != 0 ] && untouched && [ -e "$top/root/opt/data/.nisse-subvol" ] && [ "$(cat "$top/root/opt/data/file")" = precious ] && ok "nested: a failed rename of the running root also brings the carried subvolume and .snapshots back" || bad "rename failure: rc=$rc out=$out top=$(ls "$top")"
unset NISSE_MV

# ---- an undo by hand (the panel's undo button, N-311): there is no failed update behind it, so no fingerprint, maybe no state at
# all. The first version of the record's write counted "no fingerprint" as a failed write (the end-to-end test of N-311 found it).
fresh
printf 'state=idle\nlast=verified\n' > "$top/root/var/lib/nisse/update/state"
rm -f "$top/root/var/lib/nisse/update/changed.txt" "$top/root/var/lib/nisse/update/health" "$top/root/var/lib/nisse/boot/armed"
out="$(run run 41 --reason "undone from the panel")"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$top/root/etc/marker")" = old ] && ok "undo by hand: with no fingerprint in the old state the rollback still goes through (exit $rc)" || bad "undo by hand, no fingerprint: rc=$rc $out"
new_has "last=rolled-back" && new_has "reason=undone from the panel" && ok "undo by hand: the record says last=rolled-back and why" || bad "undo by hand: state $(new_state)"
new_state | grep -q '^blocked-fingerprint=' && bad "undo by hand: a blocked-fingerprint was invented" || ok "undo by hand: no blocked-fingerprint (an undo by hand blocks no update)"
[ ! -e "$top/root/var/lib/nisse/update/failed-changed.txt" ] && [ ! -e "$top/root/var/lib/nisse/update/failed-health" ] && ok "undo by hand: no failed-update files are invented either" || bad "undo by hand: failed-* files exist"
fresh
rm -rf "$top/root/var/lib/nisse"
out="$(run run 41)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$top/root/etc/marker")" = old ] && new_has "last=rolled-back" && ok "undo by hand: a system that has never had an update state at all can be rolled back" || bad "undo by hand, no state at all: rc=$rc $out"

# ---- list (N-311): the snapshots nisse made, for the panel's undo list. Run as root through sudo by the daemon.
# A fake snapper prints what `snapper --csvout --separator ';' list --columns number,type,pre-number,date,userdata` prints.
list_fresh() {
    fresh
    export NISSE_SNAPPER="$work/snapper"
    export NISSE_SNAPPER_CONFDIR="$work/confdir"
    export NISSE_SNAPSHOTS_ROOT="$top/root/.snapshots"
    mkdir -p "$work/confdir"; : > "$work/confdir/root"
    # snapshot 43 has a kernel that /boot no longer has
    mkdir -p "$top/root/.snapshots/43/snapshot/usr/lib/modules/5.0.0-1.fc44.x86_64"
    for n in 44 46 47; do mkdir -p "$top/root/.snapshots/$n/snapshot/usr/lib/modules/$KVER"; done
    cat > "$work/snapper.csv" <<'CSV'
number;type;pre-number;date;userdata
0;single;;;nisse=safe-apply
41;pre;;2026-11-21 12:00:00;nisse=ai-batch, session=s-one
42;post;41;2026-11-21 12:01:30;nisse=ai-batch, session=s-one
43;pre;;2026-11-20 09:30:00;nisse=safe-apply
44;post;43;2026-11-20 09:45:10;nisse=safe-apply
45;single;;2026-11-19 08:00:00;
46;pre;;2026-11-18 07:00:00;nisse=package-transaction
47;post;46;2026-11-18 07:00:20;nisse=package-transaction
48;single;;2026-11-17 06:00:00;important=yes
CSV
    cat > "$work/snapper" <<'STUB'
#!/bin/sh
echo "snapper $*" >> "$STUB_DIR/calls"
[ -n "${SNAPPER_FAIL:-}" ] && { echo "snapper broke" >&2; exit 1; }
case "$*" in
    *--csvout*list*) cat "$STUB_DIR/snapper.csv" ;;
esac
STUB
    chmod +x "$work/snapper"
}
lines() { printf '%s\n' "$out" | grep -c .; }
list_fresh
out="$(run list)"; rc=$?
[ "$rc" = 0 ] && ok "list: exit 0" || bad "list: exit $rc: $out"
ask="$(grep 'snapper' "$work/calls" | head -1)"
case "$ask" in *"--no-dbus"*"-c root"*"--csvout"*"--separator ;"*"list --columns number,type,pre-number,date,userdata"*) ok "list: asks snapper (no dbus, the root config) for exactly those columns" ;; *) bad "list: snapper call: $ask" ;; esac
e41="$(date -d '2026-11-21 12:00:00' +%s)"
printf '%s\n' "$out" | grep -qx "41;pre;;$e41;yes;nisse=ai-batch, session=s-one" && ok "list: an AI turn's before snapshot: number, type, no pre, the time as epoch seconds, bootable, its userdata" || bad "list: 41: $(printf '%s\n' "$out" | grep '^41;')"
printf '%s\n' "$out" | grep -qx "42;post;41;$(date -d '2026-11-21 12:01:30' +%s);yes;nisse=ai-batch, session=s-one" && ok "list: the after snapshot names the before one it pairs with" || bad "list: 42: $(printf '%s\n' "$out" | grep '^42;')"
printf '%s\n' "$out" | grep -q '^46;pre;;.*;nisse=package-transaction$' && ok "list: package transactions (the dnf hook's pairs) are listed" || bad "list: no package transaction"
printf '%s\n' "$out" | grep -q '^43;pre;;.*;nisse=safe-apply$' && ok "list: safe-apply updates are listed" || bad "list: no safe-apply row"
printf '%s\n' "$out" | grep -q '^\(0\|45\|48\);' && bad "list: a snapshot nisse did not make is listed: $(printf '%s\n' "$out" | grep '^\(0\|45\|48\);')" || ok "list: the running system (0), a plain single snapshot and one made by hand are not listed"
[ "$(lines)" = 6 ] && ok "list: exactly the six nisse snapshots (41, 42, 43, 44, 46, 47)" || bad "list: $(lines) lines: $out"
printf '%s\n' "$out" | grep -q '^43;pre;;[0-9]*;no:' && ok "list: a snapshot whose kernel has left /boot is marked not bootable" || bad "list: 43 should be marked no: $(printf '%s\n' "$out" | grep '^43;')"
printf '%s\n' "$out" | grep '^43;' | grep -q 'kernel' && ok "list: and says why, in a word of its own" || bad "list: no reason for 43"
printf '%s\n' "$out" | grep -v '^43;' | grep -q ';no:' && bad "list: another snapshot is marked not bootable: $(printf '%s\n' "$out" | grep ';no:')" || ok "list: the others (whose kernel is in /boot) are bootable"
printf '%s\n' "$out" | awk -F';' 'NF != 6 { bad = 1 } END { exit bad }' && ok "list: every line has exactly six fields (number, type, pre, epoch, bootable, userdata)" || bad "list: a line without six fields: $(printf '%s\n' "$out" | awk -F';' 'NF != 6')"
if LC_ALL=C printf '%s' "$out" | grep -q -P '[^\x00-\x7F]'; then bad "list: non-ASCII in the output"; else ok "list: plain ASCII"; fi
list_fresh
export SNAPPER_FAIL=1
out="$(run list)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *snapper*) ok "list: a failing snapper is an error that says so (exit $rc), not an empty list" ;; *) bad "list: failure without a message: $out" ;; esac || bad "list: snapper failure gave exit 0"
unset SNAPPER_FAIL
list_fresh
echo "BOOT_IMAGE=x root=live:CDLABEL=x rd.live.image" > "$work/cmdline"
out="$(run list)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "list: live media has nothing to list (empty, exit 0)" || bad "list: live media: rc=$rc out=$out"
list_fresh
export NISSE_ROOT_FSTYPE=ext4
out="$(run list)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "list: a root that is not btrfs has nothing to list (empty, exit 0)" || bad "list: ext4: rc=$rc out=$out"
list_fresh
rm -f "$work/confdir/root"
out="$(run list)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "list: no snapper root config yet: empty, exit 0" || bad "list: no config: rc=$rc out=$out"
list_fresh
out="$(run list extra 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "list: takes no arguments" || bad "list with an argument: rc=$rc"
! grep -q 'mount\|btrfs' "$work/calls" && ok "list: needs no top-level mount and runs no btrfs command" || bad "list ran btrfs"

# ---- a reason is plain ASCII, one line, and cut
fresh
long="$(printf 'x%.0s' $(seq 1 400))"
run run 41 --reason "line one
line two $long" >/dev/null
r="$(new_state | grep '^reason=')"
[ "$(printf '%s\n' "$r" | wc -l)" = 1 ] && [ "${#r}" -le 210 ] && ok "a long multi-line reason is one line of at most 200 characters" || bad "reason length ${#r}"

# ---- usage
fresh
out="$(run bogus)"; rc=$?
[ "$rc" = 2 ] && ok "an unknown command prints usage and exits 2" || bad "usage rc=$rc"
out="$(run run 41 --frobnicate)"; rc=$?
[ "$rc" != 0 ] && untouched && ok "an unknown option is refused" || bad "unknown option accepted"

rm -rf "$work"
echo
if [ "$failures" = 0 ]; then echo "nisse-rollback: all checks passed"; else echo "nisse-rollback: $failures FAILED"; exit 1; fi
