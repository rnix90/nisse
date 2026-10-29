#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build out/nisse-live.iso from the vendored Fedora KDE kickstart plus our overlay.
# Run in the Fedora build VM, after tools/rpm/build-rpm.sh for each package and tools/rpm/make-repo.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
rel="$(cat build/FEDORA_RELEASE)"
[ -f out/repo/repodata/repomd.xml ] || { echo "no local repo: run tools/rpm/make-repo.sh first" >&2; exit 1; }

ks=out/nisse-live.ks
{
    sed -e '/^fedora-release-kde$/d' -e '/^@kde-spin-initial-setup$/d' -e 's/^rootpw .*/rootpw --lock/' build/kickstart/fedora-live-kde.flat.ks
    sed "s|@NISSE_REPO@|file://$root/out/repo|" build/kickstart/nisse-live.ks
} > "$ks"
ksflatten --version "F$rel" -c "$ks" -o /dev/null 2>/dev/null   # fails on real kickstart errors; upstream has a harmless duplicate "part /" warning

sudo rm -rf out/iso out/lmc-tmp
mkdir -p out/lmc-tmp
sudo livemedia-creator --ks "$ks" --no-virt --make-iso \
    --project Nisse --releasever "$rel" --volid "Nisse-$rel" \
    --iso-only --iso-name nisse-live.iso \
    --extra-boot-args "console=ttyS0 systemd.log_target=console" \
    --tmp "$root/out/lmc-tmp" --resultdir "$root/out/iso" --logfile "$root/out/lmc.log"
sudo chown -R "$(id -u):$(id -g)" out/iso
cp out/iso/nisse-live.iso out/nisse-live.iso
ls -la out/nisse-live.iso
