#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built moonlight-qt RPM (the Moonlight game-streaming client, ledger N-507a). Fedora has it only in the updates repository and
# the image uses the release repository only, so nisse rebuilds Fedora's own source package unchanged. Run in the Fedora build VM after:
#   tools/rpm/mock-build.sh moonlight-qt
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/x86_64
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm_path="$(ls -v "$RPMS"/moonlight-qt-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpm_path" ] || fail "moonlight-qt RPM not found (run tools/rpm/mock-build.sh moonlight-qt)"

files="$(rpm -qlp "$rpm_path")"
for f in /usr/bin/moonlight /usr/share/applications/com.moonlight_stream.Moonlight.desktop /usr/share/icons/hicolor/scalable/apps/moonlight.svg; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "moonlight-qt lacks $f"
done
echo "ok   the program, its launcher entry and its icon are in the package"

rel="$(rpm -qp --qf '%{RELEASE}' "$rpm_path")"
case "$rel" in *nisse*) ;; *) fail "the release '$rel' does not say it is nisse's rebuild (it would look like Fedora's own)";; esac
lic="$(rpm -qp --qf '%{LICENSE}' "$rpm_path")"
[ "$lic" = "GPL-3.0-or-later AND MIT AND Zlib AND LGPL-2.1-or-later" ] || fail "unexpected license: $lic"
echo "ok   release $rel, license $lic"

# built against the image's Qt 6.10 and FFmpeg 8 (the release repository), not the newer updates set
req="$(rpm -qp --requires "$rpm_path")"
printf '%s\n' "$req" | grep -qxF 'libQt6Core.so.6(Qt_6.10)(64bit)' || fail "moonlight-qt does not require Qt 6.10 (built against the wrong Qt?)"
printf '%s\n' "$req" | grep -qxF 'libavcodec.so.62()(64bit)' || fail "moonlight-qt does not use FFmpeg 8 (libavcodec.so.62)"
echo "ok   built against Qt 6.10 and libavcodec.so.62"

# the clean-repo decision: no codec library of our own inside the package (it decodes with Fedora's FFmpeg)
if printf '%s\n' "$files" | grep -qiE 'libav|libx26|openh264|libsvt|libdav1d'; then fail "moonlight-qt ships a codec library of its own"; fi
echo "ok   no codec library inside (it uses Fedora's FFmpeg)"

# rpmlint: the upstream-given findings are listed in the rpmlintrc next to the spec, anything else fails
rc=packaging/rpm/moonlight-qt/moonlight-qt.rpmlintrc
[ -f "$rc" ] || fail "no $rc"
out="$(rpmlint -r "$rc" "$rpm_path" 2>&1 || true)"
errs="$(printf '%s\n' "$out" | grep -c ': E: ' || true)"
[ "$errs" = 0 ] || { printf '%s\n' "$out" | grep ': E: '; fail "rpmlint: $errs error(s)"; }
echo "ok   rpmlint: 0 errors"
echo "PASS: moonlight-qt"
