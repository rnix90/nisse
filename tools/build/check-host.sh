#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Check that this machine can build nisse images (kiwi-ng, see docs/build-host.md).
# Exit 0: ready. Exit 1: not Fedora. Exit 2: tools missing. Exit 3: SELinux is enforcing (kiwi bootstrap fails).
set -u

if ! grep -qx 'ID=fedora' /etc/os-release 2>/dev/null; then
    echo "not Fedora: build nisse images inside the Fedora build VM (see docs/build-host.md)"
    exit 1
fi

declare -A PKG=(
    [kiwi-ng]=kiwi
    [rpmbuild]=rpm-build
    [createrepo_c]=createrepo_c
    [xorriso]=xorriso
    [mkfs.erofs]=erofs-utils
    [rpmlint]=rpmlint
)
missing=()
for cmd in "${!PKG[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("${PKG[$cmd]}")
done
[ -f /usr/share/edk2/ovmf/OVMF_CODE.fd ] || missing+=(edk2-ovmf)
# build/kiwi/nisse/repositories/nisse.xml verifies Fedora's packages with the key from this package; without it
# kiwi stops with a confusing signature error. NISSE_GPG_KEYS_DIR exists for tests.
[ -d "${NISSE_GPG_KEYS_DIR:-/usr/share/distribution-gpg-keys}/fedora" ] || missing+=(distribution-gpg-keys)

if [ "${#missing[@]}" -gt 0 ]; then
    echo "missing tools. Install with:"
    echo "  sudo dnf install -y ${missing[*]}"
    exit 2
fi

# kiwi's bootstrap fails under SELinux enforcing ("%sysusers scriptlet failed, exit status 127"); docs/kiwi-spike.md.
if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    echo "SELinux is enforcing: run  sudo setenforce 0  (tools/build/provision-vm.sh makes it permanent)"
    exit 3
fi

echo "build host ready: $(grep -m1 PRETTY_NAME /etc/os-release)"
