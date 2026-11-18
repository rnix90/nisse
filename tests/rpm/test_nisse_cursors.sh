#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-cursors RPM (N-408). Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-cursors
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-cursors-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-cursors RPM not found (run tools/rpm/build-rpm.sh nisse-cursors)"
files="$(rpm -qlp "$rpmf")"
for f in /usr/share/icons/nisse_cursors/index.theme /usr/share/icons/nisse_cursors/cursors/x-cursor /usr/share/icons/nisse_cursors/cursors/wayland-cursor; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "RPM lacks $f"
done
n="$(printf '%s\n' "$files" | grep -c '^/usr/share/icons/nisse_cursors/cursors/')"
[ "$n" = 2 ] || fail "the theme must carry exactly the two cursors it overrides, found $n"
printf '%s\n' "$files" | grep -qx '/usr/share/icons' && fail "must not own /usr/share/icons"
rpm -qp --requires "$rpmf" | grep -q 'breeze-cursor-theme' || fail "must require breeze-cursor-theme (the theme it inherits)"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpmf" | (cd "$tmp" && cpio -idm --quiet)
grep -qx 'Inherits=breeze_cursors' "$tmp/usr/share/icons/nisse_cursors/index.theme" || fail "index.theme must inherit breeze_cursors"
for c in x-cursor wayland-cursor; do
    [ "$(head -c 4 "$tmp/usr/share/icons/nisse_cursors/cursors/$c")" = "Xcur" ] || fail "$c is not an Xcursor file"
done
out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-cursors"
