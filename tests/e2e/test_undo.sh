#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-311: undo from the panel's side, on an installed nisse disk with the REAL btrfs, snapper, dnf, sudo, systemd and GRUB and the
# REAL nisse daemon on the session bus: a package install (a real dnf transaction, which the dnf hook wraps in a snapshot pair) is
# listed by ListUndo, undone by Undo (nisse-rollback through sudo -A, then the machine restarts), and the packages are back as they
# were; then an older change, the FIRST install of the probe package, is undone too, and the package is gone. The panel's own look
# is the ctest of panel/tests/tst_undo.qml; this is everything under it.
# About 35 minutes (two real restarts). Runs on the Windows host (QEMU with WHPX), from Git Bash. Needs the installed disk of the
# N-303 harness and the RPMs built in the build VM (nisse-update 0.1-4, nisse-boot, nisse-snapshots, nisse-sudo 0.1-3, nisse-daemon
# 0.1-23):
#   bash tests/e2e/test_install_to_disk.sh                   (once per ISO: makes out/install/run/target.qcow2)
#   in the build VM: tools/rpm/build-rpm.sh nisse-update ; nisse-boot ; nisse-snapshots ; nisse-sudo ; nisse-daemon
#   bash tests/e2e/test_undo.sh
# The installed disk is never written (a disposable overlay in a LOCAL temp folder). The files go to the guest over a small HTTP
# server on the host (the guest reaches the host at 10.0.2.2): the serial console moves about 100 KB a minute. A guest reboot hangs
# this QEMU setup, so when the guest restarts by itself the harness sees the kernel say so and power-cycles.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

port=24698
httpport=24699
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
[ -f "$disk" ] && [ -f "$vars" ] || { echo "FAIL: no installed disk (run tests/e2e/test_install_to_disk.sh first)"; exit 2; }
work="$(cygpath -m "$(mktemp -d)")"
case "$work" in //* | [T-Zt-z]:*) echo "FAIL: the work folder $work looks like a network drive: the machine would crawl"; exit 2 ;; esac
pulled=out/install/undo-e2e
mkdir -p "$pulled"
V() { python tools/vm/vmserver.py call "$port" "$@"; }
g() { V run "$1" "${2:-120}" | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
login() { bash tools/vm/vmlogin.sh "$port" >/dev/null; }
boot() { V run 'S sync' 60 >/dev/null 2>&1; V powercycle >/dev/null; V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the power-cycle"; V shot "$work/nologin.png" >/dev/null; exit 1; }; login; }
guest_reboots() {
    V expect "Restarting system" "$1" >/dev/null || { echo "FAIL: the guest never started its own reboot within $1 s"; return 1; }
    V powercycle >/dev/null
    V expect "login:" 420 >/dev/null || { echo "FAIL: no login prompt after the guest's own reboot"; V shot "$work/nologin.png" >/dev/null; exit 1; }
    login
}
probe() { g 'echo "RES: $(cat /usr/share/nisse-e2e/version 2>/dev/null || echo none)"' 30; }
state_of() { g "echo \"RES: \$(sed -n 's/^$1=//p' /var/lib/nisse/update/state 2>/dev/null)\"" 30; }
which_root() { g 'echo "RES: $(findmnt -no OPTIONS / | grep -o "subvol=[^,]*")"' 30; }
# the daemon's answers, as JSON on one line (busctl prints {"type":"as","data":[[...]]} / {"type":"s","data":["..."]})
dbus() { g "echo \"RES: \$(busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 $1 2>&1 | tr -d '\\n')\"" "${2:-90}"; }
# the entries of ListUndo, one 'id kind bootable' per line, newest first
entries() {
    V run 'busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 ListUndo > /tmp/undo.json 2>&1; python3 -c "import json;d=json.load(open(\"/tmp/undo.json\"));print(\"RES: \"+\"|\".join(\"%d %s %s\"%(e[\"id\"],e[\"kind\"],e[\"bootable\"]) for e in map(json.loads,d[\"data\"][0])))"' 90 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1
}
# Starts Undo in the guest and does NOT wait for the reply: when it works the machine restarts within a second and takes the console
# (and the reply) with it. What it said is left in /tmp/undo.out for the failure message.
undo_now() {
    V run "rm -f /tmp/undo.out; (busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 Undo ts $1 desktop > /tmp/undo.out 2>&1 &); echo \"RES: started\"" 60 >/dev/null
}
why_no_restart() { V run 'echo "RES: $(cat /tmp/undo.out 2>&1 | head -c 300)"' 60 2>/dev/null | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
cleanup() { V quit >/dev/null 2>&1; [ -n "${httppid:-}" ] && kill "$httppid" 2>/dev/null; sleep 2; rm -rf "$work"; }
trap cleanup EXIT

# ---- the packages and the probe repositories (built in the build VM)
for p in nisse-update nisse-boot nisse-snapshots nisse-sudo nisse-daemon; do
    rpmname="$(bash tools/build/vm.sh ssh "ls -v ~/nisse/out/rpmbuild/RPMS/*/$p-[0-9]*.rpm | tail -1" < /dev/null 2>/dev/null | tr -d '\r' | tail -1)"
    [ -n "$rpmname" ] || { echo "FAIL: no $p RPM in the build VM"; exit 2; }
    rm -f "$pulled"/"$p"-[0-9]*.rpm
    bash tools/build/vm.sh pull "${rpmname#/home/builder/nisse/}" "$pulled/" >/dev/null 2>&1
    ls "$pulled"/"$p"-[0-9]*.rpm >/dev/null 2>&1 || { echo "FAIL: could not pull $p"; exit 2; }
    cp "$(ls "$pulled"/"$p"-[0-9]*.rpm | tail -1)" "$pulled/$p.rpm"
done
bash tools/build/vm.sh ssh 'cd ~/nisse && bash tests/e2e/data/make_probe_repos.sh' < /dev/null >/dev/null 2>&1
rm -f "$pulled/probe-repos.tgz"
bash tools/build/vm.sh pull out/e2e/probe-repos.tgz "$pulled/" >/dev/null 2>&1
[ -s "$pulled/probe-repos.tgz" ] || { echo "FAIL: could not build the probe repositories"; exit 2; }
case "$(ls "$pulled"/nisse-update-[0-9]*.rpm | tail -1)" in *"-0.1-"[4-9]* | *"-0.2-"*) ;; *) echo "FAIL: the nisse-update RPM is older than 0.1-4 (no rollback list in it)"; exit 2 ;; esac
python -m http.server "$httpport" --bind 127.0.0.1 --directory "$pulled" > "$work/http.log" 2>&1 &
httppid=$!

# ---- the machine
python tools/vm/vmserver.py serve --disk "$disk" --vars "$vars" --work "$work/vm" --port "$port" > "$work/server.log" 2>&1 &
sleep 8
V expect "login:" 420 >/dev/null || { echo "FAIL: the installed disk did not reach a login"; exit 1; }
login
ok "the installed disk booted to a login (on a throwaway overlay)"
fetch() { V run "curl -fsS -o /tmp/$1 http://10.0.2.2:$httpport/$1 && echo \"RES: got \$(stat -c %s /tmp/$1)\"" 300 | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
for f in nisse-snapshots.rpm nisse-boot.rpm nisse-update.rpm nisse-sudo.rpm nisse-daemon.rpm probe-repos.tgz; do
    case "$(fetch "$f")" in "got "[1-9]*) ;; *) bad "the guest could not fetch $f from the host over HTTP"; exit 1 ;; esac
done
ok "the guest fetched the RPMs from the host over HTTP (fast, where the serial console would take an hour)"
out="$(V run 'S dnf install -y --disablerepo=updates /tmp/nisse-snapshots.rpm /tmp/nisse-boot.rpm /tmp/nisse-update.rpm /tmp/nisse-sudo.rpm /tmp/nisse-daemon.rpm 2>&1 | tail -2; echo "RES: $(rpm -q nisse-update nisse-sudo nisse-daemon | tr "\n" " ")"' 1800)"
case "$out" in *"RES: nisse-update-"*"nisse-sudo-"*"nisse-daemon-"*) ok "the five packages install on the installed system" ;; *) bad "install failed: $(echo "$out" | tail -4)"; exit 1 ;; esac
V run 'S systemctl start nisse-snapshot-setup.service; S systemctl start nisse-boot-setup.service; S mkdir -p /var/lib/e2e; S tar -C /var/lib/e2e -xzf /tmp/probe-repos.tgz' 300 >/dev/null
[ "$(g 'echo "RES: $(sudo -n true 2>&1 && echo passwordless)"' 30)" = passwordless ] && ok "sudo -n works for the person (nisse-sudo full mode)" || bad "sudo -n asks for a password: the daemon could not run the tool"
[ "$(g 'echo "RES: $(test -f /etc/snapper/configs/root && echo yes)"' 30)" = yes ] && ok "the snapper root config exists" || bad "no snapper root config"

# ---- two real package changes, each wrapped in a snapshot pair by the dnf hook
V run 'S dnf install -y --disablerepo=updates /var/lib/e2e/probe-1.0.rpm >/dev/null 2>&1; sleep 4; S dnf install -y --disablerepo=updates /var/lib/e2e/repo-good/nisse-e2e-probe-2.0-1.noarch.rpm >/dev/null 2>&1; sleep 4' 600 >/dev/null
[ "$(probe)" = 2.0 ] && ok "the probe package is installed (1.0, then upgraded to 2.0 by two real dnf transactions)" || { bad "probe is $(probe)"; exit 1; }

# ---- the real list, as nisse-rollback prints it
real="$(V run 'S nisse-rollback list; echo "RES: rc=$?"' 120 | tr -d '\r')"
echo "$real" | grep -E '^[0-9]+;' > "$pulled/real_list.txt"
[ -s "$pulled/real_list.txt" ] && ok "nisse-rollback list printed $(wc -l < "$pulled/real_list.txt") rows with the real snapper" || bad "nisse-rollback list printed nothing: $real"
awk -F';' 'NF != 6 { bad = 1 } END { exit bad }' "$pulled/real_list.txt" && ok "every row has six fields" || bad "a row without six fields: $(awk -F';' 'NF != 6' "$pulled/real_list.txt" | head -2)"
now="$(g 'echo "RES: $(date +%s)"' 30)"
awk -F';' -v now="$now" '$4 < now - 7200 || $4 > now + 600 { bad = 1 } END { exit bad }' "$pulled/real_list.txt" && ok "the times are real epoch seconds from the last two hours (snapper's own date column was read right)" || bad "a time out of range: $(cat "$pulled/real_list.txt" | head -3) now=$now"
grep -q 'package-transaction' "$pulled/real_list.txt" && ok "the dnf hook's pairs are in it (nisse=package-transaction)" || bad "no package-transaction rows: $(head -3 "$pulled/real_list.txt")"
[ -z "$(grep ';no:' "$pulled/real_list.txt")" ] && ok "every snapshot is bootable (its kernel is in /boot)" || bad "a snapshot is not bootable: $(grep ';no:' "$pulled/real_list.txt" | head -1)"

# ---- the daemon, started by D-Bus activation, lists the changes
ent="$(entries)"
echo "     (ListUndo: $ent)"
case "$ent" in *" package True"*"|"*" package True"*) ok "ListUndo through the real daemon: the package changes, newest first, bootable ($ent)" ;; *) bad "ListUndo: '$ent'" ;; esac
newest="${ent%% *}"
older="$(printf '%s' "$ent" | tr '|' '\n' | grep ' package ' | tail -1 | cut -d' ' -f1)"
[ -n "$newest" ] && [ -n "$older" ] && [ "$newest" != "$older" ] && ok "two different changes: the upgrade to 2.0 ($newest) and an older one ($older)" || bad "could not tell two changes apart: newest=$newest older=$older"

# ---- Undo refuses what it should, in words
r="$(dbus 'Undo ts 99999 desktop')"
case "$r" in *"not a change"*) ok "Undo of a number that is not in the list is refused in words" ;; *) bad "Undo 99999: $r" ;; esac
r="$(dbus 'Undo ts '"$newest"' ""')"
case "$r" in *"by must name"*) ok "Undo with nobody named is refused" ;; *) bad "Undo with no 'by': $r" ;; esac
[ "$(probe)" = 2.0 ] && ok "nothing was changed by the refusals" || bad "a refusal changed the system: probe is $(probe)"

# ---- undo the upgrade: the machine restarts and the package is back at 1.0
undo_now "$newest"
echo "     waiting for the restart the daemon asked for (sudo -A nisse-rollback run $newest --reboot)"
guest_reboots 300 && ok "Undo $newest: the daemon ran the rollback through sudo -A and the guest restarted by itself" || { bad "no restart after Undo $newest: $(why_no_restart)"; exit 1; }
[ "$(probe)" = 1.0 ] && ok "the upgrade is undone: the probe package is back at 1.0" || bad "after the undo the probe is $(probe), expected 1.0"
[ "$(which_root)" = "subvol=/root" ] && ok "it runs on the normal root (not a snapshot)" || bad "root is $(which_root)"
[ "$(state_of last)" = rolled-back ] && case "$(state_of reason)" in *"undone from the panel"*) ok "the record says why: $(state_of reason)" ;; *) bad "reason: '$(state_of reason)'" ;; esac || bad "state last=$(state_of last)"
r="$(dbus 'AuditTail u 50' 90)"
case "$r" in *'\"kind\":\"rollback\"'*"$newest"*) ok "the audit log has the rollback record (written before the restart, in home, so it survived)" ;; *) bad "no rollback audit record: $(echo "$r" | cut -c1-300)" ;; esac

# ---- now the older change: undo the FIRST install, and the package is gone altogether
ent2="$(entries)"
echo "     (ListUndo after the restart: $ent2)"
case "$ent2" in *" package True"*) ok "after the restart the list is still there (the snapshots moved with the restore)" ;; *) bad "ListUndo after the restart: '$ent2'" ;; esac
undo_now "$older"
guest_reboots 300 && ok "Undo $older (the first install): the guest restarted by itself again" || { bad "no restart after Undo $older: $(why_no_restart)"; exit 1; }
[ "$(probe)" = none ] && ok "the INSTALL is undone: the probe package is not installed any more" || bad "after undoing the install the probe is $(probe)"
[ "$(g 'echo "RES: $(rpm -q nisse-e2e-probe 2>&1 | head -1)"' 30)" = "package nisse-e2e-probe is not installed" ] && ok "rpm agrees" || bad "rpm -q: $(g 'echo "RES: $(rpm -q nisse-e2e-probe 2>&1 | head -1)"' 30)"
[ "$(g 'echo "RES: $(rpm -q nisse-daemon nisse-update >/dev/null 2>&1 && echo installed)"' 30)" = installed ] && ok "the nisse packages, installed before those snapshots, are still there" || bad "the nisse packages are gone"
[ "$(which_root)" = "subvol=/root" ] && [ "$(g 'echo "RES: $(S touch /e2e-write-test 2>&1 && echo writable || echo read-only)"; S rm -f /e2e-write-test' 30)" = writable ] && ok "the restored root is writable" || bad "root after the second undo: $(which_root)"

echo
[ "$failures" = 0 ] && echo "PASS: undo from the daemon on the real machine" || { echo "$failures failed"; exit 1; }
