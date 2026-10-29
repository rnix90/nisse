#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Gather every built RPM into out/repo and index it. Run in the Fedora build VM.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
repo="$root/out/repo"
rm -rf "$repo"
mkdir -p "$repo"
cp "$root"/out/rpmbuild/RPMS/*/*.rpm "$repo"/
createrepo_c "$repo"
