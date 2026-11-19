#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-415: every approved art asset in tests/rpm/approved-art.txt is in the built RPM of the package that should ship it.
# Run in the Fedora build VM after the packages are built (build/build-all.sh builds them all).
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

n=0
declare -A lists
while read -r path pkg task opts; do
    case "$path" in ""|"#"*) continue ;; esac
    if [ -z "${lists[$pkg]+x}" ]; then
        rpmf="$(ls -v out/rpmbuild/RPMS/*/"$pkg"-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
        [ -n "$rpmf" ] || fail "no built RPM for $pkg (needed for $path, made by $task); run tools/rpm/build-rpm.sh $pkg"
        lists[$pkg]="$(rpm -qlp "$rpmf")"
    fi
    case "$path" in
        */)
            min="${opts#min=}"; [ -n "$opts" ] || min=1
            count="$(printf '%s\n' "${lists[$pkg]}" | grep -c "^$path." || true)"
            [ "$count" -ge "$min" ] || fail "$pkg has $count files under $path, expected at least $min ($task)"
            ;;
        *)
            printf '%s\n' "${lists[$pkg]}" | grep -qxF "$path" || fail "$pkg lacks $path ($task)"
            ;;
    esac
    n=$((n + 1))
done < tests/rpm/approved-art.txt
[ "$n" -ge 25 ] || fail "only $n manifest lines were checked"
echo "ok   $n approved art paths are in their packages"

# the tray icons are real symbolic SVGs that take the panel color: they carry KDE's color-scheme style and no fixed fill
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-branding-[0-9]*.rpm | tail -1)"
rpm2cpio "$rpmf" | (cd "$tmp" && cpio -idm --quiet)
for state in idle busy needs-you unread paused offline; do
    f="$tmp/usr/share/icons/hicolor/scalable/status/nisse-tray-$state-symbolic.svg"
    [ -f "$f" ] || fail "missing tray icon $state"
    grep -q 'id="current-color-scheme"' "$f" || fail "$state: no KDE color-scheme style, Plasma could not recolor it"
    grep -q 'currentColor' "$f" || fail "$state: does not draw in currentColor"
    cmp -s "$f" "assets/art/tray/svg/nisse-tray-$state-symbolic.svg" || fail "$state: differs from the approved file"
done
echo "ok   the six tray icons are the approved symbolic SVGs"
echo "PASS: approved art"
