#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-panel RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-panel
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls out/rpmbuild/RPMS/x86_64/nisse-panel-[0-9]*.rpm 2>/dev/null | head -1 || true)"
[ -n "$rpmf" ] || fail "nisse-panel RPM not found (run tools/rpm/build-rpm.sh nisse-panel)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-panel /usr/share/applications/nisse-panel.desktop; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "RPM lacks $f"
done
printf '%s\n' "$files" | grep -q 'tst_chat' && fail "the test executable must not be installed"

member usr/share/applications/nisse-panel.desktop | grep -qx 'Icon=distributor-logo-nisse' || fail "desktop file must use the Nisse icon"
rpm -qp --requires "$rpmf" | grep -q '^nisse-daemon' || fail "RPM must require nisse-daemon"
rpm -qp --requires "$rpmf" | grep -q 'qt6-qtdeclarative' || fail "RPM must require qt6-qtdeclarative (QML runtime)"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
member usr/share/applications/nisse-panel.desktop > "$tmp/nisse-panel.desktop"
desktop-file-validate "$tmp/nisse-panel.desktop" || fail "desktop-file-validate rejected the desktop file"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-panel"
