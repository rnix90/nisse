#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-branding and nisse-fonts-nunito RPMs. Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-branding && tools/rpm/build-rpm.sh nisse-fonts-nunito
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }
find_rpm() { ls "$RPMS"/"$1"-[0-9]*.rpm 2>/dev/null | head -1 || true; }

brand="$(find_rpm nisse-branding)"
fonts="$(find_rpm nisse-fonts-nunito)"
[ -n "$brand" ] || fail "nisse-branding RPM not found (run tools/rpm/build-rpm.sh nisse-branding)"
[ -n "$fonts" ] || fail "nisse-fonts-nunito RPM not found (run tools/rpm/build-rpm.sh nisse-fonts-nunito)"

bl="$(rpm -qlp "$brand")"
for f in /usr/share/icons/hicolor/48x48/apps/distributor-logo-nisse.png \
         /usr/share/icons/hicolor/scalable/apps/distributor-logo-nisse.svg \
         /usr/share/icons/hicolor/symbolic/apps/distributor-logo-nisse-symbolic.svg; do
    printf '%s\n' "$bl" | grep -qxF "$f" || fail "branding RPM lacks $f"
done

fl="$(rpm -qlp "$fonts")"
printf '%s\n' "$fl" | grep -qF '/usr/share/fonts/nunito/Nunito[wght].ttf' || fail "fonts RPM lacks the roman TTF"
printf '%s\n' "$fl" | grep -qF '/usr/share/fonts/nunito/Nunito-Italic[wght].ttf' || fail "fonts RPM lacks the italic TTF"
rpm -qp --licensefiles "$fonts" | grep -q 'OFL' || fail "fonts RPM has no OFL license file"
rpm -qp --provides "$fonts" | grep -qx 'font(nunito)' || fail "fonts RPM does not provide font(nunito)"

[ "$(rpm -qp --qf '%{LICENSE}' "$fonts")" = "OFL-1.1" ] || fail "fonts License must be OFL-1.1"
[ "$(rpm -qp --qf '%{LICENSE}' "$brand")" = "GPL-2.0-or-later" ] || fail "branding License must be GPL-2.0-or-later"

out="$(rpmlint "$brand" "$fonts" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"

echo "PASS: branding and fonts"
