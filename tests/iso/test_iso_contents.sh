#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Inspect a built Nisse live ISO. Run in the Fedora build VM:
#   tests/iso/test_iso_contents.sh out/nisse-live.iso
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
iso="${1:?usage: test_iso_contents.sh ISO}"
[ -f "$iso" ] || fail "ISO not found: $iso"

work="$(mktemp -d)"
cleanup() { sudo umount "$work/mnt" 2>/dev/null || true; sudo rm -rf "$work"; }
trap cleanup EXIT

xorriso -osirrox on -indev "$iso" -extract /LiveOS/squashfs.img "$work/squashfs.img" >/dev/null 2>&1 \
    || fail "no /LiveOS/squashfs.img in the ISO"

if unsquashfs -ll "$work/squashfs.img" | grep -q ' squashfs-root/LiveOS/rootfs.img$'; then
    unsquashfs -d "$work/sq" "$work/squashfs.img" LiveOS/rootfs.img >/dev/null
    mkdir "$work/mnt"
    sudo mount -o loop,ro "$work/sq/LiveOS/rootfs.img" "$work/mnt"
    root="$work/mnt"
    listing="$(sudo find "$root" -xdev -type f 2>/dev/null)"
else
    unsquashfs -d "$work/root" "$work/squashfs.img" usr/lib/os-release usr/share/fonts >/dev/null 2>&1 || true
    root="$work/root"
    listing="$(unsquashfs -ll "$work/squashfs.img" | awk '{print $NF}')"
fi

grep -qx 'ID=nisse' "$root/usr/lib/os-release" || fail "root filesystem os-release lacks ID=nisse"
[ -d "$root/usr/share/fonts/nunito" ] || fail "Nunito font directory missing"
if printf '%s\n' "$listing" | grep -E '(^|/)claude$'; then
    fail "a file named claude is inside the ISO (Claude Code must not be bundled)"
fi
echo "PASS: ISO contents ($iso)"
