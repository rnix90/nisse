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
