#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-503: the nisse login screen on an installed disk. With the built nisse-lookandfeel package installed, Plasma Login Manager's greeter shows
# the nisse wallpaper (not Fedora's cityscape): idle (nobody has touched a key) and awake (the greeter blurs the wallpaper); both screenshots
# are judged by tools/vm/login_check.py. About 5 minutes (a real boot). Runs on the Windows host (QEMU with WHPX), from Git Bash. Needs the
# installed disk of the N-303 harness and the RPM built in the build VM:
#   bash tests/e2e/test_install_to_disk.sh                   (once per ISO: makes out/install/run/target.qcow2)
#   in the build VM: tools/rpm/build-rpm.sh nisse-lookandfeel
#   bash tests/e2e/test_login_screen.sh
# The installed disk is never written: the machine runs on a disposable overlay (tools/vm/vmserver.py).
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

port=24704
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
[ -f "$disk" ] && [ -f "$vars" ] || { echo "FAIL: no installed disk (run tests/e2e/test_install_to_disk.sh first)"; exit 2; }
work="$(cygpath -m "$(mktemp -d)")"
pulled=out/install/login-e2e
mkdir -p "$pulled"
V() { python tools/vm/vmserver.py call "$port" "$@"; }
g() { V run "$1" "${2:-120}" | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
cleanup() { V quit >/dev/null 2>&1; sleep 2; rm -rf "$work"; }
trap cleanup EXIT

rpmname="$(bash tools/build/vm.sh ssh "ls -v ~/nisse/out/rpmbuild/RPMS/noarch/nisse-lookandfeel-[0-9]*.rpm | tail -1" < /dev/null 2>/dev/null | tr -d '\r' | tail -1)"
[ -n "$rpmname" ] || { echo "FAIL: no nisse-lookandfeel RPM in the build VM"; exit 2; }
rm -f "$pulled"/nisse-lookandfeel-[0-9]*.rpm
bash tools/build/vm.sh pull "${rpmname#/home/builder/nisse/}" "$pulled/" >/dev/null 2>&1
ls "$pulled"/nisse-lookandfeel-[0-9]*.rpm >/dev/null 2>&1 || { echo "FAIL: could not pull the RPM"; exit 2; }

python tools/vm/vmserver.py serve --disk "$disk" --vars "$vars" --work "$work/vm" --port "$port" > "$work/server.log" 2>&1 &
sleep 8
V expect "login:" 420 >/dev/null || { echo "FAIL: the installed disk did not reach a login"; exit 1; }
bash tools/vm/vmlogin.sh "$port" >/dev/null || { echo "FAIL: could not log in on the serial console"; exit 1; }
ok "the installed disk booted (on a throwaway overlay)"

# the stock greeter first: Fedora's picture, so the check is shown to be able to say no on a real boot
sleep 20
V shot "$work/before-idle.png" >/dev/null
if python tools/vm/login_check.py --idle "$work/before-idle.png" >/dev/null; then
    ok "(note) this disk's greeter already passed before the package; the disk may carry an older nisse-lookandfeel"
else
    ok "before the package the greeter is refused (Fedora's cityscape): the check can say no on a real boot"
fi

python -m http.server 8766 --bind 127.0.0.1 --directory "$pulled" > "$work/http.log" 2>&1 &
httppid=$!
trap 'kill $httppid 2>/dev/null; cleanup' EXIT
f="$(basename "$(ls "$pulled"/nisse-lookandfeel-[0-9]*.rpm | head -1)")"
got="$(g "S curl -sf -o /tmp/laf.rpm http://10.0.2.2:8766/$f && echo \"RES: \$(wc -c < /tmp/laf.rpm)\"" 120)"
[ "${got:-0}" -gt 1000 ] 2>/dev/null || { echo "FAIL: could not fetch the package into the guest ($got)"; exit 1; }
out="$(V run 'S dnf install -y --disablerepo=updates /tmp/laf.rpm 2>&1 | tail -3; echo "RES: $(rpm -q nisse-lookandfeel)"' 180 | tr -d '\r')"
want="$(basename "$f" .noarch.rpm)"
case "$out" in *"RES: $want"*) ok "the package installs on the installed system ($want)" ;; *) bad "install failed: $(echo "$out" | tail -4)"; exit 1 ;; esac
[ "$(g 'rpm -q kde-settings-plasmalogin >/dev/null 2>&1 && echo "RES: still" || echo "RES: replaced"' 30)" = "replaced" ] && ok "Fedora's kde-settings-plasmalogin was replaced (same file, no collision)" || bad "kde-settings-plasmalogin is still installed"
[ "$(g 'test -f /usr/lib/plasmalogin/defaults.conf && echo "RES: there"' 30)" = "there" ] && ok "/usr/lib/plasmalogin/defaults.conf is on the disk" || bad "no defaults.conf"
[ "$(g 'echo "RES: $(grep -c wallpapers/nisse /usr/lib/plasmalogin/defaults.conf)"' 30)" -ge 2 ] 2>/dev/null && ok "it names the nisse wallpaper" || bad "defaults.conf does not name the nisse wallpaper"

# a new greeter: restart the display manager (the greeter and its wallpaper start again), then look at the screen untouched
V run 'S systemctl restart plasmalogin; echo "RES: restarted"' 60 >/dev/null
sleep 30
V shot "$work/idle.png" >/dev/null
python tools/vm/login_check.py --idle "$work/idle.png" && ok "the idle login screen shows the nisse wallpaper" || bad "the idle login screen is not the nisse one"
V key shift >/dev/null
sleep 4
V shot "$work/awake.png" >/dev/null
python tools/vm/login_check.py --awake "$work/awake.png" && ok "the awake login screen (wallpaper blurred) is the nisse one" || bad "the awake login screen is not the nisse one"
mkdir -p out/install/login-e2e/shots && cp "$work"/idle.png "$work"/awake.png out/install/login-e2e/shots/ 2>/dev/null

echo
[ "$failures" = 0 ] && echo "PASS: login screen on an installed disk" || { echo "FAIL: $failures check(s)"; exit 1; }
