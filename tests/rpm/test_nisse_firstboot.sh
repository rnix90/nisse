#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-firstboot RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-firstboot
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls out/rpmbuild/RPMS/noarch/nisse-firstboot-[0-9]*.rpm 2>/dev/null | head -1 || true)"
[ -n "$rpmf" ] || fail "nisse-firstboot RPM not found (run tools/rpm/build-rpm.sh nisse-firstboot)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-fetch-claude /usr/lib/systemd/user/nisse-fetch-claude.service \
         /usr/lib/systemd/user-preset/81-nisse-firstboot.preset; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "RPM lacks $f"
done
member usr/lib/systemd/user-preset/81-nisse-firstboot.preset | grep -qx 'enable nisse-fetch-claude.service' || fail "preset must enable nisse-fetch-claude.service for users"
rpm -qp --requires "$rpmf" | grep -qx 'curl' || fail "RPM must require curl"
printf '%s\n' "$files" | grep -qE '(^|/)claude$' && fail "Claude Code itself must not be in this package"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-firstboot"
