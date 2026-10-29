#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-daemon RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-daemon
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls out/rpmbuild/RPMS/x86_64/nisse-daemon-[0-9]*.rpm 2>/dev/null | head -1 || true)"
[ -n "$rpmf" ] || fail "nisse-daemon RPM not found (run tools/rpm/build-rpm.sh nisse-daemon)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-daemon /usr/bin/nisse-audit-hook /usr/lib/systemd/user/nisse-daemon.service \
         /usr/share/dbus-1/services/org.nisse.Daemon1.service /usr/share/nisse/claude-settings.json; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "RPM lacks $f"
done

member usr/share/nisse/claude-settings.json | grep -q '/usr/bin/nisse-audit-hook' || fail "settings must register nisse-audit-hook"
member usr/share/dbus-1/services/org.nisse.Daemon1.service | grep -qx 'SystemdService=nisse-daemon.service' || fail "D-Bus service must activate the user unit"
member usr/lib/systemd/user/nisse-daemon.service | grep -qx 'BusName=org.nisse.Daemon1' || fail "unit must claim org.nisse.Daemon1"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-daemon"
