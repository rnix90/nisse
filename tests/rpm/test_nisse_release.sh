#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-release RPMs. Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-release
set -euo pipefail
cd "$(dirname "$0")/../.."

REL="$(cat build/FEDORA_RELEASE)"
PROD="$(tr -d '[:space:]' < build/PRODUCT_VERSION)"   # Nisse's own version; REL is only the Fedora base
RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }

main="$(ls -v "$RPMS"/nisse-release-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
common="$(ls -v "$RPMS"/nisse-release-common-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$main" ] || fail "nisse-release RPM not found in $RPMS (run tools/rpm/build-rpm.sh nisse-release)"
[ -n "$common" ] || fail "nisse-release-common RPM not found in $RPMS"

member() { rpm2cpio "$1" | cpio -i --to-stdout --quiet "./$2"; }

osr="$(member "$main" usr/lib/os-release)"
# The user-visible name and version are Nisse's own; VERSION_ID stays the Fedora base (dnf's $releasever, COPR and %fedora need it).
for want in "VERSION=\"$PROD\"" "PRETTY_NAME=\"Nisse $PROD\"" "BUILD_ID=$PROD" "CPE_NAME=\"cpe:/o:nisse:nisse:$PROD\""; do
    printf '%s
' "$osr" | grep -qxF "$want" || fail "os-release lacks line: $want"
done
printf '%s
' "$osr" | grep -E '^(PRETTY_NAME|VERSION)=' | grep -q "$REL" && fail "os-release shows the Fedora base ($REL) in its user-visible name or version"
[ "$(rpm -qp --qf '%{VERSION}' "$main")" = "$REL" ] || fail "the RPM Version must stay the Fedora base $REL (dnf's releasever)"
[ "$(member "$common" usr/lib/fedora-release)" = "Nisse release $PROD (Nisse)" ] || fail "/usr/lib/fedora-release must read: Nisse release $PROD (Nisse)"
[ "$(member "$common" usr/lib/system-release-cpe)" = "cpe:/o:nisse:nisse:$PROD" ] || fail "system-release-cpe must be cpe:/o:nisse:nisse:$PROD"
for want in 'ID=nisse' 'ID_LIKE="fedora"' 'LOGO=distributor-logo-nisse' "VERSION_ID=$REL" 'NAME="Nisse"'              'DEFAULT_HOSTNAME=nisse' 'HOME_URL="https://github.com/rnix90/nisse"'              'BUG_REPORT_URL="https://github.com/rnix90/nisse/issues"' 'SUPPORT_URL="https://github.com/rnix90/nisse"'; do
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
member "$common" usr/lib/systemd/system-preset/80-nisse-desktop.preset | grep -qx 'enable livesys.service'          || fail "common lacks a preset enabling livesys.service (live user and autologin)"
member "$common" usr/lib/systemd/system-preset/80-nisse-desktop.preset | grep -qx 'enable livesys-late.service'     || fail "common lacks a preset enabling livesys-late.service"

# Nisse adopts Fedora's own preset set (fedora-release-common 44-18, MIT); only the deviations live in 80-nisse-desktop.
p90="$(member "$common" usr/lib/systemd/system-preset/90-default.preset)"
[ "$(head -1 <<< "$p90")" = "# Derived from fedora-release-common 44-18 (MIT). See README.md." ] || fail "90-default.preset must start with the provenance line"
for want in 'enable systemd-resolved.service' 'enable systemd-oomd.*' 'enable tuned.service' 'enable power-profiles-daemon.service' \
            'enable thermald.service' 'enable fstrim.timer' 'enable audit-rules.service' 'enable flatpak-add-fedora-repos.service'; do
    grep -qxF "$want" <<< "$p90" || fail "90-default.preset lacks Fedora's line: $want"
done
member "$common" usr/lib/systemd/system-preset/80-nisse-desktop.preset | grep -qx 'disable sshd.service' || fail "80-nisse-desktop.preset must disable sshd.service (an SSH server is opt-in)"
member "$common" usr/lib/systemd/system-preset/80-nisse-desktop.preset | grep -qx 'disable plasma-setup.service' || fail "80-nisse-desktop.preset must disable plasma-setup.service (Nisse has its own first-boot flow)"
member "$common" usr/lib/systemd/system-preset/85-display-manager.preset | grep -qx 'enable plasmalogin.service' || fail "85-display-manager.preset must enable plasmalogin.service"
# The user preset is what turns on a desktop session's audio (PipeWire) and user directories.
u90="$(member "$common" usr/lib/systemd/user-preset/90-default-user.preset)"
[ "$(head -1 <<< "$u90")" = "# Derived from fedora-release-common 44-18 (MIT). See README.md." ] || fail "90-default-user.preset must start with the provenance line"
for want in 'enable wireplumber.service' 'enable pipewire-pulse.socket' 'enable xdg-user-dirs.service' 'enable obex.service'; do
    grep -qxF "$want" <<< "$u90" || fail "90-default-user.preset lacks Fedora's line: $want"
done

# dnf5's copr plugin builds the COPR chroot name from os-release ID ("nisse-44"), which does not exist.
# This vendor config tells it to use Fedora's chroots (verified in the VM with a fake ID=nisse os-release).
vendor="$(member "$common" etc/dnf/plugins/copr.vendor.conf)"
for want in '[main]' 'distribution = fedora' "releasever = $REL"; do
    grep -qxF "$want" <<< "$vendor" || fail "copr.vendor.conf lacks line: $want"
done

# /usr/share/nisse is shared by nisse-hw, nisse-daemon and later packages: the release package owns the directory.
rpm -qp --dump "$common" | grep -qE '^/usr/share/nisse [0-9]+ [0-9]+ [^ ]+ 040' || fail "nisse-release-common must own the directory /usr/share/nisse"

out="$(rpmlint "$main" "$common" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"

echo "PASS: nisse-release"
