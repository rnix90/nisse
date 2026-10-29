#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install everything the Nisse build needs into a fresh Fedora build VM. Run inside the VM:
#   bash ~/nisse/tools/build/provision-vm.sh
# Safe to run again. See docs/build-host.md.
set -euo pipefail

sudo dnf install -y \
    rpm-build rpmlint createrepo_c xorriso erofs-utils edk2-ovmf git desktop-file-utils \
    python3-devel python3-pytest systemd-rpm-macros dnf5-plugins gawk dbus-daemon \
    cargo rust clippy rustfmt gcc gcc-c++ cmake ninja-build \
    qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qttools qt6-qtdeclarative \
    kiwi kiwi-systemdeps distribution-gpg-keys

# kiwi's bootstrap fails under SELinux enforcing ("%sysusers scriptlet failed, exit status 127"); see docs/kiwi-spike.md.
# This only affects the build VM, not the image it builds.
sudo setenforce 0 || true
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

# The ISO is built from Fedora's release repository only, so it ships Qt from the release repo: build against the
# same Qt (see docs/build-host.md, "Build the panel against the same Qt as the ISO").
sudo dnf --repo=fedora distro-sync -y 'qt6-*'

echo "provisioned: $(grep -m1 PRETTY_NAME /etc/os-release), Qt $(rpm -q --qf '%{version}' qt6-qtbase)"
