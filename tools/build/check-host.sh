#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Check that this machine can build Nisse images.
# Exit 0: ready. Exit 1: not Fedora. Exit 2: tools missing. Exit 3: loop devices unavailable.
set -u

if ! grep -qx 'ID=fedora' /etc/os-release 2>/dev/null; then
    echo "not Fedora: build Nisse images inside the Fedora build VM (see docs/build-host.md)"
    exit 1
fi

declare -A PKG=(
    [livemedia-creator]=lorax-lmc-novirt
    [rpmbuild]=rpm-build
    [createrepo_c]=createrepo_c
    [xorriso]=xorriso
    [unsquashfs]=squashfs-tools
    [ksflatten]=pykickstart
    [rpmlint]=rpmlint
)
missing=()
for cmd in "${!PKG[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("${PKG[$cmd]}")
done
[ -f /usr/share/edk2/ovmf/OVMF_CODE.fd ] || missing+=(edk2-ovmf)

if [ "${#missing[@]}" -gt 0 ]; then
    echo "missing tools. Install with:"
    echo "  sudo dnf install -y ${missing[*]}"
    exit 2
fi

if ! sudo losetup -f >/dev/null 2>&1; then
    echo "loop devices are unavailable: livemedia-creator --no-virt cannot run here"
    exit 3
fi

echo "build host ready: $(grep -m1 PRETTY_NAME /etc/os-release)"
