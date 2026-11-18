#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-308: safe-apply on an installed nisse disk with the REAL dnf, snapper and GRUB, updating from local file repositories
# (a probe package in versions 1.0, 2.0, 2.5 and a 3.0 whose %pre fails; no network is touched by the updates themselves).
# About 15 minutes. Runs on the Windows host (QEMU with WHPX), from Git Bash. Needs the installed disk of the N-303 harness and
# the RPMs built in the build VM (nisse-update, nisse-boot, nisse-snapshots):
#   bash tests/e2e/test_install_to_disk.sh                   (once per ISO: makes out/install/run/target.qcow2)
#   in the build VM: tools/rpm/build-rpm.sh nisse-update ; nisse-boot ; nisse-snapshots
#   bash tests/e2e/test_apply_updates.sh
# The installed disk is never written (a disposable overlay, tools/vm/vmserver.py). A guest reboot hangs this QEMU setup, so the
# "reboot" after an update is a power-cycle; nisse-apply-updates reboot itself is covered by the shell test.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

port=24691
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
[ -f "$disk" ] && [ -f "$vars" ] || { echo "FAIL: no installed disk (run tests/e2e/test_install_to_disk.sh first)"; exit 2; }
work="$(cygpath -m "$(mktemp -d)")"
pulled=out/install/apply-e2e
mkdir -p "$pulled"
V() { python tools/vm/vmserver.py call "$port" "$@"; }
g() { V run "$1" "${2:-120}" | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
login() { bash tools/vm/vmlogin.sh "$port" >/dev/null; }
boot() { V powercycle >/dev/null; V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the power-cycle"; V shot "$work/nologin.png" >/dev/null; exit 1; }; login; }
probe() { g 'echo "RES: $(cat /usr/share/nisse-e2e/version 2>/dev/null)"' 30; }
which_root() { g 'echo "RES: $(findmnt -no OPTIONS / | grep -o "subvol=[^,]*")"' 30; }
state_of() { g "echo \"RES: \$(sed -n 's/^$1=//p' /var/lib/nisse/update/state 2>/dev/null)\"" 30; }
boot_status() { g "echo \"RES: \$(S nisse-boot status | grep '^$1=' | cut -d= -f2)\"" 30; }
snap_count() { g 'echo "RES: $(S snapper --no-dbus -c root --csvout list --columns number | tail -n +2 | grep -vc "^0$")"' 60; }
cleanup() { V quit >/dev/null 2>&1; sleep 2; rm -rf "$work"; }
trap cleanup EXIT

# ---- the packages and the probe repositories (built in the build VM)
for p in nisse-update nisse-boot nisse-snapshots; do
    rpmname="$(bash tools/build/vm.sh ssh "ls -v ~/nisse/out/rpmbuild/RPMS/noarch/$p-[0-9]*.rpm | tail -1" < /dev/null 2>/dev/null | tr -d '\r' | tail -1)"
    [ -n "$rpmname" ] || { echo "FAIL: no $p RPM in the build VM"; exit 2; }
    rm -f "$pulled"/"$p"-[0-9]*.rpm
    bash tools/build/vm.sh pull "${rpmname#/home/builder/nisse/}" "$pulled/" >/dev/null 2>&1
    ls "$pulled"/"$p"-[0-9]*.rpm >/dev/null 2>&1 || { echo "FAIL: could not pull $p"; exit 2; }
done
bash tools/build/vm.sh ssh 'cd ~/nisse && bash tests/e2e/data/make_probe_repos.sh' < /dev/null >/dev/null 2>&1
rm -f "$pulled/probe-repos.tgz"
bash tools/build/vm.sh pull out/e2e/probe-repos.tgz "$pulled/" >/dev/null 2>&1
[ -s "$pulled/probe-repos.tgz" ] || { echo "FAIL: could not build the probe repositories"; exit 2; }

# ---- the machine
python tools/vm/vmserver.py serve --disk "$disk" --vars "$vars" --work "$work/vm" --port "$port" > "$work/server.log" 2>&1 &
sleep 8
V expect "login:" 420 >/dev/null || { echo "FAIL: the installed disk did not reach a login"; exit 1; }
login
ok "the installed disk booted to a login (on a throwaway overlay)"
for p in nisse-update nisse-boot nisse-snapshots; do
    V put "/tmp/$p.rpm" "$(cygpath -m "$(ls "$pulled"/"$p"-[0-9]*.rpm | head -1)")" >/dev/null
done
V put /tmp/probe-repos.tgz "$(cygpath -m "$pulled/probe-repos.tgz")" >/dev/null
out="$(V run 'S dnf install -y /tmp/nisse-snapshots.rpm /tmp/nisse-boot.rpm /tmp/nisse-update.rpm 2>&1 | tail -2; echo "RES: $(rpm -q nisse-update nisse-boot nisse-snapshots | tr "\n" " ")"' 900)"
case "$out" in *"RES: nisse-update-"*) ok "nisse-update, nisse-boot and nisse-snapshots install on the installed system" ;; *) bad "install failed: $(echo "$out" | tail -4)"; exit 1 ;; esac
V run 'S systemctl start nisse-snapshot-setup.service; S systemctl start nisse-boot-setup.service; S mkdir -p /var/lib/e2e; S tar -C /var/lib/e2e -xzf /tmp/probe-repos.tgz; S dnf install -y /var/lib/e2e/probe-1.0.rpm >/dev/null 2>&1' 600 >/dev/null
[ "$(probe)" = 1.0 ] && ok "probe package 1.0 installed; the update will move it to 2.0" || { bad "probe 1.0 did not install"; exit 1; }
[ "$(g 'echo "RES: $(test -f /etc/snapper/configs/root && echo yes)"' 30)" = yes ] && ok "the snapper root config exists" || bad "no snapper root config"
repo() { echo "--dnf-arg --repofrompath=e2e,file:///var/lib/e2e/repo-$1 --dnf-arg --repo=e2e --dnf-arg --no-gpgchecks"; }
run_update() { V run "S nisse-apply-updates run $(repo "$1") ${2:-}; echo \"RES: rc=\$?\"" 900 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }

# ---- 1. nothing to update: no arm, the unused snapshot is removed again
n0="$(snap_count)"
rc="$(run_update none)"
[ "$rc" = "rc=0" ] && [ "$(state_of state)" = idle ] && [ "$(state_of last)" = nothing-to-do ] && ok "nothing to update: exit 0, state idle (last=nothing-to-do)" || bad "nothing to update: $rc state=$(state_of state) last=$(state_of last)"
[ "$(boot_status armed)" = no ] && [ "$(snap_count)" = "$n0" ] && ok "nothing to update: nothing armed and the unused snapshot is gone ($n0 snapshots before and after)" || bad "nothing to update: armed=$(boot_status armed) snapshots $n0 -> $(snap_count)"

# ---- 2. a real update: pending-verify, armed on the before snapshot, no reboot
V run 'S touch /run/e2e-still-up' 30 >/dev/null
rc="$(run_update good)"
[ "$rc" = "rc=0" ] && ok "update from the local repository: exit 0" || bad "update: $rc"
[ "$(probe)" = 2.0 ] && ok "the probe package really moved from 1.0 to 2.0" || bad "probe is $(probe)"
snap="$(state_of snapshot)"; post="$(state_of post-snapshot)"
[ "$(state_of state)" = pending-verify ] && [ -n "$snap" ] && [ -n "$post" ] && ok "state is pending-verify with before snapshot $snap and after snapshot $post" || bad "state=$(state_of state) snapshot=$snap post=$post"
[ "$(snap_count)" = "$((n0 + 2))" ] && ok "exactly two snapshots were added (safe-apply's pair; the dnf hook stood aside)" || bad "snapshots $n0 -> $(snap_count), expected +2"
[ "$(g "echo \"RES: \$(S snapper --no-dbus -c root --csvout list --columns number,userdata | grep -c 'nisse=safe-apply')\"" 60)" = 2 ] && ok "both are labelled nisse=safe-apply" || bad "snapshot labels"
[ "$(boot_status armed)" = yes ] && [ "$(boot_status snapshot)" = "$snap" ] && [ "$(boot_status tries-left)" = 3 ] && ok "GRUB is armed on the BEFORE snapshot with 3 tries" || bad "boot status: armed=$(boot_status armed) snapshot=$(boot_status snapshot) tries=$(boot_status tries-left)"
[ "$(g 'echo "RES: $(test -e /run/e2e-still-up && echo up)"' 30)" = up ] && ok "it did not reboot the machine" || bad "the machine rebooted"
[ "$(g 'echo "RES: $(S cat /var/lib/nisse/update/changed.txt | grep -c nisse-e2e-probe-2.0)"' 30)" = 1 ] && ok "changed.txt lists the updated package" || bad "changed.txt"
rc="$(run_update good)"
[ "$rc" != "rc=0" ] && [ "$(state_of state)" = pending-verify ] && ok "a second run while pending verification is refused and changes nothing" || bad "second run: $rc"

# ---- 3. the machine comes back from the reboot and the health check (stood in for by 'verified') finishes the update
boot
[ "$(probe)" = 2.0 ] && ok "after the reboot the update is still there (probe 2.0)" || bad "after reboot probe is $(probe)"
[ "$(boot_status armed)" = yes ] && [ "$(boot_status tries-left)" = 2 ] && ok "the armed boot counted 3 -> 2" || bad "after the boot: tries-left=$(boot_status tries-left)"
[ "$(state_of state)" = pending-verify ] && ok "still pending-verify until something verifies it" || bad "state after reboot: $(state_of state)"
V run 'S nisse-apply-updates verified' 60 >/dev/null
[ "$(state_of state)" = idle ] && [ "$(state_of last)" = verified ] && [ "$(boot_status armed)" = no ] && ok "verified: state idle (last=verified), GRUB disarmed" || bad "verified: state=$(state_of state) armed=$(boot_status armed)"
[ "$(g 'echo "RES: $(S grub2-editenv list | grep -c "^boot_counter=")"' 30)" = 0 ] && ok "no boot counter is left in the GRUB environment" || bad "boot_counter still set"

# ---- 4. an update that never gets verified falls back to the before snapshot (the whole net, end to end)
rc="$(V run "S nisse-apply-updates run $(repo good2) --tries 2; echo \"RES: rc=\$?\"" 900 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1)"
snap2="$(state_of snapshot)"
[ "$rc" = "rc=0" ] && [ "$(probe)" = 2.5 ] && [ "$(state_of state)" = pending-verify ] && ok "second update: probe 2.5, pending-verify, before snapshot $snap2, 2 tries" || bad "second update: $rc probe=$(probe) state=$(state_of state)"
boot; r1="$(which_root)"; probe1="$(probe)"
boot; r2="$(which_root)"
boot; r3="$(which_root)"; probe3="$(probe)"
[ "$r1" = "subvol=/root" ] && [ "$probe1" = 2.5 ] && [ "$r2" = "subvol=/root" ] && ok "never verified: boots 1 and 2 start the updated system (probe 2.5)" || bad "boots 1-2: $r1 $r2 (probe $probe1)"
[ "$r3" = "subvol=/root/.snapshots/$snap2/snapshot" ] && [ "$probe3" = 2.0 ] && ok "boot 3: GRUB fell back by itself to the BEFORE snapshot $snap2 (probe 2.0 again)" || bad "boot 3: $r3 probe=$probe3"
V run 'S nisse-boot clear' 60 >/dev/null
boot
[ "$(which_root)" = "subvol=/root" ] && ok "after the fallback was cleared the machine boots the normal system again" || bad "normal boot after clear: $(which_root)"

# ---- 5. an update that cannot be applied: failed, nothing armed
V run 'S rm -f /var/lib/nisse/update/state; S nisse-boot clear' 60 >/dev/null
before="$(probe)"
rc="$(run_update bad)"
[ "$rc" != "rc=0" ] && ok "an update whose package scriptlet fails: exit non-zero ($rc)" || bad "the failing update exited 0"
[ "$(state_of state)" = failed ] && ok "state is failed" || bad "state after the failure: $(state_of state)"
msg="$(state_of message)"; case "$msg" in *"dnf upgrade failed"*) ok "the state says why: $msg" ;; *) bad "failure message: '$msg'" ;; esac
[ "$(boot_status armed)" = no ] && ok "nothing was armed" || bad "armed after a failure"
[ "$(probe)" = "$before" ] && ok "the probe package is untouched ($before)" || bad "probe changed to $(probe)"
[ -n "$(state_of snapshot)" ] && ok "the state keeps the before snapshot number ($(state_of snapshot))" || bad "no snapshot number in the failed state"

echo
[ "$failures" = 0 ] && echo "PASS: safe-apply on the real dnf, snapper and GRUB" || { echo "$failures failed"; exit 1; }
