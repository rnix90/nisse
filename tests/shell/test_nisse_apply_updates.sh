#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-308: tests nisse-apply-updates (run, status, verified, reboot) against a fake snapper, dnf, rpm, nisse-boot, nisse-hwroute
# and systemctl. No btrfs, no root, no network. The real dnf, snapper and GRUB are tests/e2e/test_apply_updates.sh.
set -u
cd "$(dirname "$0")/../.."
tool="$PWD/packaging/rpm/nisse-update/nisse-apply-updates"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

# A fresh sandbox. Every fake appends one line to $work/calls, so the ORDER of the steps can be checked.
fresh() {
    work="$(mktemp -d)"
    mkdir -p "$work/state" "$work/confdir"
    touch "$work/confdir/root"
    export NISSE_STATE_DIR="$work/state"
    export NISSE_SNAPPER="$work/snapper"
    export NISSE_DNF="$work/dnf"
    export NISSE_RPM="$work/rpm"
    export NISSE_BOOT_TOOL="$work/nisse-boot"
    export NISSE_HWROUTE="$work/hwroute"
    export NISSE_SYSTEMCTL="$work/systemctl"
    export NISSE_SNAPPER_CONFDIR="$work/confdir"
    export NISSE_ROOT_FSTYPE=btrfs
    export NISSE_FREE_PERCENT=60
    export NISSE_CMDLINE_FILE="$work/cmdline"
    export NISSE_NOW=1700000000
    export STUB_DIR="$work"
    export TZ=UTC
    echo "BOOT_IMAGE=x root=UUID=1 ro" > "$work/cmdline"
    echo 41 > "$work/next"
    printf 'bash-5.2-1\nkernel-core-6.19.10-300\nfirefox-130-1\n' > "$work/rpmdb"
    : > "$work/calls"
    unset DNF_FAIL DNF_NOCHANGE SNAPPER_FAIL BOOT_FAIL HW_FAIL
    cat > "$work/snapper" <<'STUB'
#!/bin/sh
echo "snapper $*" >> "$STUB_DIR/calls"
while [ "${1#-}" != "$1" ]; do
    case "$1" in -c | --separator) shift ;; esac
    shift
done
verb="$1"; shift
case "$verb" in
    create)
        [ -n "${SNAPPER_FAIL:-}" ] && exit 1
        n=$(cat "$STUB_DIR/next"); echo $((n + 1)) > "$STUB_DIR/next"; echo "$n" ;;
    delete | modify) ;;
esac
exit 0
STUB
    cat > "$work/dnf" <<'STUB'
#!/bin/sh
echo "dnf $*" >> "$STUB_DIR/calls"
echo "skip=${NISSE_SNAPSHOT_SKIP:-}" >> "$STUB_DIR/dnfenv"
[ -n "${DNF_FAIL:-}" ] && { echo "Error: a package failed" >&2; exit 1; }
if [ -z "${DNF_NOCHANGE:-}" ]; then
    sed -i 's/^firefox-130-1$/firefox-131-1/; s/^kernel-core-6.19.10-300$/kernel-core-7.3.4-200\nkernel-core-6.19.10-300/' "$STUB_DIR/rpmdb"
fi
exit 0
STUB
    cat > "$work/rpm" <<'STUB'
#!/bin/sh
cat "$STUB_DIR/rpmdb"
STUB
    cat > "$work/nisse-boot" <<'STUB'
#!/bin/sh
echo "nisse-boot $*" >> "$STUB_DIR/calls"
[ "$1" = arm ] && [ -n "${BOOT_FAIL:-}" ] && { echo "nisse-boot: cannot arm" >&2; exit 1; }
exit 0
STUB
    cat > "$work/hwroute" <<'STUB'
#!/bin/sh
echo "hwroute $*" >> "$STUB_DIR/calls"
[ -n "${HW_FAIL:-}" ] && exit 1
exit 0
STUB
    cat > "$work/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >> "$STUB_DIR/calls"
exit 0
STUB
    chmod +x "$work/snapper" "$work/dnf" "$work/rpm" "$work/nisse-boot" "$work/hwroute" "$work/systemctl"
}
has_call() { grep -q -- "$1" "$work/calls"; }
call_line() { grep -n -- "$1" "$work/calls" | head -1 | cut -d: -f1; }
state_has() { grep -qx -- "$1" "$work/state/state"; }
run() { sh "$tool" "$@" 2>&1; }

# ---- run: the whole flow
fresh
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ok "run: exit 0" || bad "run: exit $rc: $out"
has_call 'snapper .*create -t pre -p -c number' && ok "run: takes the pre snapshot (type pre, number cleanup)" || bad "run: no pre snapshot: $(cat "$work/calls")"
has_call 'snapper .*create .*nisse=safe-apply' && ok "run: the snapshot is labelled nisse=safe-apply" || bad "run: no safe-apply label"
has_call 'dnf upgrade -y' && ok "run: dnf upgrade -y" || bad "run: no dnf upgrade: $(cat "$work/calls")"
grep -qx 'skip=1' "$work/dnfenv" && ok "run: dnf runs with NISSE_SNAPSHOT_SKIP=1 (the dnf hook stands aside, safe-apply has its own pair)" || bad "run: dnf did not get NISSE_SNAPSHOT_SKIP"
has_call 'hwroute' && ok "run: the hardware routing step runs" || bad "run: no hwroute"
has_call 'snapper .*create -t post --pre-number 41' && ok "run: takes the post snapshot paired with the pre one" || bad "run: no paired post snapshot"
has_call 'nisse-boot arm --tries 3 41' && ok "run: arms the boot fallback on the PRE snapshot with 3 tries" || bad "run: arm call: $(grep nisse-boot "$work/calls")"
a="$(call_line 'create -t pre')"; h="$(call_line hwroute)"; d="$(call_line 'dnf upgrade')"; p="$(call_line 'create -t post')"; b="$(call_line 'nisse-boot arm')"
[ -n "$a" ] && [ "$a" -lt "$h" ] && [ "$h" -lt "$d" ] && [ "$d" -lt "$p" ] && [ "$p" -lt "$b" ] && ok "run: the order is snapshot, hardware, dnf, post snapshot, arm" || bad "run: order $a $h $d $p $b"
has_call 'systemctl reboot' && bad "run: rebooted without being asked" || ok "run: does not reboot unless told to"
state_has "state=pending-verify" && state_has "snapshot=41" && state_has "post-snapshot=42" && ok "run: state is pending-verify with both snapshot numbers" || bad "run: state: $(cat "$work/state/state")"
state_has "applied-at=1700000000" && ok "run: state records when it was applied" || bad "run: no applied-at"
state_has "changed=2" && ok "run: counts the changed packages (firefox 131 and the new kernel-core)" || bad "run: changed: $(grep changed= "$work/state/state")"
state_has "kernel-changed=yes" && ok "run: notes that the kernel changed" || bad "run: kernel-changed"
[ -s "$work/state/changed.txt" ] && grep -q 'firefox-131-1' "$work/state/changed.txt" && ok "run: lists the changed packages in changed.txt" || bad "run: changed.txt"
case "$out" in *"reboot"*) ok "run: says a reboot is needed to finish and verify" ;; *) bad "run: no word about the reboot: $out" ;; esac

# ---- run --reboot
fresh
out="$(run run --reboot)"; rc=$?
[ "$rc" = 0 ] && has_call 'systemctl reboot' && ok "run --reboot: reboots after arming" || bad "run --reboot: rc=$rc calls=$(cat "$work/calls")"
r="$(call_line 'systemctl reboot')"; b="$(call_line 'nisse-boot arm')"
[ "$b" -lt "$r" ] && ok "run --reboot: arms first, then reboots" || bad "run --reboot: order"

# ---- options
fresh
run run --tries 5 >/dev/null
has_call 'nisse-boot arm --tries 5 41' && ok "run --tries 5 reaches nisse-boot" || bad "run --tries: $(grep nisse-boot "$work/calls")"
fresh
run run --dnf-arg --repofrompath=e2e,file:///x --dnf-arg --no-gpgchecks >/dev/null
has_call 'dnf upgrade -y .*--repofrompath=e2e,file:///x --no-gpgchecks' && ok "run --dnf-arg: extra dnf arguments are passed through in order" || bad "run --dnf-arg: $(grep '^dnf' "$work/calls")"
fresh
out="$(run run --tries 0)"; rc=$?
[ "$rc" != 0 ] && ! has_call 'snapper' && ok "run: a bad --tries is refused before anything is touched" || bad "run --tries 0 accepted"
fresh
out="$(run run --frobnicate)"; rc=$?
[ "$rc" != 0 ] && ! has_call 'snapper' && ok "run: an unknown option is refused" || bad "unknown option accepted"

# ---- failures
fresh
export DNF_FAIL=1; out="$(run run)"; rc=$?
[ "$rc" != 0 ] && ok "dnf failure: exit non-zero" || bad "dnf failure: exit 0"
! has_call 'nisse-boot arm' && ok "dnf failure: nothing is armed" || bad "dnf failure: armed anyway"
state_has "state=failed" && state_has "snapshot=41" && ok "dnf failure: state is failed and keeps the snapshot number" || bad "dnf failure: state $(cat "$work/state/state")"
grep -q '^message=' "$work/state/state" && ok "dnf failure: state carries a one-line reason" || bad "dnf failure: no message"
has_call 'systemctl reboot' && bad "dnf failure: rebooted" || ok "dnf failure: no reboot even with --reboot"
fresh
export DNF_FAIL=1; out="$(run run --reboot)"
has_call 'systemctl reboot' && bad "dnf failure with --reboot: rebooted" || ok "dnf failure with --reboot: still no reboot"
fresh
export SNAPPER_FAIL=1; out="$(run run)"; rc=$?
[ "$rc" != 0 ] && ! has_call 'dnf' && ok "no snapshot, no update: a failed pre snapshot stops before dnf" || bad "update went ahead without a snapshot (rc=$rc)"
fresh
export HW_FAIL=1; out="$(run run)"; rc=$?
[ "$rc" != 0 ] && ! has_call 'nisse-boot arm' && state_has "state=failed" && ok "hardware step failure: failed, nothing armed" || bad "hwroute failure: rc=$rc state=$(cat "$work/state/state")"
fresh
rm -f "$work/hwroute"
out="$(run run)"; rc=$?
[ "$rc" = 0 ] && state_has "state=pending-verify" && ok "no nisse-hwroute on this machine: skipped, the update still goes ahead" || bad "missing hwroute: rc=$rc"
fresh
export BOOT_FAIL=1; out="$(run run --reboot)"; rc=$?
[ "$rc" != 0 ] && state_has "state=failed" && ! has_call 'systemctl reboot' && ok "arm failure after the update: failed, and no reboot (an unarmed reboot would have no way back)" || bad "arm failure: rc=$rc"
grep -q "^message=.*arm" "$work/state/state" && ok "arm failure: the state says the update was applied but could not be armed" || bad "arm failure message: $(grep message= "$work/state/state")"

# ---- refusals before anything is touched
fresh
run run >/dev/null; : > "$work/calls"
out="$(run run)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$work/calls" ] && ok "run: refuses while an update is pending verification" || bad "run: second run went ahead: $(cat "$work/calls")"
case "$out" in *pending*) ok "run: says why (pending)" ;; *) bad "run: no reason: $out" ;; esac
fresh
NISSE_ROOT_FSTYPE=ext4 out="$(run run)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$work/calls" ] && ok "run: refuses on a root that is not btrfs" || bad "run on ext4: rc=$rc"
fresh
rm -f "$work/confdir/root"
out="$(run run)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$work/calls" ] && ok "run: refuses without the snapper root config" || bad "run without snapper config: rc=$rc"
fresh
echo "BOOT_IMAGE=x root=live:CDLABEL=nisse rd.live.image ro" > "$work/cmdline"
out="$(run run)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$work/calls" ] && ok "run: refuses on live media" || bad "run on live media: rc=$rc"
fresh
NISSE_FREE_PERCENT=5 out="$(run run)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$work/calls" ] && ok "run: refuses below 10% free space (the snapshot hook would skip, and safe-apply has no way back without one)" || bad "run on a nearly full disk: rc=$rc"

# ---- nothing to update
fresh
export DNF_NOCHANGE=1; out="$(run run)"; rc=$?
[ "$rc" = 0 ] && ok "nothing to update: exit 0" || bad "nothing to update: rc=$rc"
! has_call 'nisse-boot arm' && ! has_call 'create -t post' && ok "nothing to update: no post snapshot, nothing armed" || bad "nothing to update: armed or took a post snapshot"
has_call 'snapper .*delete 41' && ok "nothing to update: the unused pre snapshot is removed" || bad "nothing to update: pre snapshot left behind"
state_has "state=idle" && state_has "last=nothing-to-do" && ok "nothing to update: state is idle, last=nothing-to-do" || bad "nothing to update: state $(cat "$work/state/state")"
fresh
export DNF_NOCHANGE=1; out="$(run run --reboot)"
has_call 'systemctl reboot' && bad "nothing to update with --reboot: rebooted" || ok "nothing to update: no reboot, even with --reboot"

# ---- status
fresh
out="$(run status)"
case "$out" in *"state=idle"*) ok "status: idle when nothing has run" ;; *) bad "status idle: $out" ;; esac
run run >/dev/null
out="$(run status)"
case "$out" in *"state=pending-verify"*"snapshot=41"*) ok "status: pending-verify with the snapshot" ;; *) bad "status pending: $out" ;; esac

# ---- verified (called by the health check, N-309)
fresh
run run >/dev/null; : > "$work/calls"
out="$(run verified)"; rc=$?
[ "$rc" = 0 ] && has_call 'nisse-boot clear' && ok "verified: clears the boot fallback" || bad "verified: rc=$rc calls=$(cat "$work/calls")"
state_has "state=idle" && state_has "last=verified" && ok "verified: state is idle, last=verified" || bad "verified: state $(cat "$work/state/state")"
out="$(run verified)"; rc=$?
[ "$rc" = 0 ] && ok "verified: nothing pending is fine" || bad "verified twice: rc=$rc"
fresh
: > "$work/calls"
run verified >/dev/null
! has_call 'nisse-boot clear' && ok "verified: with nothing pending it does not touch GRUB" || bad "verified with nothing pending cleared GRUB"

# ---- reboot
fresh
run run >/dev/null; : > "$work/calls"
out="$(run reboot)"; rc=$?
[ "$rc" = 0 ] && has_call 'systemctl reboot' && ok "reboot: reboots when an update is pending verification" || bad "reboot: rc=$rc"
fresh
out="$(run reboot)"; rc=$?
[ "$rc" != 0 ] && ! has_call 'systemctl reboot' && ok "reboot: refuses when nothing is pending" || bad "reboot with nothing pending: rc=$rc"

# ---- usage
out="$(run)"; rc=$?
[ "$rc" != 0 ] && ok "no command prints usage and fails" || bad "no command accepted"
out="$(run frobnicate)"; rc=$?
[ "$rc" != 0 ] && ok "an unknown command is an error" || bad "unknown command accepted"

echo
[ "$failures" = 0 ] && echo "PASS: nisse-apply-updates" || { echo "$failures failed"; exit 1; }
