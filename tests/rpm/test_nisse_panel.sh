#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-panel RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-panel
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/x86_64/nisse-panel-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-panel RPM not found (run tools/rpm/build-rpm.sh nisse-panel)"
# Extract the whole payload once and read members from disk: identical files can be stored as a hardlink set, where the
# first cpio entry is empty, so extracting one member by name can return nothing.
root_dir="$(mktemp -d)"
rpm2cpio "$rpmf" | (cd "$root_dir" && cpio -idm --quiet 2>/dev/null)
member() { cat "$root_dir/$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-panel /usr/share/applications/nisse-panel.desktop; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "RPM lacks $f"
done
printf '%s\n' "$files" | grep -q 'tst_chat' && fail "the test executable must not be installed"

member usr/share/applications/nisse-panel.desktop | grep -qx 'Icon=distributor-logo-nisse' || fail "desktop file must use the nisse icon"
rpm -qp --requires "$rpmf" | grep -q '^nisse-daemon' || fail "RPM must require nisse-daemon"
rpm -qp --requires "$rpmf" | grep -q 'qt6-qtdeclarative' || fail "RPM must require qt6-qtdeclarative (QML runtime)"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp" "$root_dir"' EXIT
member usr/share/applications/nisse-panel.desktop > "$tmp/nisse-panel.desktop"
desktop-file-validate "$tmp/nisse-panel.desktop" || fail "desktop-file-validate rejected the desktop file"

# Meta+N opens or focuses the panel (approved defaults, ledger N-110/N-111). KDE takes an app's default global shortcut
# from X-KDE-Shortcuts in a desktop file under /usr/share/kglobalaccel, the way Konsole ships Ctrl+Alt+T.
grep -qx 'X-KDE-Shortcuts=Meta+N' "$tmp/nisse-panel.desktop" || fail "the desktop file must carry X-KDE-Shortcuts=Meta+N"
printf '%s\n' "$files" | grep -qxF /usr/share/kglobalaccel/nisse-panel.desktop || fail "RPM lacks /usr/share/kglobalaccel/nisse-panel.desktop"
member usr/share/kglobalaccel/nisse-panel.desktop > "$tmp/kga.desktop"
cmp -s "$tmp/kga.desktop" "$tmp/nisse-panel.desktop" || fail "the kglobalaccel copy differs from the applications desktop file"
echo "ok   Meta+N is the panel's default global shortcut"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-panel"
