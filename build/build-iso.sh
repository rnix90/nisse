#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build out/nisse-live.iso with kiwi from the vendored Fedora description plus the Nisse overlay.
# Run in the Fedora build VM (SELinux permissive, see docs/build-host.md) after tools/rpm/build-rpm.sh for each
# package and tools/rpm/make-repo.sh. out/nisse-live.iso exists only if this script succeeded.
#   NISSE_REPO_URL=dir:///path/to/repo   use another local repo (default: out/repo)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Never leave a stale ISO behind: a failed build (including a failed pre-check) must not look like a successful one.
rm -f out/nisse-live.iso

repo_dir="${NISSE_REPO_URL:-dir://$root/out/repo}"
repo_dir="${repo_dir#dir://}"
[ -f "$repo_dir/repodata/repomd.xml" ] || { echo "no local repo at $repo_dir: run tools/rpm/make-repo.sh first" >&2; exit 1; }

bash build/render-kiwi.sh

# kiwi mounts /proc, /dev and /sys inside its target tree; clear an old target only through kiwi's own unmounting, and
# refuse to rm -rf anything that is still a mount point (see docs/kiwi-spike.md).
if findmnt -rn -o TARGET | grep -q "^$root/out/kiwi-build"; then
    echo "out/kiwi-build still has mounts; unmount them first (findmnt | grep kiwi-build)" >&2
    exit 1
fi
sudo rm -rf out/kiwi-build

sudo kiwi-ng --profile Nisse-Live --type iso system build \
    --description out/kiwi-description --target-dir out/kiwi-build

iso="$(ls out/kiwi-build/*.iso 2>/dev/null | head -1)"
[ -n "$iso" ] && [ -s "$iso" ] || { echo "kiwi finished but produced no ISO in out/kiwi-build" >&2; exit 1; }
sudo chown "$(id -u):$(id -g)" "$iso"
cp "$iso" out/nisse-live.iso.partial
mv out/nisse-live.iso.partial out/nisse-live.iso
ls -la out/nisse-live.iso
