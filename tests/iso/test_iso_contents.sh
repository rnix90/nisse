#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Inspect a built Nisse live ISO (kiwi layout: /LiveOS/squashfs.img is an EROFS image holding the root filesystem;
# see docs/kiwi-spike.md). Run in the Fedora build VM:
#   tests/iso/test_iso_contents.sh out/nisse-live.iso
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
iso="${1:?usage: test_iso_contents.sh ISO}"
[ -f "$iso" ] || fail "ISO not found: $iso"

work="$(mktemp -d)"
cleanup() { sudo umount "$work/mnt" 2>/dev/null || true; sudo rm -rf "$work"; }
trap cleanup EXIT

xorriso -osirrox on -indev "$iso" -extract /LiveOS/squashfs.img "$work/root.erofs" >/dev/null 2>&1 \
    || fail "no /LiveOS/squashfs.img in the ISO"
mkdir "$work/mnt"
sudo mount -t erofs -o loop,ro "$work/root.erofs" "$work/mnt" || fail "the root image is not a mountable EROFS filesystem"
root="$work/mnt"
listing="$(sudo find "$root" -xdev -type f 2>/dev/null)"

grep -qx 'ID=nisse' "$root/usr/lib/os-release" || fail "root filesystem os-release lacks ID=nisse"
[ -d "$root/usr/share/fonts/nunito" ] || fail "Nunito font directory missing"
for prog in nisse-hwroute nisse-daemon nisse-audit-hook nisse-panel nisse-fetch-claude; do
    # a here-string, not a pipe: under pipefail, grep -q exits early and printf dies of SIGPIPE on a long listing
    grep -qE "(^|/)usr/bin/$prog$" <<< "$listing" || fail "/usr/bin/$prog is missing from the ISO"
done
if grep -E '(^|/)claude$' <<< "$listing"; then
    fail "a file named claude is inside the ISO (Claude Code must not be bundled)"
fi

# The installer hook that routes hardware at install time (Anaconda runs everything in this directory).
[ -f "$root/usr/share/anaconda/post-scripts/90-nisse-hwroute.ks" ] \
    || fail "Anaconda post-script 90-nisse-hwroute.ks is missing"

# Package database checks: the release-repo-only decision (Qt 6.10) and Fedora's KDE release package is gone.
rpmq() { rpm --dbpath "$root/usr/lib/sysimage/rpm" "$@"; }
qt="$(rpmq -q --qf '%{version}' qt6-qtbase 2>/dev/null)" || fail "qt6-qtbase is not installed in the image"
case "$qt" in 6.10*) ;; *) fail "qt6-qtbase is $qt, expected 6.10.x (release repo only, no updates)";; esac
if rpmq -q fedora-release-kde >/dev/null 2>&1; then fail "fedora-release-kde is installed (Nisse must use nisse-release)"; fi
rpmq -q nisse-release >/dev/null 2>&1 || fail "nisse-release is not installed"

echo "PASS: ISO contents ($iso), Qt $qt"
