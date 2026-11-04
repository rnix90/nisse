#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-branding and nisse-fonts-nunito RPMs. Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-branding && tools/rpm/build-rpm.sh nisse-fonts-nunito
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }
find_rpm() { ls -v "$RPMS"/"$1"-[0-9]*.rpm 2>/dev/null | tail -1 || true; }

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

# ---- Fedora's placeholder art (generic-logos, the hot dog) is replaced by Nisse's, not shipped alongside it.
rpm -qp --provides "$brand" | grep -qE '^system-logos = ' || fail "nisse-branding must provide system-logos (anaconda, plymouth, breeze and kde-settings require it)"
for pkg in generic-logos fedora-logos; do
    rpm -qp --conflicts "$brand" | grep -qx "$pkg" || fail "nisse-branding must conflict with $pkg"
done
manifest=tests/rpm/placeholder-paths.txt
[ -f "$manifest" ] || fail "$manifest is missing"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$brand" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
links="$(rpm -qp --qf '[%{FILENAMES} %{FILELINKTOS}\n]' "$brand")"
replaced=0
while read -r kind path sha spec; do
    printf '%s\n' "$bl" | grep -qxF "$path" || fail "branding RPM lacks the replacement for $path"
    file="$scratch$path"
    case "$spec" in
        png:*)
            want="${spec#png:}"
            got="$(python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); assert d[:8]==b"\x89PNG\r\n\x1a\n"; print("%dx%d" % struct.unpack(">II", d[16:24]))' "$file" 2>&1)" \
                || fail "$path is not a PNG: $got"
            [ "$got" = "$want" ] || fail "$path is $got, the original is $want" ;;
        svg)
            python3 -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$file" 2>/dev/null || fail "$path is not well-formed SVG"
            [ "$(stat -c %s "$file")" -lt 20000 ] || fail "$path is over 20 KB: that is raster or placeholder art, not a plain vector mark"
            grep -q 'data:image' "$file" && fail "$path embeds a raster image" ;;
        icns)
            [ "$(head -c 4 "$file")" = "icns" ] || fail "$path is not an icns file" ;;
        symlink:*)
            printf '%s\n' "$links" | grep -qxF "$path ${spec#symlink:}" || fail "$path must be a symlink to ${spec#symlink:}" ;;
        *) fail "unknown kind in $manifest: $spec" ;;
    esac
    replaced=$((replaced + 1))
done < <(grep '^R ' "$manifest")
[ "$replaced" -ge 21 ] || fail "only $replaced replacements checked, expected 21 or more"
echo "ok   $replaced placeholder paths replaced by Nisse art"

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
