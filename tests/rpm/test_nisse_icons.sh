#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-icons RPM (N-409). Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-icons
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-icons-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-icons RPM not found (run tools/rpm/build-rpm.sh nisse-icons)"
files="$(rpm -qlp "$rpmf")"
for t in nisse_icons nisse_icons_dark; do
    for f in index.theme scalable/apps/preferences-system.svg scalable/apps/utilities-terminal.svg scalable/apps/org.fedoraproject.AnacondaInstaller.svg scalable/places/start-here-kde-plasma.svg; do
        printf '%s\n' "$files" | grep -qxF "/usr/share/icons/$t/$f" || fail "RPM lacks /usr/share/icons/$t/$f"
    done
    n="$(printf '%s\n' "$files" | grep -c "^/usr/share/icons/$t/.*\.svg$")"
    [ "$n" = 4 ] || fail "$t must carry exactly the four icons it overrides, found $n"
done
printf '%s\n' "$files" | grep -qx '/usr/share/icons' && fail "must not own /usr/share/icons"
rpm -qp --requires "$rpmf" | grep -q 'breeze-icon-theme' || fail "must require breeze-icon-theme (the themes it inherits)"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpmf" | (cd "$tmp" && cpio -idm --quiet)
grep -qx 'Inherits=breeze' "$tmp/usr/share/icons/nisse_icons/index.theme" || fail "nisse_icons must inherit breeze"
grep -qx 'Inherits=breeze-dark' "$tmp/usr/share/icons/nisse_icons_dark/index.theme" || fail "nisse_icons_dark must inherit breeze-dark"
grep -q 'color:#1b2330' "$tmp/usr/share/icons/nisse_icons/scalable/places/start-here-kde-plasma.svg" || fail "the light start icon must default to Ink"
grep -q 'color:#f6f2e9' "$tmp/usr/share/icons/nisse_icons_dark/scalable/places/start-here-kde-plasma.svg" || fail "the dark start icon must default to Paper"
out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-icons"
