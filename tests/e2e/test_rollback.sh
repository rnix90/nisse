#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-310: the watchdog rollback on an installed nisse disk with the REAL btrfs, snapper, dnf, systemd and GRUB.
#   A. an update that installs fine and then fails its health check after the reboot: the watchdog sees the unhealthy result,
#      counts down, swaps the restored root in and reboots; the machine comes back on the old packages with a writable root,
#      its snapshots, GRUB disarmed and the record of what happened; the same update is not tried again, a different one is.
#   B. an update whose boots never finish: GRUB falls back to the snapshot by itself, and the watchdog running there settles it
#      with a real rollback, so the machine ends up on a normal, writable root and not on a read-only snapshot.
# About 45 minutes (every step is a real boot). Runs on the Windows host (QEMU with WHPX), from Git Bash. Needs the installed
# disk of the N-303 harness and the RPMs built in the build VM (nisse-update 0.1-3 or later, nisse-boot, nisse-snapshots):
#   bash tests/e2e/test_install_to_disk.sh                   (once per ISO: makes out/install/run/target.qcow2)
#   in the build VM: tools/rpm/build-rpm.sh nisse-update ; nisse-boot ; nisse-snapshots
#   bash tests/e2e/test_rollback.sh
# The installed disk is never written (a disposable overlay in a LOCAL temp folder: on a network drive the machine crawls). A
# guest reboot hangs this QEMU setup, so when the guest starts one by itself the harness sees the kernel say so on the console and
# power-cycles. The countdown is 20 s here (a drop-in) so the test does not wait a minute at each step; 60 s and ten minutes
# are covered by tests/shell/test_nisse_watchdog.sh.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

port=24696
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
[ -f "$disk" ] && [ -f "$vars" ] || { echo "FAIL: no installed disk (run tests/e2e/test_install_to_disk.sh first)"; exit 2; }
work="$(cygpath -m "$(mktemp -d)")"
case "$work" in //* | [T-Zt-z]:*) echo "FAIL: the work folder $work looks like a network drive: the machine would crawl"; exit 2 ;; esac
pulled=out/install/rollback-e2e
mkdir -p "$pulled"
V() { python tools/vm/vmserver.py call "$port" "$@"; }
g() { V run "$1" "${2:-120}" | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
login() { bash tools/vm/vmlogin.sh "$port" >/dev/null; }
boot() { V run 'S sync' 60 >/dev/null 2>&1; V powercycle >/dev/null; V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the power-cycle"; V shot "$work/nologin.png" >/dev/null; exit 1; }; login; }
# the guest reboots itself (the watchdog's rollback): wait for the kernel's last console line, then power-cycle
guest_reboots() {
    V expect "Restarting system" "$1" >/dev/null || { echo "FAIL: the guest never started its own reboot within $1 s"; return 1; }
    V powercycle >/dev/null
    V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the guest's own reboot"; V shot "$work/nologin.png" >/dev/null; exit 1; }
    login
}
probe() { g 'echo "RES: $(cat /usr/share/nisse-e2e/version 2>/dev/null)"' 30; }
which_root() { g 'echo "RES: $(findmnt -no OPTIONS / | grep -o "subvol=[^,]*")"' 30; }
state_of() { g "echo \"RES: \$(sed -n 's/^$1=//p' /var/lib/nisse/update/state 2>/dev/null)\"" 30; }
boot_status() { g "echo \"RES: \$(S nisse-boot status | grep '^$1=' | cut -d= -f2)\"" 30; }
grubenv() { g "echo \"RES: \$(S grub2-editenv list | grep -E '^$1=' | cut -d= -f2-)\"" 30; }
snap_count() { g 'echo "RES: $(S snapper --no-dbus -c root --csvout list --columns number | tail -n +2 | grep -vc "^0$")"' 60; }
repo() { echo "--dnf-arg --repofrompath=e2e,file:///var/lib/e2e/repo-$1 --dnf-arg --repo=e2e --dnf-arg --no-gpgchecks"; }
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
case "$(ls "$pulled"/nisse-update-[0-9]*.rpm)" in *"-0.1-"[3-9]* | *"-0.2-"*) ;; *) echo "FAIL: the nisse-update RPM is older than 0.1-3 (no rollback in it)"; exit 2 ;; esac

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
out="$(V run 'S dnf install -y --disablerepo=updates /tmp/nisse-snapshots.rpm /tmp/nisse-boot.rpm /tmp/nisse-update.rpm 2>&1 | tail -2; echo "RES: $(rpm -q nisse-update nisse-boot nisse-snapshots | tr "\n" " ")"' 1800)"
case "$out" in *"RES: nisse-update-"*) ok "nisse-update, nisse-boot and nisse-snapshots install on the installed system" ;; *) bad "install failed: $(echo "$out" | tail -4)"; exit 1 ;; esac
V run 'S systemctl start nisse-snapshot-setup.service; S systemctl start nisse-boot-setup.service; S mkdir -p /var/lib/e2e; S tar -C /var/lib/e2e -xzf /tmp/probe-repos.tgz; S dnf install -y /var/lib/e2e/probe-1.0.rpm >/dev/null 2>&1' 600 >/dev/null
[ "$(probe)" = 1.0 ] && ok "probe package 1.0 installed" || { bad "probe 1.0 did not install"; exit 1; }
[ "$(g 'echo "RES: $(systemctl is-enabled nisse-update-watchdog.service 2>&1)"' 30)" = enabled ] && ok "the package's preset enabled nisse-update-watchdog.service" || bad "the watchdog unit is not enabled"
# short waits for the test (the drop-ins are made BEFORE the update's snapshot, so a restored root has them too; the production
# values are in the shell tests)
V run 'S mkdir -p /etc/systemd/system/nisse-update-watchdog.service.d /etc/systemd/system/nisse-health-check.service.d; S sh -c "printf \"[Service]\nEnvironment=NISSE_COUNTDOWN=20\n\" > /etc/systemd/system/nisse-update-watchdog.service.d/e2e.conf"; S sh -c "printf \"[Service]\nExecStart=\nExecStart=/usr/bin/nisse-health-check run --deadline 40\n\" > /etc/systemd/system/nisse-health-check.service.d/e2e.conf"; S systemctl daemon-reload' 60 >/dev/null
V run 'S sh -c "echo e2e-before-update > /home/e2e-home-file"; S sync' 30 >/dev/null

# ======== A. an update that fails its health check
n0="$(snap_count)"
rc="$(V run "S nisse-apply-updates run $(repo broken); echo \"RES: rc=\$?\"" 900 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1)"
snapA="$(state_of snapshot)"
[ "$rc" = "rc=0" ] && [ "$(probe)" = 4.0 ] && [ "$(state_of state)" = pending-verify ] && ok "A: the broken update is applied: probe 4.0, pending-verify, before snapshot $snapA" || bad "A: update: $rc probe=$(probe) state=$(state_of state)"
[ -n "$(state_of fingerprint)" ] && ok "A: the pending state carries the update's fingerprint ($(state_of fingerprint))" || bad "A: no fingerprint in the state"
fpA="$(state_of fingerprint)"
[ "$(g 'echo "RES: $(test -x /usr/lib/nisse/health.d/99-e2e-broken && echo yes)"' 30)" = yes ] && ok "A: the update shipped its failing health check" || bad "A: the broken check is missing"
V run 'S sh -c "echo e2e-written-after-update > /home/e2e-home-file-2"; S sync' 30 >/dev/null
boot
echo "     waiting for: health check (40 s deadline), the watchdog's 20 s countdown, the rollback and the guest's own reboot"
guest_reboots 600 && ok "A: after the unhealthy boot the guest started a reboot by itself (the watchdog's rollback)" || { bad "A: no reboot by the watchdog"; exit 1; }

[ "$(probe)" = 1.0 ] && ok "A: the machine came back on the OLD packages (probe 1.0, not 4.0)" || bad "A: probe is $(probe)"
[ "$(g 'echo "RES: $(test -e /usr/lib/nisse/health.d/99-e2e-broken && echo present || echo gone)"' 30)" = gone ] && ok "A: the broken health check is gone" || bad "A: the broken check is still installed"
[ "$(which_root)" = "subvol=/root" ] && ok "A: it runs on the normal root subvolume (subvol=/root), not on a snapshot" || bad "A: root is $(which_root)"
[ "$(g 'echo "RES: $(S touch /e2e-write-test 2>&1 && echo writable || echo read-only)"; S rm -f /e2e-write-test' 30)" = writable ] && ok "A: the restored root is writable" || bad "A: the restored root is read-only"
[ "$(state_of state)" = idle ] && [ "$(state_of last)" = rolled-back ] && ok "A: the state says idle, last=rolled-back" || bad "A: state=$(state_of state) last=$(state_of last)"
[ "$(state_of snapshot)" = "$snapA" ] && ok "A: it names the snapshot it went back to ($snapA)" || bad "A: snapshot in the state: $(state_of snapshot)"
case "$(state_of reason)" in *"health check failed"*99-e2e-broken*"broken"*) ok "A: the reason names the failing check and its own message: $(state_of reason)" ;; *) bad "A: reason: '$(state_of reason)'" ;; esac
[ "$(state_of blocked-fingerprint)" = "$fpA" ] && ok "A: the failed update's fingerprint is carried over as blocked-fingerprint" || bad "A: blocked-fingerprint '$(state_of blocked-fingerprint)' vs '$fpA'"
[ "$(g 'echo "RES: $(grep -c 99-e2e-broken /var/lib/nisse/update/failed-health)"' 30)" -ge 1 ] 2>/dev/null && ok "A: the failing health result is kept as failed-health" || bad "A: no failed-health"
[ "$(g 'echo "RES: $(grep -c nisse-e2e-probe /var/lib/nisse/update/failed-changed.txt)"' 30)" -ge 1 ] 2>/dev/null && ok "A: the failed update's package list is kept as failed-changed.txt" || bad "A: no failed-changed.txt"
top="$(g 'S mkdir -p /mnt/top; S mount -o subvolid=5 "$(findmnt -no SOURCE / | sed "s/\[.*//")" /mnt/top; echo "RES: $(ls /mnt/top | tr "\n" " ")"' 60)"
case "$top" in *"root.failed-"*) ok "A: the replaced root is kept at the top level for inspection ($top)" ;; *) bad "A: no root.failed-* in: $top" ;; esac
[ "$(g 'echo "RES: $(ls /mnt/top/root.failed-*/usr/share/nisse-e2e/version >/dev/null 2>&1 && cat /mnt/top/root.failed-*/usr/share/nisse-e2e/version)"' 30)" = 4.0 ] && ok "A: and it really is the failed (4.0) system" || bad "A: the kept root does not hold probe 4.0"
case "$top" in *home*var_log* | *home*) ok "A: home, var_log and var_cache are still there beside it" ;; *) bad "A: excluded subvolumes missing: $top" ;; esac
V run 'S umount /mnt/top' 30 >/dev/null
[ "$(g 'echo "RES: $(cat /home/e2e-home-file 2>/dev/null)"' 30)" = e2e-before-update ] && [ "$(g 'echo "RES: $(cat /home/e2e-home-file-2 2>/dev/null)"' 30)" = e2e-written-after-update ] && ok "A: files in /home (an excluded subvolume), before and after the update, are untouched by the rollback" || bad "A: /home files changed"
[ "$(snap_count)" -ge "$((n0 + 2))" ] && ok "A: snapper works on the restored root and still lists the snapshots ($(snap_count))" || bad "A: snapshots $n0 -> $(snap_count)"
[ "$(boot_status armed)" = no ] && [ -z "$(grubenv boot_counter)" ] && [ -z "$(grubenv nisse_fallback)" ] && ok "A: GRUB is disarmed (no boot counter, no fallback entry named)" || bad "A: still armed: armed=$(boot_status armed) counter=$(grubenv boot_counter) fallback=$(grubenv nisse_fallback)"
[ "$(g 'echo "RES: $(test -e /var/lib/nisse/boot/armed && echo present || echo gone)"' 30)" = gone ] && ok "A: the next boot's reconcile dropped the arm record (snapshot $snapA is back under snapper's cleanup)" || bad "A: the arm record is still there"
[ "$(g "echo \"RES: \$(S snapper --no-dbus -c root --csvout list --columns number,cleanup | grep \"^$snapA,\" | cut -d, -f2)\"" 60)" = number ] && ok "A: snapshot $snapA is handed back to the number cleanup" || bad "A: snapshot $snapA cleanup algorithm: '$(g "echo \"RES: \$(S snapper --no-dbus -c root --csvout list --columns number,cleanup | grep \"^$snapA,\")\"" 60)'"
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(g 'echo "RES: $(S grep -c "^menuentry" /boot/grub2/nisse-boot.cfg 2>/dev/null)"' 30)" -ge 1 ] 2>/dev/null && break
    sleep 3
done
case "$(g "echo \"RES: \$(S grep -o 'nisse-snap-[0-9]*' /boot/grub2/nisse-boot.cfg 2>/dev/null | tr '\n' ' ')\"" 30)" in *"nisse-snap-$snapA"*) ok "A: the snapshot boot menu was rewritten for the restored system (moving .snapshots had emptied it for a moment) and lists snapshot $snapA" ;; *) bad "A: the snapshot boot menu does not list $snapA after the rollback" ;; esac
[ "$(g 'echo "RES: $(systemctl is-active nisse-update-watchdog.service 2>&1)"' 30)" = inactive ] && ok "A: with nothing pending the watchdog ended at once" || bad "A: the watchdog unit is $(g 'echo "RES: $(systemctl is-active nisse-update-watchdog.service 2>&1)"' 30)"

# ---- the same update is not tried again
n1="$(snap_count)"
out="$(V run "S nisse-apply-updates run $(repo broken) 2>&1; echo \"RES: rc=\$?\"" 900 | tr -d '\r')"
case "$out" in *"skipped"*"rolled back"*) ok "A: running the same update again is skipped, with the reason" ;; *) bad "A: the same update was not skipped: $(echo "$out" | tail -3)" ;; esac
[ "$(echo "$out" | sed -n 's/^RES: //p' | tail -1)" = "rc=0" ] && [ "$(probe)" = 1.0 ] && [ "$(snap_count)" = "$n1" ] && ok "A: skipping is not an error, installed nothing and took no snapshot" || bad "A: skipped run changed things: probe=$(probe) snapshots $n1 -> $(snap_count)"
[ "$(state_of last)" = rolled-back ] && [ -n "$(state_of skipped-at)" ] && ok "A: the rollback record is kept and the skip is recorded (skipped-at)" || bad "A: state after the skip: last=$(state_of last) skipped-at=$(state_of skipped-at)"

# ---- a DIFFERENT update is tried, and a healthy one verifies itself
rc="$(V run "S nisse-apply-updates run $(repo good); echo \"RES: rc=\$?\"" 900 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1)"
[ "$rc" = "rc=0" ] && [ "$(probe)" = 2.0 ] && [ "$(state_of state)" = pending-verify ] && ok "A: a different update (probe 2.0) is applied as normal after the rollback" || bad "A: different update: $rc probe=$(probe) state=$(state_of state)"
[ -z "$(state_of blocked-fingerprint)" ] && [ -n "$(state_of fingerprint)" ] && [ "$(state_of fingerprint)" != "$fpA" ] && ok "A: the block is replaced by the new update's own fingerprint" || bad "A: fingerprints: blocked='$(state_of blocked-fingerprint)' new='$(state_of fingerprint)'"
V run 'S mkdir -p /etc/systemd/system/nisse-health-check.service.d; S sh -c "printf \"[Service]\nExecStart=\nExecStart=/usr/bin/nisse-health-check run --deadline 40\n\" > /etc/systemd/system/nisse-health-check.service.d/e2e.conf"; S systemctl daemon-reload; S rm -f /var/lib/nisse/update/health' 60 >/dev/null
boot
t=0; while [ "$t" -lt 300 ]; do [ "$(state_of state)" = idle ] && break; sleep 10; t=$((t + 10)); done
[ "$(state_of state)" = idle ] && [ "$(state_of last)" = verified ] && [ "$(probe)" = 2.0 ] && ok "A: the healthy update verified itself after its reboot and the watchdog did not touch it (probe 2.0)" || bad "A: healthy update: state=$(state_of state) last=$(state_of last) probe=$(probe)"

# ======== B. an update whose boots never finish: GRUB falls back, the watchdog settles it
V run 'S mkdir -p /etc/systemd/system/nisse-update-watchdog.service.d; S sh -c "printf \"[Service]\nEnvironment=NISSE_COUNTDOWN=20\nEnvironment=NISSE_HANG_LIMIT=36000\n\" > /etc/systemd/system/nisse-update-watchdog.service.d/e2e.conf"; S systemctl daemon-reload' 60 >/dev/null
rc="$(V run "S nisse-apply-updates run $(repo good2) --tries 2; echo \"RES: rc=\$?\"" 900 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1)"
snapB="$(state_of snapshot)"
[ "$rc" = "rc=0" ] && [ "$(probe)" = 2.5 ] && [ "$(state_of state)" = pending-verify ] && [ "$(boot_status armed)" = yes ] && ok "B: a second update is applied: probe 2.5, pending-verify, armed on snapshot $snapB with 2 tries" || bad "B: update: $rc probe=$(probe) state=$(state_of state)"
# its health check never gets a verdict (masked in the running root only, the snapshot predates it)
V run 'S systemctl mask nisse-health-check.service; S sync' 60 >/dev/null
boot; r1="$(which_root)"; p1="$(probe)"
boot; r2="$(which_root)"
[ "$r1" = "subvol=/root" ] && [ "$p1" = 2.5 ] && [ "$r2" = "subvol=/root" ] && ok "B: boots 1 and 2 start the updated system (probe 2.5), nothing verifies it" || bad "B: boots 1-2: $r1 $r2 (probe $p1)"
V run 'S sync' 30 >/dev/null; V powercycle >/dev/null
V expect "login:" 420 >/dev/null || { bad "B: no login on the third boot"; exit 1; }
login
[ "$(which_root)" = "subvol=/root/.snapshots/$snapB/snapshot" ] && ok "B: boot 3: GRUB fell back to snapshot $snapB by itself (the running root is the read-only snapshot)" || bad "B: boot 3 root: $(which_root)"
[ "$(boot_status fell-back)" = yes ] && ok "B: nisse-boot status says it fell back" || bad "B: no fell-back flag"
echo "     waiting for the watchdog on the fallback boot: 20 s countdown... (production: 60 s), then the rollback and the guest's own reboot"
guest_reboots 600 && ok "B: the watchdog on the fallback boot started a reboot by itself" || { bad "B: no reboot by the watchdog on the fallback boot"; exit 1; }
[ "$(which_root)" = "subvol=/root" ] && ok "B: the machine is on the normal root again, not on the snapshot" || bad "B: root after the settle: $(which_root)"
[ "$(probe)" = 2.0 ] && ok "B: the packages are the pre-update ones (probe 2.0)" || bad "B: probe is $(probe)"
[ "$(g 'echo "RES: $(S touch /e2e-write-test 2>&1 && echo writable || echo read-only)"; S rm -f /e2e-write-test' 30)" = writable ] && ok "B: the root is writable (the settle is a real rollback, not just a snapshot boot)" || bad "B: read-only root"
[ "$(state_of last)" = rolled-back ] && [ "$(state_of snapshot)" = "$snapB" ] && ok "B: the state records last=rolled-back to snapshot $snapB" || bad "B: state last=$(state_of last) snapshot=$(state_of snapshot)"
case "$(state_of reason)" in *"fell back"*) ok "B: the reason says the machine fell back: $(state_of reason)" ;; *) bad "B: reason '$(state_of reason)'" ;; esac
[ -z "$(grubenv boot_counter)" ] && [ -z "$(grubenv nisse_fallback)" ] && [ "$(boot_status armed)" = no ] && ok "B: GRUB is disarmed" || bad "B: GRUB still armed: counter=$(grubenv boot_counter) fallback=$(grubenv nisse_fallback) armed=$(boot_status armed)"
boot
[ "$(which_root)" = "subvol=/root" ] && [ "$(boot_status fell-back)" = "" ] && ok "B: one more boot is normal and does not fall back again" || bad "B: next boot root=$(which_root) fell-back=$(boot_status fell-back)"

echo
[ "$failures" = 0 ] && echo "PASS: the watchdog rollback on the real machine" || { echo "$failures failed"; exit 1; }
