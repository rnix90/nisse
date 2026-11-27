#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fetch the six source tarballs of moonlight-qt (ledger N-507a) into the folder given as the first argument.
# They come from Fedora's own source package of the exact build nisse rebuilds, on Koji (which keeps every build); each file is checked
# against the sha256 in sources.sha256, so a changed or damaged download stops the build. Nothing here is committed: out/sources is a
# build folder.
set -euo pipefail
dest="${1:?usage: fetch-sources.sh DEST_DIR}"
here="$(cd "$(dirname "$0")" && pwd)"
srpm_url='https://kojipkgs.fedoraproject.org/packages/moonlight-qt/6.2.0%5E20261105git3fead13/1.fc44/src/moonlight-qt-6.2.0%5E20261105git3fead13-1.fc44.src.rpm'
mkdir -p "$dest"
if (cd "$dest" && sha256sum --quiet -c "$here/sources.sha256" >/dev/null 2>&1); then
    echo "moonlight-qt sources are already in $dest"
    exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -sfL --retry 3 -o "$tmp/m.src.rpm" "$srpm_url"
(cd "$tmp" && rpm2cpio m.src.rpm | cpio -idm --quiet)
cp "$tmp"/*.tar.gz "$dest"/
(cd "$dest" && sha256sum -c "$here/sources.sha256")
