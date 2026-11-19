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

member usr/share/applications/nisse-panel.desktop | grep -qx 'Icon=nisse-assistant' || fail "desktop file must use the assistant sparkle icon (N-409a), not the start button's disc or the n"
for f in /usr/share/icons/hicolor/scalable/apps/nisse-assistant.svg /usr/share/icons/hicolor/48x48/apps/nisse-assistant.png          /usr/share/icons/hicolor/16x16/apps/nisse-assistant.png /usr/share/icons/hicolor/512x512/apps/nisse-assistant.png; do
    printf '%s
' "$files" | grep -qxF "$f" || fail "RPM lacks the assistant icon $f"
done
rpm -qp --requires "$rpmf" | grep -q '^nisse-daemon' || fail "RPM must require nisse-daemon"
rpm -qp --requires "$rpmf" | grep -q 'qt6-qtdeclarative' || fail "RPM must require qt6-qtdeclarative (QML runtime)"
# N-205: the microphone check runs pw-dump, so the package must pull it in.
rpm -qp --requires "$rpmf" | grep -qx 'pipewire-utils' || fail "RPM must require pipewire-utils (the notice is held back while a microphone is in use)"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
# N-415a: the panel is a docked sidebar that runs from login. It needs the layer-shell plugin at run time (loaded, not linked, so
# only an explicit Requires finds it) and an autostart entry that starts it closed.
rpm -qp --requires "$rpmf" | grep -qx 'layer-shell-qt' || fail "RPM must require layer-shell-qt (the sidebar is a layer-shell surface)"
printf '%s
' "$files" | grep -qxF /etc/xdg/autostart/nisse-panel-autostart.desktop || fail "RPM lacks the login autostart entry"
grep -qx 'Exec=nisse-panel --background' "$root_dir/etc/xdg/autostart/nisse-panel-autostart.desktop" || fail "the autostart entry must start the panel with --background (closed)"
grep -qx 'OnlyShowIn=KDE;' "$root_dir/etc/xdg/autostart/nisse-panel-autostart.desktop" || fail "the autostart entry must be for KDE only"
grep -qx 'Exec=nisse-panel' "$root_dir/usr/share/applications/nisse-panel.desktop" || fail "the launcher must stay a plain 'nisse-panel' (a second launch toggles the running sidebar)"

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
