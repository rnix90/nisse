#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build every Nisse RPM, index them into out/repo, then build out/nisse-live.iso. Run in the Fedora build VM:
#   setsid nohup bash build/build-all.sh > out/build-all.log 2>&1 < /dev/null &      (about 25-35 minutes)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p out

for pkg in nisse-release nisse-branding nisse-fonts-nunito nisse-hw nisse-firstboot nisse-daemon nisse-panel; do
    echo "== building $pkg"
    tools/rpm/build-rpm.sh "$pkg" > "out/build-$pkg.log" 2>&1 < /dev/null || {
        echo "build of $pkg failed; see out/build-$pkg.log" >&2
        exit 1
    }
done
echo "== indexing the local repo"
tools/rpm/make-repo.sh
echo "== building the ISO"
bash build/build-iso.sh
echo "== done"
