#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-307: the real GRUB on an installed nisse disk: a snapshot picked from the boot menu by keyboard boots, a counted boot failure
# falls back to the snapshot, the controls (unarmed broken boots, armed then cleared) do not, a garbage or unusable rollback
# file still boots normally, and Fedora's success timer is held while armed. About 30 minutes (every step is a real boot).
# Runs on the Windows host (QEMU with WHPX), from Git Bash. Needs the installed disk of the N-303 harness and the two RPMs:
#   bash tests/e2e/test_install_to_disk.sh                   (once per ISO: makes out/install/run/target.qcow2)
#   in the build VM: tools/rpm/build-rpm.sh nisse-boot ; tools/rpm/build-rpm.sh nisse-snapshots
#   bash tests/e2e/test_boot_fallback.sh
# The installed disk is never written: the machine runs on a disposable overlay (tools/vm/vmserver.py). A guest reboot hangs
# this QEMU setup, so every "boot" here is a power-cycle (stop the process, start it on the same disk and firmware variables).
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

port=24690
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
[ -f "$disk" ] && [ -f "$vars" ] || { echo "FAIL: no installed disk (run tests/e2e/test_install_to_disk.sh first)"; exit 2; }
work="$(cygpath -m "$(mktemp -d)")"
pulled=out/install/boot-e2e          # the RPMs, pulled from the build VM (out/ is git-ignored)
mkdir -p "$pulled"
V() { python tools/vm/vmserver.py call "$port" "$@"; }
# a value the guest prints on a line starting with RES:
g() { V run "$1" "${2:-120}" | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
login() { bash tools/vm/vmlogin.sh "$port" >/dev/null; }
boot() { V powercycle >/dev/null; V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the power-cycle"; V shot "$work/nologin.png" >/dev/null; exit 1; }; login; }
which_root() { g 'if [ -e /etc/nisse-e2e-marker ]; then echo "RES: snapshot"; else echo "RES: normal"; fi' 60; }
env_of() { g "echo \"RES: \$(S grub2-editenv list | grep -E '^$1=' | cut -d= -f2-)\"" 60; }
cleanup() { V quit >/dev/null 2>&1; sleep 2; rm -rf "$work"; }
trap cleanup EXIT

# ---- the packages (built in the build VM)
for p in nisse-boot nisse-snapshots; do
    rpmname="$(bash tools/build/vm.sh ssh "ls -v ~/nisse/out/rpmbuild/RPMS/noarch/$p-[0-9]*.rpm | tail -1" < /dev/null 2>/dev/null | tr -d '\r' | tail -1)"
    [ -n "$rpmname" ] || { echo "FAIL: no $p RPM in the build VM"; exit 2; }
    rm -f "$pulled"/"$p"-[0-9]*.rpm
    bash tools/build/vm.sh pull "${rpmname#/home/builder/nisse/}" "$pulled/" >/dev/null 2>&1
    ls "$pulled"/"$p"-[0-9]*.rpm >/dev/null 2>&1 || { echo "FAIL: could not pull $p"; exit 2; }
done

# ---- the machine
python tools/vm/vmserver.py serve --disk "$disk" --vars "$vars" --work "$work/vm" --port "$port" > "$work/server.log" 2>&1 &
sleep 8
V expect "login:" 420 >/dev/null || { echo "FAIL: the installed disk did not reach a login"; exit 1; }
login
ok "the installed disk booted to a login (on a throwaway overlay)"

for p in nisse-boot nisse-snapshots; do
    V put "/tmp/$p.rpm" "$(cygpath -m "$(ls "$pulled"/"$p"-[0-9]*.rpm | head -1)")" >/dev/null
done
out="$(V run 'S dnf install -y --disablerepo=updates /tmp/nisse-snapshots.rpm /tmp/nisse-boot.rpm 2>&1 | tail -3; echo "RES: $(rpm -q nisse-boot nisse-snapshots | tr "\n" " ")"' 900)"
case "$out" in *"RES: nisse-boot-"*"nisse-snapshots-"*) ok "nisse-boot and nisse-snapshots install on the installed system" ;; *) bad "install failed: $(echo "$out" | tail -5)"; exit 1 ;; esac

# ---- the first-boot fixes: env_block (the installed system really has it), snippets in grub.cfg, the snapper config
before="$(env_of env_block)"
[ "$before" = "512+1" ] && ok "as installed, the GRUB environment has env_block=512+1 (GRUB cannot save its variables)" || bad "env_block before the fix was '$before' (the finding of the N-307 spike did not reproduce)"
V run 'S systemctl start nisse-snapshot-setup.service; S systemctl start nisse-boot-setup.service; S systemctl start nisse-boot-sync.path' 180 >/dev/null
[ -z "$(env_of env_block)" ] && ok "nisse-boot-setup removed env_block" || bad "env_block is still there"
[ "$(g 'echo "RES: $(S grep -c -E "09_nisse_fallback|11_nisse_snapshots" /boot/grub2/grub.cfg)"' 60)" -ge 2 ] 2>/dev/null && ok "grub.cfg has both nisse snippets (regenerated once)" || bad "grub.cfg lacks the nisse snippets"
[ "$(g 'echo "RES: $(test -f /etc/snapper/configs/root && echo yes)"' 60)" = yes ] && ok "the snapper root config exists (nisse-snapshots first-boot setup)" || bad "no snapper root config"

# ---- two snapshots; the newest has a marker file so the booted root can be told apart
V run 'S snapper -c root create -d "e2e clean" >/dev/null; S sh -c "echo e2e > /etc/nisse-e2e-marker"; S snapper -c root create -d "e2e marked" >/dev/null; S rm -f /etc/nisse-e2e-marker; S sync' 120 >/dev/null
snapA="$(g 'echo "RES: $(S snapper -c root --csvout list --columns number,description | grep "e2e marked" | cut -d, -f1)"' 60)"
snapB="$(g 'echo "RES: $(S snapper -c root --csvout list --columns number,description | grep "e2e clean" | cut -d, -f1)"' 60)"
[ -n "$snapA" ] && [ -n "$snapB" ] && ok "snapshots made: $snapB (clean) and $snapA (marked, the newest)" || { bad "could not make snapshots"; exit 1; }
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(g 'echo "RES: $(S grep -c "^menuentry" /boot/grub2/nisse-boot.cfg 2>/dev/null)"' 30)" -ge 2 ] 2>/dev/null && break
    sleep 3
done
menu="$(g 'echo "RES: $(S grep -o "nisse-snap-[0-9]*" /boot/grub2/nisse-boot.cfg | tr "\n" " ")"' 30)"
case "$menu" in *"nisse-snap-$snapA"*"nisse-snap-$snapB"*) ok "the snapshot menu file follows the snapshots folder by itself (path unit): $menu" ;; *) bad "the menu file does not list both snapshots: '$menu'" ;; esac
[ "$(g 'echo "RES: $(S head -3 /boot/grub2/nisse-boot.cfg | grep -c nisse-snap-'"$snapA"')"' 30)" = 1 ] && ok "newest snapshot is the first entry" || bad "the newest snapshot is not first"

# ---- 1. a snapshot picked from the real GRUB menu by keyboard (the menu must be showing: boot_success=0)
picked=no
for try in 1 2 3; do
    V run 'S grub2-editenv - set boot_success=0; S sync' 30 >/dev/null
    V powercycle >/dev/null
    sleep 3.2; V key down; sleep 0.4; V key down; sleep 0.5; V key ret; sleep 1.2; V key ret
    V expect "login:" 420 >/dev/null || continue
    login
    if [ "$(which_root)" = snapshot ]; then picked=yes; break; fi
done
[ "$picked" = yes ] && ok "picked 'nisse snapshots' then the first entry from the GRUB menu with the keyboard: that snapshot booted" || bad "the keyboard pick did not boot the snapshot"
sub="$(g 'echo "RES: $(findmnt -no OPTIONS / | grep -o "subvol=[^,]*")"' 30)"
[ "$sub" = "subvol=/root/.snapshots/$snapA/snapshot" ] && ok "it is snapshot $snapA's own subvolume, read-only ($sub)" || bad "unexpected subvolume: $sub"
[ "$(g 'echo "RES: $(touch /e2e-write-test 2>&1 | grep -c Read-only)"' 30)" = 1 ] && ok "writing to the snapshot root is refused (read-only)" || bad "the snapshot root is writable"
[ -z "$(env_of next_entry)" ] && ok "booting an entry from the menu did not change the default (the next boot is the normal system)" || bad "the menu pick left next_entry set"
boot
[ "$(which_root)" = normal ] && ok "the next boot is the normal system again" || bad "the next boot was not normal"

# ---- 2. counted failure falls back
V run "S nisse-boot arm --tries 2 $snapA" 60 >/dev/null
st="$(g 'echo "RES: $(S nisse-boot status | tr "\n" " ")"' 60)"
case "$st" in *"armed=yes"*"snapshot=$snapA"*"tries-left=2"*) ok "armed: $st" ;; *) bad "status after arm: $st" ;; esac
[ "$(env_of boot_counter)" = 2 ] && [ -n "$(env_of nisse_fallback)" ] && ok "GRUB's environment holds the counter and the fallback entry name" || bad "grub env after arm: counter=$(env_of boot_counter)"
boot
[ "$(which_root)" = normal ] && [ "$(env_of boot_counter)" = 1 ] && ok "armed boot 1 starts normally and GRUB counted 2 -> 1" || bad "boot 1: $(which_root) counter=$(env_of boot_counter)"
echo "     holding this session open for 150 s: the success timer must NOT mark the boot good while armed"
sleep 150
[ "$(env_of boot_success)" = 0 ] && ok "while armed, Fedora's success timer did not run (boot_success is still 0 after 150 s logged in)" || bad "boot_success became $(env_of boot_success) while armed (the timer ran)"
boot
[ "$(which_root)" = normal ] && [ "$(env_of boot_counter)" = 0 ] && ok "armed boot 2 starts normally, counter 1 -> 0" || bad "boot 2: $(which_root) counter=$(env_of boot_counter)"
boot
[ "$(which_root)" = snapshot ] && ok "boot 3: the countdown ran out and GRUB started the snapshot by itself" || bad "boot 3 was $(which_root), expected the snapshot"
st="$(g 'echo "RES: $(S nisse-boot status | tr "\n" " ")"' 60)"
case "$st" in *"fell-back=yes"*) ok "status from the fallback boot says it fell back" ;; *) bad "status after the fallback: $st" ;; esac
boot
[ "$(which_root)" = snapshot ] && ok "boot 4: it keeps starting the snapshot until cleared" || bad "boot 4 was $(which_root)"

# ---- 3. clear from the fallback boot (a read-only snapshot: only GRUB can be disarmed there), then the next normal boot finishes the job
V run 'S nisse-boot clear; echo "RES: rc=$?"' 60 | grep -q "RES: rc=0" && ok "nisse-boot clear works on the read-only fallback boot (exit 0)" || bad "clear failed on the fallback boot"
[ -z "$(env_of boot_counter)" ] && [ -z "$(env_of nisse_fallback)" ] && [ "$(env_of boot_success)" = 1 ] && ok "GRUB is disarmed and the boot is marked good" || bad "grub env after clear: counter=$(env_of boot_counter) success=$(env_of boot_success)"
boot
[ "$(which_root)" = normal ] && ok "after clear the next boot is the normal system" || bad "after clear the boot was $(which_root)"
[ "$(g 'echo "RES: $(test -e /var/lib/nisse/boot/armed && echo stale || echo gone)"' 30)" = gone ] && ok "the normal boot dropped the stale arm (reconcile)" || bad "the stale arm file is still there"
[ "$(g 'echo "RES: $(S test -e /boot/grub2/nisse-rollback.cfg && echo stale || echo gone)"' 30)" = gone ] && ok "and the rollback file" || bad "the rollback file is still there"
cl="$(g "echo \"RES: \$(S snapper -c root --csvout list --columns number,cleanup | grep '^$snapA,' | cut -d, -f2)\"" 60)"
[ "$cl" = number ] && ok "the snapshot is back under normal cleanup (cleanup=number)" || bad "snapshot $snapA cleanup is '$cl'"
echo "     fresh boot, unarmed, session held open 150 s: the success timer (2 minutes after login) must run"
V run 'S grub2-editenv - set boot_success=0; S sync' 30 >/dev/null
boot
sleep 150
[ "$(env_of boot_success)" = 1 ] && ok "control: unarmed, Fedora's success timer marks the boot good (the hold is only while armed)" || bad "control: boot_success is $(env_of boot_success) while unarmed"

# ---- 4. controls
V run 'S grub2-editenv - unset boot_counter nisse_fallback; S grub2-editenv - set boot_success=0; S sync' 30 >/dev/null
r=""; for i in 1 2 3; do boot; r="$r $(which_root)"; done
[ "$r" = " normal normal normal" ] && [ -z "$(env_of boot_counter)" ] && ok "control: unarmed broken boots (never marked good) never fall back" || bad "control unarmed: $r"
V run "S nisse-boot arm --tries 2 $snapA" 60 >/dev/null
boot
[ "$(which_root)" = normal ] && [ "$(env_of boot_counter)" = 1 ] && ok "control: armed, boot 1 normal" || bad "control armed boot 1: $(which_root)"
V run 'S nisse-boot clear' 60 >/dev/null
r=""; for i in 1 2 3; do boot; r="$r $(which_root)"; done
[ "$r" = " normal normal normal" ] && ok "control: armed then cleared: later boots stay normal" || bad "control cleared: $r"

# ---- 5. a bad rollback file or an unusable kernel never leaves the machine at the menu
V put /tmp/garbage.cfg "$(cygpath -m "$PWD/tests/e2e/data/grub-garbage.cfg")" >/dev/null
V run 'S install -m 644 /tmp/garbage.cfg /boot/grub2/nisse-rollback.cfg; S grub2-editenv - set boot_counter=-1 boot_success=0 nisse_fallback=nisse-rollback; S sync' 60 >/dev/null
boot
[ "$(which_root)" = normal ] && ok "a garbage rollback file: the machine boots normally" || bad "a garbage rollback file: booted $(which_root)"
V put /tmp/missing-kernel.cfg "$(cygpath -m "$PWD/tests/e2e/data/grub-missing-kernel.cfg")" >/dev/null
V run 'S install -m 644 /tmp/missing-kernel.cfg /boot/grub2/nisse-rollback.cfg; S grub2-editenv - set boot_counter=-1 boot_success=0 nisse_fallback=nisse-rollback; S sync' 60 >/dev/null
boot
[ "$(which_root)" = normal ] && ok "a rollback entry naming a kernel that is not there: the machine boots normally" || bad "a missing kernel: booted $(which_root)"
V run 'S nisse-boot clear' 60 >/dev/null

echo
[ "$failures" = 0 ] && echo "PASS: the real GRUB menu and boot counter" || { echo "$failures failed"; exit 1; }
