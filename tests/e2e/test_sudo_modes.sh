#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306a: the nisse-sudo package with the REAL sudo, for a wheel user with no terminal (like an AI session's shell).
# Run in the Fedora build VM (needs sudo, useradd) after:
#   tools/rpm/build-rpm.sh nisse-sudo && tools/rpm/build-rpm.sh nisse-snapshots
# The build VM's own user keeps its passwordless sudo through a later drop-in, so this cannot lock the VM.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

pkg() { ls -v out/rpmbuild/RPMS/noarch/"$1"-[0-9]*.rpm 2>/dev/null | tail -1; }
sudo_rpm="$(pkg nisse-sudo)"; snap_rpm="$(pkg nisse-snapshots)"
[ -n "$sudo_rpm" ] && [ -n "$snap_rpm" ] || { echo "FAIL: build nisse-sudo and nisse-snapshots first"; exit 1; }

u=nisseprobe
work="$(mktemp -d)"
cleanup() {
    sudo userdel -r "$u" >/dev/null 2>&1
    sudo dnf remove -y nisse-sudo nisse-snapshots >/dev/null 2>&1
    sudo rm -f /etc/sudoers.d/50-nisse-sudo
    rm -rf "$work"
}
trap cleanup EXIT
chmod 777 "$work"

sudo dnf install -y "$sudo_rpm" "$snap_rpm" >/dev/null 2>&1 && ok "nisse-sudo and nisse-snapshots install" || { bad "install failed"; exit 1; }
sudo useradd -m -G wheel "$u" && echo "$u:probe-pass-1" | sudo chpasswd || { echo "FAIL: cannot make the test user"; exit 1; }

# stand-ins for kdialog: answer, wrong answer, cancel; each logs that it was asked
printf '#!/bin/sh\necho asked >> "%s/asked"\necho probe-pass-1\n' "$work" > "$work/kdialog-ok"
printf '#!/bin/sh\necho asked >> "%s/asked"\necho wrong\n' "$work" > "$work/kdialog-bad"
printf '#!/bin/sh\necho asked >> "%s/asked"\nexit 1\n' "$work" > "$work/kdialog-cancel"
chmod 755 "$work"/kdialog-*
asked() { if [ -f "$work/asked" ]; then wc -l < "$work/asked"; else echo 0; fi; }
forget() { sudo -u "$u" sudo -k 2>/dev/null; rm -f "$work/asked"; }
# run as the probe user with no terminal; the shim directory first on PATH, as for a session the daemon starts
as() { sudo -u "$u" env -i PATH=/usr/libexec/nisse/shims:/usr/bin:/usr/sbin HOME="/home/$u" "$@" < /dev/null; }
rc() { "$@" >/dev/null 2>&1; echo "$?"; }

sudo visudo -c >/dev/null 2>&1 && ok "the whole sudoers configuration is valid with the package installed" || bad "visudo -c fails"

# ---- full mode (the default)
[ "$(sudo nisse-sudo-mode status)" = full ] && ok "the installed default is full" || bad "default mode is $(sudo nisse-sudo-mode status)"
[ "$(rc as sudo -n true)" = 0 ] && ok "full: a wheel user runs sudo with no password" || bad "full: sudo -n true failed"
[ "$(rc as sudo -n /usr/libexec/nisse/nisse-snapshot-batch pre 'bad;id')" = 2 ] && ok "full: the snapshot helper is reachable (it answers 2 for a bad session id)" || bad "full: helper not reachable through sudo"

# ---- limited mode
sudo nisse-sudo-mode limited >/dev/null 2>&1 && [ "$(sudo nisse-sudo-mode status)" = limited ] && ok "switched to limited" || bad "cannot switch to limited"
sudo visudo -c >/dev/null 2>&1 && ok "limited: the whole sudoers configuration is valid" || bad "limited: visudo -c fails"
[ "$(rc as sudo -n true)" != 0 ] && ok "limited: an ordinary command needs a password (sudo -n fails)" || bad "limited: sudo -n true still works"
[ "$(rc as sudo -n /usr/libexec/nisse/nisse-snapshot-batch pre 'bad;id')" = 2 ] && ok "limited: the snapshot helper is still passwordless" || bad "limited: the snapshot helper now needs a password"

forget
[ "$(rc as env NISSE_KDIALOG="$work/kdialog-ok" SUDO_ASKPASS=/usr/libexec/nisse/nisse-askpass /usr/bin/sudo true)" != 0 ] && ok "limited: the real sudo with no -A and no terminal fails (so the shim is what adds -A)" || bad "limited: sudo without -A worked with no terminal"
forget
[ "$(rc as env NISSE_KDIALOG="$work/kdialog-ok" sudo true)" = 0 ] && ok "limited: through the shim, a sudo with no terminal asks the popup and succeeds" || bad "limited: shim + popup did not give sudo"
[ "$(asked)" = 1 ] && ok "limited: the popup was shown once" || bad "limited: popup shown $(asked) times"
[ "$(rc as env NISSE_KDIALOG="$work/kdialog-ok" sudo true)" = 0 ] && [ "$(asked)" = 1 ] && ok "limited: the answer is remembered, the next sudo does not ask again" || bad "limited: asked again (popups: $(asked))"
[ "$(rc as sudo -n true)" = 0 ] && ok "limited: the remembered answer also serves sudo -n from the same user" || bad "limited: not remembered for sudo -n"
forget
[ "$(rc as env NISSE_KDIALOG="$work/kdialog-bad" sudo true)" != 0 ] && ok "limited: a wrong password fails" || bad "limited: a wrong password gave sudo"
forget
[ "$(rc as env NISSE_KDIALOG="$work/kdialog-cancel" sudo true)" != 0 ] && [ "$(asked)" = 1 ] && ok "limited: a cancelled popup fails and is not asked again" || bad "limited: cancel rc/asked wrong (asked $(asked))"
forget
[ "$(rc as env NISSE_KDIALOG="$work/kdialog-ok" sudo -n true)" != 0 ] && [ "$(asked)" = 0 ] && ok "limited: sudo -n never opens a popup" || bad "limited: sudo -n opened a popup or succeeded"

# ---- back to full
sudo nisse-sudo-mode full >/dev/null 2>&1 && ok "switched back to full" || bad "cannot switch back"
forget
[ "$(rc as sudo -n true)" = 0 ] && [ "$(asked)" = 0 ] && ok "full again: no password, no popup" || bad "full again: sudo -n true failed"
sudo visudo -c >/dev/null 2>&1 && ok "full again: the sudoers configuration is valid" || bad "full again: visudo -c fails"

echo
[ "$failures" = 0 ] && echo "PASS: nisse sudo modes with the real sudo" || { echo "$failures failed"; exit 1; }
