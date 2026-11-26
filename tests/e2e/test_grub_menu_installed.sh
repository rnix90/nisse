#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-502: the themed GRUB menu on an installed nisse disk. With the nisse-grub-theme, nisse-boot and nisse-snapshots packages installed:
# grub.cfg carries the theme and the replaced kernel list; the menu on the screen is the approved one (nisse, Start from Earlier
# Snapshots, Computer Settings, More Ways to Start; judged by tools/vm/grub_check.py); the first row boots; the hotkey m opens More Ways
# to Start, whose first row boots an older kernel entry; and without nisse's kernel file the stock Fedora list is still there.
# About 10 minutes (every step is a real boot). Runs on the Windows host (QEMU with WHPX), from Git Bash. Needs the installed disk of
# the N-303 harness and the three RPMs built in the build VM:
#   bash tests/e2e/test_install_to_disk.sh                   (once per ISO: makes out/install/run/target.qcow2)
#   in the build VM: tools/rpm/build-rpm.sh nisse-boot ; nisse-snapshots ; nisse-grub-theme
#   bash tests/e2e/test_grub_menu_installed.sh
# The installed disk is never written: the machine runs on a disposable overlay (tools/vm/vmserver.py).
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

port=24701
disk=out/install/run/target.qcow2
vars=out/install/run/install/OVMF_VARS.fd
[ -f "$disk" ] && [ -f "$vars" ] || { echo "FAIL: no installed disk (run tests/e2e/test_install_to_disk.sh first)"; exit 2; }
work="$(cygpath -m "$(mktemp -d)")"
pulled=out/install/menu-e2e
mkdir -p "$pulled"
V() { python tools/vm/vmserver.py call "$port" "$@"; }
g() { V run "$1" "${2:-120}" | tr -d '\r' | sed -n 's/^RES: //p' | tail -1; }
login() { bash tools/vm/vmlogin.sh "$port" >/dev/null; }
cleanup() { V quit >/dev/null 2>&1; sleep 2; rm -rf "$work"; }
trap cleanup EXIT
# a GRUB menu on the screen: start the machine again with the menu forced to show, wait for the firmware to hand over, stop the countdown
start_menu() {
    V run 'S grub2-editenv - set menu_show_once=1; S sync' 30 >/dev/null
    V serial >/dev/null
    V powercycle >/dev/null
    sleep 3.2
}
show_menu() { start_menu; V key up; sleep 1.5; }
boot_to_login() { V expect "login:" 420 >/dev/null || return 1; login; }

for p in nisse-boot nisse-snapshots nisse-grub-theme; do
    rpmname="$(bash tools/build/vm.sh ssh "ls -v ~/nisse/out/rpmbuild/RPMS/noarch/$p-[0-9]*.rpm | tail -1" < /dev/null 2>/dev/null | tr -d '\r' | tail -1)"
    [ -n "$rpmname" ] || { echo "FAIL: no $p RPM in the build VM"; exit 2; }
    rm -f "$pulled"/"$p"-[0-9]*.rpm
    bash tools/build/vm.sh pull "${rpmname#/home/builder/nisse/}" "$pulled/" >/dev/null 2>&1
    ls "$pulled"/"$p"-[0-9]*.rpm >/dev/null 2>&1 || { echo "FAIL: could not pull $p"; exit 2; }
done

python tools/vm/vmserver.py serve --disk "$disk" --vars "$vars" --work "$work/vm" --port "$port" > "$work/server.log" 2>&1 &
sleep 8
boot_to_login || { echo "FAIL: the installed disk did not reach a login"; exit 1; }
ok "the installed disk booted to a login (on a throwaway overlay)"

# the RPMs go in over the guest's network (the host is 10.0.2.2 to it): the serial console takes minutes for a megabyte
python -m http.server 8765 --bind 127.0.0.1 --directory "$pulled" > "$work/http.log" 2>&1 &
httppid=$!
trap 'kill $httppid 2>/dev/null; cleanup' EXIT
for p in nisse-boot nisse-snapshots nisse-grub-theme; do
    f="$(basename "$(ls "$pulled"/"$p"-[0-9]*.rpm | head -1)")"
    got="$(g "S curl -sf -o /tmp/$p.rpm http://10.0.2.2:8765/$f && echo \"RES: \$(wc -c < /tmp/$p.rpm)\"" 120)"
    [ "${got:-0}" -gt 1000 ] 2>/dev/null || { echo "FAIL: could not fetch $p into the guest ($got)"; exit 1; }
done
out="$(V run 'S dnf install -y --disablerepo=updates /tmp/nisse-snapshots.rpm /tmp/nisse-boot.rpm /tmp/nisse-grub-theme.rpm 2>&1 | tail -3; echo "RES: $(rpm -q nisse-boot nisse-snapshots nisse-grub-theme | tr "\n" " ")"' 240)"
case "$out" in *"RES: nisse-boot-"*"nisse-snapshots-"*"nisse-grub-theme-"*) ok "the three packages install on the installed system" ;; *) bad "install failed: $(echo "$out" | tail -5)"; exit 1 ;; esac

# ---- the files: an older kernel is faked with a second BootLoaderSpec file (same kernel files, a marker option), then grub.cfg is made
g 'S systemctl start nisse-boot-setup.service; echo "RES: ok"' 120 >/dev/null
cat > "$work/fake-older.sh" <<'FAKE'
f="$(ls /boot/loader/entries/*.conf | grep -v rescue | head -1)"
sed -e 's/^version .*/version 6.18.2-100.fc44.x86_64/' -e 's/^options .*/& nisse_e2e_older=1/' "$f" > "${f%.conf}-older.conf"
FAKE
V put /tmp/fake-older.sh "$work/fake-older.sh" >/dev/null
# grub2-mkconfig rewrites the options of every BootLoaderSpec file (docs/boot-recovery.md), so the faked entry's marker goes in after it
V run 'S grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tail -3' 180 >/dev/null
# grub2-mkconfig rewrote the options of the entry files while it ran: the copies must have been brought up to date in the same run
cat > "$work/compare-options.sh" <<'CMP'
b="$(ls /boot/loader/nisse-main/*.conf | head -1)"; n="$(basename "$b")"
if [ "$(grep '^options' "$b")" = "$(grep '^options' "/boot/loader/entries/$n")" ]; then echo "RES: same"; else echo "RES: differ"; fi
CMP
V put /tmp/compare-options.sh "$work/compare-options.sh" >/dev/null
[ "$(g 'S sh /tmp/compare-options.sh' 60)" = same ] && ok "the main row's options are the entry file's, as grub2-mkconfig left them (98_nisse_menu_refresh)" || bad "the main row's options differ from the entry file's after grub2-mkconfig"
V run 'S sh /tmp/fake-older.sh; S nisse-boot menu' 120 >/dev/null
[ "$(g 'echo "RES: $(S grep -c -E "nisse-menu.cfg|More Ways to Start|Computer Settings|themes/nisse/theme.txt" /boot/grub2/grub.cfg)"' 60)" -ge 4 ] 2>/dev/null \
    && ok "grub.cfg has the replaced kernel list, More Ways to Start, Computer Settings and the theme" || bad "grub.cfg lacks a part of the themed menu"
g 'echo "RES: $(S grep -c "UEFI Firmware Settings" /boot/grub2/grub.cfg)"' 60 | grep -qx 0 && ok "Fedora's own firmware row is switched off (no second row)" || bad "UEFI Firmware Settings is still in grub.cfg"
g 'echo "RES: $(test -s /boot/grub2/themes/nisse/theme.txt && test -s /boot/grub2/themes/nisse/nunito-semibold-regular-32.pf2 && echo there)"' 60 | grep -qx there && ok "the theme is on the boot partition" || bad "no theme on the boot partition"
menu="$(g 'echo "RES: $(S sh -c "head -qn1 /boot/loader/nisse-main/*.conf" | tr "\n" "|") / $(S sh -c "head -qn1 /boot/loader/nisse-more/*.conf" | tr "\n" "|")"' 60)"
case "$menu" in *"nisse|"*"Start nisse with Kernel 6.18.2-100.fc44|"*) case "$menu" in *"Start nisse in Rescue Mode"*) okrows=1 ;; *) okrows=0 ;; esac ;; *) okrows=0 ;; esac
case "$okrows" in 1) ok "the rows: nisse for the newest kernel, the faked older one and the rescue kernel under More Ways" ;; *) bad "unexpected rows: $menu" ;; esac

# ---- the screen
rows=3
g 'echo "RES: $(S test -f /boot/grub2/nisse-boot.cfg && echo yes || echo no)"' 30 | grep -qx yes && rows=4
start_menu
V shot "$work/menu.png" >/dev/null       # before any key: a key stops the countdown, and the countdown line and bar go with it
words="$(V serial | tr -d '')"
V key up >/dev/null; sleep 1
python tools/vm/grub_check.py menu --rows "$rows" "$work/menu.png" && ok "the menu on the screen is the approved one ($rows rows: judged by grub_check.py)" || bad "the menu on the screen is not the approved one (the photo is $work/menu.png)"
mkdir -p docs/screenshots && cp "$work/menu.png" docs/screenshots/n502-grub-installed.png 2>/dev/null
# the words on the serial copy of the menu: nisse's rows, not Fedora's list ("nisse (6.19.10-300.fc44.x86_64) 0.2")
case "$words" in *"nisse ("*) bad "the stock Fedora list is showing (a row titled with a kernel version), not nisse's rows" ;; *) ok "no row is titled with a kernel version" ;; esac
for want in "Start from Earlier Snapshots" "Computer Settings" "More Ways to Start"; do
    case "$words" in *"$want"*) ok "the menu has the row: $want" ;; *) bad "the menu lacks the row: $want" ;; esac
done

# ---- the first row boots; the hotkey m opens More Ways to Start and its first row boots the older entry
V key ret >/dev/null
boot_to_login || { bad "the first row (nisse) did not boot to a login"; exit 1; }
[ "$(g 'echo "RES: $(grep -c nisse_e2e_older /proc/cmdline)"' 30)" = 0 ] && ok "the first row, nisse, booted the newest kernel entry" || bad "the first row booted the older entry"
show_menu
V key m >/dev/null; sleep 1.5
V shot "$work/more.png" >/dev/null; cp "$work/more.png" docs/screenshots/n502-grub-more-ways.png 2>/dev/null
V key ret >/dev/null
boot_to_login || { bad "the More Ways row did not boot to a login"; exit 1; }
[ "$(g 'echo "RES: $(grep -c nisse_e2e_older /proc/cmdline)"' 30)" = 1 ] && ok "the hotkey m, then the first row, booted the older kernel entry" || bad "More Ways did not boot the older entry (cmdline: $(g 'echo "RES: $(cat /proc/cmdline)"' 30); its options: $(g 'echo "RES: $(S sh -c "grep -h ^options /boot/loader/nisse-more/*.conf" | tr -s " " | tr "\n" "|")"' 30))"

# ---- the fallback: without nisse's file the stock Fedora list is shown and boots
V run 'S rm -f /boot/grub2/nisse-menu.cfg /boot/grub2/nisse-more.cfg' 30 >/dev/null
show_menu
V key ret >/dev/null
boot_to_login && ok "without nisse's kernel file the stock list is there and its default row boots" || bad "no boot without nisse's kernel file"
V run 'S nisse-boot menu' 30 >/dev/null

echo
[ "$failures" = 0 ] && echo "PASS: themed GRUB menu on an installed disk" || { echo "$failures failed"; exit 1; }
