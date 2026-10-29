#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-release RPMs. Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-release
set -euo pipefail
cd "$(dirname "$0")/../.."

REL="$(cat build/FEDORA_RELEASE)"
RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }

main="$(ls "$RPMS"/nisse-release-[0-9]*.rpm 2>/dev/null | head -1 || true)"
common="$(ls "$RPMS"/nisse-release-common-[0-9]*.rpm 2>/dev/null | head -1 || true)"
[ -n "$main" ] || fail "nisse-release RPM not found in $RPMS (run tools/rpm/build-rpm.sh nisse-release)"
[ -n "$common" ] || fail "nisse-release-common RPM not found in $RPMS"

member() { rpm2cpio "$1" | cpio -i --to-stdout --quiet "./$2"; }

osr="$(member "$main" usr/lib/os-release)"
for want in 'ID=nisse' 'ID_LIKE="fedora"' 'LOGO=distributor-logo-nisse' "VERSION_ID=$REL" 'NAME="Nisse"'; do
    printf '%s\n' "$osr" | grep -qxF "$want" || fail "os-release lacks line: $want"
done

rpm -qp --provides "$main" | grep -qx 'system-release' || fail "nisse-release does not provide system-release"
rpm -qp --conflicts "$main" | grep -qx 'fedora-release' || fail "nisse-release does not conflict with fedora-release"
rpm -qp --conflicts "$common" | grep -qx 'fedora-release-common' || fail "common does not conflict with fedora-release-common"

[ "$(member "$common" etc/nisse/channel)" = "stable" ] || fail "/etc/nisse/channel must contain exactly: stable"
for ch in stable daily; do
    repo="$(member "$common" "etc/yum.repos.d/nisse-$ch.repo")"
    printf '%s\n' "$repo" | grep -qx 'enabled=0' || fail "nisse-$ch.repo must contain enabled=0"
done

member "$common" usr/lib/systemd/system-preset/80-nisse-desktop.preset | grep -qx 'enable plasmalogin.service'     || fail "common lacks a preset enabling plasmalogin.service (the KDE display manager)"

out="$(rpmlint "$main" "$common" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"

echo "PASS: nisse-release"
