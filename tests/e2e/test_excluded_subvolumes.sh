#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-312: what a rollback does NOT touch, on an installed nisse disk with the REAL btrfs, snapper and GRUB: files in home, var_log,
# var_cache (the subvolumes the installer makes besides the root), in a data subvolume mounted from fstab, and in a subvolume NESTED
# inside the root (which a snapshot does not hold, so nisse-rollback carries it across) survive a rollback of the root; the change
# made to the root after the snapshot is gone. Also shown, as the limit it is: a data subvolume whose fstab line was added AFTER the
# snapshot keeps its files but is not mounted by the restored system until the line is put back.
# About 20 minutes (one real restart). Runs on the Windows host (QEMU with WHPX), from Git Bash. Needs the installed disk of the N-303
# harness and the RPMs built in the build VM (nisse-update 0.1-5, nisse-boot, nisse-snapshots):
#   bash tests/e2e/test_install_to_disk.sh                   (once per ISO: makes out/install/run/target.qcow2)
#   in the build VM: tools/rpm/build-rpm.sh nisse-update ; nisse-boot ; nisse-snapshots
#   bash tests/e2e/test_excluded_subvolumes.sh
# The installed disk is never written (a disposable overlay in a LOCAL temp folder). Files reach the guest over a small HTTP server on
# the host (10.0.2.2); a guest reboot hangs this QEMU setup, so the harness sees the kernel announce the restart and power-cycles.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

port=24700
httpport=24701
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
[ -f "$disk" ] && [ -f "$vars" ] || { echo "FAIL: no installed disk (run tests/e2e/test_install_to_disk.sh first)"; exit 2; }
work="$(cygpath -m "$(mktemp -d)")"
case "$work" in //* | [T-Zt-z]:*) echo "FAIL: the work folder $work looks like a network drive: the machine would crawl"; exit 2 ;; esac
pulled=out/install/excluded-e2e
mkdir -p "$pulled"
V() { python tools/vm/vmserver.py call "$port" "$@"; }
login() { bash tools/vm/vmlogin.sh "$port" >/dev/null; }
boot() { V run 'S sync' 60 >/dev/null 2>&1; V powercycle >/dev/null; V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the power-cycle"; exit 1; }; login; }
guest_reboots() {
    V expect "Restarting system" "$1" >/dev/null || { echo "FAIL: the guest never started its own reboot within $1 s"; return 1; }
    V powercycle >/dev/null
    V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the guest's own reboot"; exit 1; }
    login
}
# the guest script's CHECK lines, once, into $checks
checks=""
# /tmp does not survive the restart: the guest script is fetched again
refresh_checks() { fetch guest.sh >/dev/null; checks="$(V run 'S sh /tmp/guest.sh check 2>&1' 180 | tr -d '\r' | sed -n 's/^CHECK //p')"; }
val() { printf '%s\n' "$checks" | sed -n "s/^$1=//p" | head -n 1; }
want() { # name expected description
    local got; got="$(val "$1")"
    [ "$got" = "$2" ] && ok "$3" || bad "$3 (expected '$2', got '$got')"
}
cleanup() { V quit >/dev/null 2>&1; [ -n "${httppid:-}" ] && kill "$httppid" 2>/dev/null; sleep 2; rm -rf "$work"; }
trap cleanup EXIT

# ---- the packages (built in the build VM)
for p in nisse-update nisse-boot nisse-snapshots; do
    rpmname="$(bash tools/build/vm.sh ssh "ls -v ~/nisse/out/rpmbuild/RPMS/*/$p-[0-9]*.rpm | tail -1" < /dev/null 2>/dev/null | tr -d '\r' | tail -1)"
    [ -n "$rpmname" ] || { echo "FAIL: no $p RPM in the build VM"; exit 2; }
    rm -f "$pulled"/"$p"-[0-9]*.rpm
    bash tools/build/vm.sh pull "${rpmname#/home/builder/nisse/}" "$pulled/" >/dev/null 2>&1
    ls "$pulled"/"$p"-[0-9]*.rpm >/dev/null 2>&1 || { echo "FAIL: could not pull $p"; exit 2; }
    cp "$(ls "$pulled"/"$p"-[0-9]*.rpm | tail -1)" "$pulled/$p.rpm"
done
case "$(ls "$pulled"/nisse-update-[0-9]*.rpm | tail -1)" in *"-0.1-"[5-9]* | *"-0.2-"*) ;; *) echo "FAIL: the nisse-update RPM is older than 0.1-5 (it does not carry nested subvolumes)"; exit 2 ;; esac
cp tests/e2e/data/excluded_subvolumes_guest.sh "$pulled/guest.sh"
python -m http.server "$httpport" --bind 127.0.0.1 --directory "$pulled" > "$work/http.log" 2>&1 &
httppid=$!

# ---- the machine
python tools/vm/vmserver.py serve --disk "$disk" --vars "$vars" --work "$work/vm" --port "$port" > "$work/server.log" 2>&1 &
sleep 8
V expect "login:" 420 >/dev/null || { echo "FAIL: the installed disk did not reach a login"; exit 1; }
login
ok "the installed disk booted to a login (on a throwaway overlay)"
fetch() { V run "curl -fsS -o /tmp/$1 http://10.0.2.2:$httpport/$1 && echo \"RES: got \$(stat -c %s /tmp/$1)\"" 300 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
for f in nisse-snapshots.rpm nisse-boot.rpm nisse-update.rpm guest.sh; do
    case "$(fetch "$f")" in "got "[1-9]*) ;; *) bad "the guest could not fetch $f from the host over HTTP"; exit 1 ;; esac
done
out="$(V run 'S dnf install -y --disablerepo=updates /tmp/nisse-snapshots.rpm /tmp/nisse-boot.rpm /tmp/nisse-update.rpm 2>&1 | tail -2; echo "RES: $(rpm -q nisse-update nisse-boot nisse-snapshots | tr "\n" " ")"' 1800)"
case "$out" in *"RES: nisse-update-"*) ok "nisse-update, nisse-boot and nisse-snapshots install on the installed system" ;; *) bad "install failed: $(echo "$out" | tail -4)"; exit 1 ;; esac
V run 'S systemctl start nisse-snapshot-setup.service; S systemctl start nisse-boot-setup.service' 300 >/dev/null

# ---- the excluded subvolumes, the files, the snapshot to go back to
setup="$(V run 'S sh /tmp/guest.sh setup 2>&1' 300 | tr -d '\r')"
snap="$(printf '%s\n' "$setup" | sed -n 's/^N=//p' | tail -1)"
case "$snap" in '' | *[!0-9]*) bad "setup failed: $(printf '%s\n' "$setup" | tail -4)"; exit 1 ;; esac
ok "a data subvolume (mounted from fstab) and a nested subvolume were made, files written into home, var_log, var_cache, the data and the nested subvolume, and snapshot $snap taken"
V run 'S sh /tmp/guest.sh after 2>&1' 300 >/dev/null
ok "the root was changed and every subvolume written to again after the snapshot"

# ---- the rollback
echo "     rolling back to snapshot $snap (nisse-rollback run $snap --reboot)"
# started in the guest in the background and not waited for: when it works the machine restarts at once and takes the console with it
V run "(S sh /tmp/guest.sh rollback $snap > /dev/null 2>&1 &); echo \"RES: started\"" 60 >/dev/null
guest_reboots 300 && ok "the guest restarted by itself after the rollback" || { bad "no restart after the rollback"; exit 1; }
refresh_checks
want root-change gone "the change made to the root after the snapshot is gone"
want root-subvol "subvol=/root" "the machine runs on the normal root, restored"
want home-before "home-before,home-after" "home: the file from before the snapshot, with what was added after it, is untouched"
want home-after "home-new" "home: a file made after the snapshot is still there"
want log-before "log-before,log-after" "var_log: untouched"
want log-after "log-new" "var_log: a file made after the snapshot is still there"
want cache-before "cache-before,cache-after" "var_cache: untouched"
want cache-after "cache-new" "var_cache: a file made after the snapshot is still there"
want data-mount "subvol=/e2e_data" "the data subvolume is mounted again by the restored fstab"
want data-before "data-before,data-after" "the data subvolume: the file from before the snapshot, with what was added after it, is untouched"
want data-after "data-new" "the data subvolume: a file made after the snapshot is still there"
want nested-is-subvolume yes "the nested subvolume is still a subvolume at its path (carried across, not copied)"
want nested-before "nested-before,nested-after" "the nested subvolume: its files are untouched"
want nested-after "nested-new" "the nested subvolume: a file made after the snapshot is still there"
want late-is-subvolume yes "a nested subvolume made after the snapshot, under parents the snapshot did not have, is carried across too"
want late-file late "and its file is intact"
want failed-root-nested 0 "the kept old root no longer holds the nested subvolume (it was carried, not left behind)"
want failed-root-late 0 "nor the one made after the snapshot"
want nested-left "" "nothing is recorded as left behind (nested-left is empty)"
case "$(val rollback-out)" in *"carried 2 nested subvolumes across"*) ok "nisse-rollback said what it carried: $(val rollback-out | cut -c1-160)" ;; *) bad "the rollback's output: '$(val rollback-out)'" ;; esac

# ---- the limit, shown as the limit it is
want data2-mounted no "LIMIT: a data subvolume whose fstab line was added after the snapshot is not mounted by the restored system (the line is gone with the old fstab)"
want data2-still-there "data2" "LIMIT: ...but its files are safe in the subvolume at the top level of the file system"

echo
[ "$failures" = 0 ] && echo "PASS: excluded subvolumes survive a rollback on the real machine" || { echo "$failures failed"; exit 1; }
