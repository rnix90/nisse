#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-309: the health check on an installed nisse disk with the REAL systemd, NetworkManager, login manager and GRUB: each real
# check passes on a healthy system and fails when its thing is broken, a healthy update verifies ITSELF after the reboot (the
# unit runs after the graphical target and calls nisse-apply-updates verified), and an update with a broken network stays
# pending with the failing checks and their reasons recorded. About 20 minutes. Runs on the Windows host (QEMU with WHPX),
# from Git Bash. Needs the installed disk of the N-303 harness and the RPMs built in the build VM (nisse-update, nisse-boot,
# nisse-snapshots); see tests/e2e/test_apply_updates.sh for the setup. A guest reboot hangs this QEMU setup, so every
# "reboot" is a power-cycle.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

port=24694
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
[ -f "$disk" ] && [ -f "$vars" ] || { echo "FAIL: no installed disk (run tests/e2e/test_install_to_disk.sh first)"; exit 2; }
work="$(cygpath -m "$(mktemp -d)")"
pulled=out/install/health-e2e
mkdir -p "$pulled"
V() { python tools/vm/vmserver.py call "$port" "$@"; }
g() { V run "$1" "${2:-120}" | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
login() { bash tools/vm/vmlogin.sh "$port" >/dev/null; }
boot() { V run 'S sync' 60 >/dev/null; V powercycle >/dev/null; V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the power-cycle"; V shot "$work/nologin.png" >/dev/null; exit 1; }; login; }
hval() { g "echo \"RES: \$(sed -n 's/^$1=//p' /var/lib/nisse/update/health 2>/dev/null | head -1)\"" 30; }
state_of() { g "echo \"RES: \$(sed -n 's/^$1=//p' /var/lib/nisse/update/state 2>/dev/null)\"" 30; }
boot_status() { g "echo \"RES: \$(S nisse-boot status | grep '^$1=' | cut -d= -f2)\"" 30; }
# wait up to $2 seconds for the health file to say $1
wait_result() {
    local want="$1" t=0
    while [ "$t" -lt "$2" ]; do
        [ "$(hval result)" = "$want" ] && return 0
        sleep 10; t=$((t + 10))
    done
    return 1
}
# the runner writes the result first and then calls verified: wait a moment for the state to follow
wait_state() {
    local want="$1" t=0
    while [ "$t" -lt "$2" ]; do
        [ "$(state_of state)" = "$want" ] && return 0
        sleep 3; t=$((t + 3))
    done
    return 1
}
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
out="$(V run 'S dnf install -y /tmp/nisse-snapshots.rpm /tmp/nisse-boot.rpm /tmp/nisse-update.rpm 2>&1 | tail -2; echo "RES: $(rpm -q nisse-update nisse-boot nisse-snapshots | tr "\n" " ")"' 1800)"
case "$out" in *"RES: nisse-update-"*) ok "nisse-update, nisse-boot and nisse-snapshots install on the installed system" ;; *) bad "install failed: $(echo "$out" | tail -4)"; exit 1 ;; esac
V run 'S systemctl start nisse-snapshot-setup.service; S systemctl start nisse-boot-setup.service; S mkdir -p /var/lib/e2e; S tar -C /var/lib/e2e -xzf /tmp/probe-repos.tgz; S dnf install -y /var/lib/e2e/probe-1.0.rpm >/dev/null 2>&1' 600 >/dev/null
[ "$(g 'echo "RES: $(systemctl is-enabled nisse-health-check.service 2>&1)"' 30)" = enabled ] && ok "the package's preset enabled nisse-health-check.service" || bad "the health check unit is not enabled"
repo() { echo "--dnf-arg --repofrompath=e2e,file:///var/lib/e2e/repo-$1 --dnf-arg --repo=e2e --dnf-arg --no-gpgchecks"; }

# ---- 1. every REAL check on the healthy machine
for c in 10-boot 20-network 30-services 40-display; do
    r="$(g "echo \"RES: \$(sh /usr/lib/nisse/health.d/$c >/tmp/chk.out 2>&1; echo rc=\$? \$(head -1 /tmp/chk.out))\"" 60)"
    case "$r" in "rc=0"*) ok "real check $c passes on the healthy system" ;; *) bad "real check $c: $r" ;; esac
done
V run 'S nisse-health-check run --force --deadline 60; echo "RES: rc=$?"' 120 | grep -q "RES: rc=0" && [ "$(hval result)" = healthy ] && ok "the runner agrees (--force): result=healthy" || bad "runner on a healthy system: result=$(hval result)"
[ "$(hval checks)" = "10-boot 20-network 30-services 40-display" ] && ok "it ran all four checks, in order" || bad "checks ran: $(hval checks)"

# ---- 2. the display check on the real login manager: stop it and the check fails, start it and it passes
V run 'S systemctl stop display-manager.service' 60 >/dev/null
r="$(g 'echo "RES: $(sh /usr/lib/nisse/health.d/40-display >/tmp/chk.out 2>&1; echo rc=$? $(head -1 /tmp/chk.out))"' 60)"
case "$r" in "rc=1 "*"login manager"*) ok "real display check fails with the login manager stopped ($r)" ;; *) bad "display check with the login manager stopped: $r" ;; esac
V run 'S systemctl start display-manager.service' 60 >/dev/null
t=0; r=""; while [ "$t" -lt 90 ]; do r="$(g 'echo "RES: $(sh /usr/lib/nisse/health.d/40-display >/dev/null 2>&1; echo rc=$?)"' 60)"; [ "$r" = "rc=0" ] && break; sleep 5; t=$((t + 5)); done
[ "$r" = "rc=0" ] && ok "...and passes again once the login manager is back (greeter session on the seat)" || bad "display check after restarting the login manager: $r"
[ "$(g 'echo "RES: $(S systemctl stop polkit.service; sh /usr/lib/nisse/health.d/30-services >/tmp/chk.out 2>&1; echo rc=$? $(head -1 /tmp/chk.out))"' 60)" = "rc=1 not active: polkit.service" ] && ok "real services check names a stopped polkit" || bad "services check with polkit stopped: $(g 'echo "RES: $(head -1 /tmp/chk.out)"' 30)"
V run 'S systemctl start polkit.service' 60 >/dev/null

# ---- 3. a healthy update verifies itself after the reboot
rc="$(V run "S nisse-apply-updates run $(repo good); echo \"RES: rc=\$?\"" 900 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1)"
[ "$rc" = "rc=0" ] && [ "$(state_of state)" = pending-verify ] && [ "$(boot_status armed)" = yes ] && ok "an update is applied: pending-verify, GRUB armed" || bad "update: $rc state=$(state_of state)"
V run 'S rm -f /var/lib/nisse/update/health' 30 >/dev/null
boot
echo "     waiting for the health check to verify the update by itself (nobody calls verified)"
wait_result healthy 300 && ok "after the reboot the health check ran by itself and the result is healthy" || bad "no healthy result after the reboot: result=$(hval result) failed=$(hval failed)"
wait_state idle 60
[ "$(state_of state)" = idle ] && [ "$(state_of last)" = verified ] && ok "the update was verified: state idle, last=verified" || bad "state after the check: $(state_of state) last=$(state_of last)"
[ "$(boot_status armed)" = no ] && [ "$(g 'echo "RES: $(S grub2-editenv list | grep -c "^boot_counter=")"' 30)" = 0 ] && ok "and the boot fallback was disarmed (no boot counter left)" || bad "still armed after verification"
[ "$(g 'echo "RES: $(journalctl -b -u nisse-health-check.service --no-pager 2>/dev/null | grep -c "healthy:")"' 30)" -ge 1 ] 2>/dev/null && ok "the journal of the unit shows the healthy result" || bad "no healthy line in the unit's journal"
order="$(g 'echo "RES: $(journalctl -b --no-pager -o short-monotonic 2>/dev/null | grep -E "Reached target graphical.target|nisse-health-check: healthy" | sed "s/^\[ *\([0-9.]*\)\].*\(Reached\|nisse-health\).*/\1 \2/" | tr "\n" ";")"' 60)"
echo "     (journal: $order)"

# ---- 4. a boot with nothing pending: the unit starts, says so, and changes nothing
at="$(hval checked-at)"
boot
sleep 20
[ "$(hval checked-at)" = "$at" ] && ok "a boot with nothing pending does not touch the health result" || bad "the health result changed on an idle boot"
[ "$(g 'echo "RES: $(journalctl -b -u nisse-health-check.service --no-pager 2>/dev/null | grep -c "nothing to check")"' 30)" -ge 1 ] 2>/dev/null && ok "the unit ran and said there was nothing to check" || bad "the unit did not log 'nothing to check'"

# ---- 5. an update whose boot has a broken network: it must NOT be verified
V run 'S mkdir -p /etc/systemd/system/nisse-health-check.service.d; S sh -c "printf \"[Service]\nExecStart=\nExecStart=/usr/bin/nisse-health-check run --deadline 40\n\" > /etc/systemd/system/nisse-health-check.service.d/e2e.conf"; S systemctl daemon-reload' 60 >/dev/null
rc="$(V run "S nisse-apply-updates run $(repo good2); echo \"RES: rc=\$?\"" 900 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1)"
[ "$rc" = "rc=0" ] && [ "$(state_of state)" = pending-verify ] && ok "a second update is applied and pending" || bad "second update: $rc state=$(state_of state)"
V run 'S rm -f /var/lib/nisse/update/health; S systemctl mask NetworkManager.service' 60 >/dev/null
[ "$(g 'echo "RES: $(systemctl is-enabled NetworkManager.service 2>&1)"' 30)" = masked ] && ok "NetworkManager is masked for the next boot" || bad "NetworkManager is not masked"
boot
wait_result unhealthy 300 && ok "the health check ran after the reboot and found the machine unhealthy" || bad "no unhealthy result: result=$(hval result)"
failed="$(hval failed)"
case "$failed" in *20-network*30-services*) ok "failed checks: $failed (the network stack and the key services)" ;; *) bad "failed checks: '$failed'" ;; esac
case "$(g 'echo "RES: $(sed -n "s/^message-20-network=//p" /var/lib/nisse/update/health)"' 30)" in *NetworkManager*) ok "the reason names NetworkManager" ;; *) bad "network reason: $(g 'echo "RES: $(grep message /var/lib/nisse/update/health | tr "\n" ";")"' 30)" ;; esac
[ "$(state_of state)" = pending-verify ] && [ "$(boot_status armed)" = yes ] && ok "an unhealthy update stays pending-verify with GRUB still armed (rolling back is N-310's job)" || bad "after the failure: state=$(state_of state) armed=$(boot_status armed)"
[ "$(boot_status tries-left)" = 2 ] && ok "GRUB counted this boot (3 -> 2): the fallback is still on its way" || bad "tries-left=$(boot_status tries-left)"
V run 'S systemctl unmask NetworkManager.service; S rm -f /etc/systemd/system/nisse-health-check.service.d/e2e.conf; S nisse-boot clear' 60 >/dev/null

echo
[ "$failures" = 0 ] && echo "PASS: the health check on the real machine" || { echo "$failures failed"; exit 1; }
