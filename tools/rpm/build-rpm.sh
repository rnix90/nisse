#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build packaging/rpm/NAME/NAME.spec into out/rpmbuild/RPMS. Run in the Fedora build VM.
#   tools/rpm/build-rpm.sh NAME
# Specs get these defines: nisse_root (repo root), fedora_release (build/FEDORA_RELEASE).
set -euo pipefail
name="${1:?usage: build-rpm.sh NAME}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
dir="$root/packaging/rpm/$name"
[ -f "$dir/$name.spec" ] || { echo "no such spec: $dir/$name.spec" >&2; exit 1; }
top="$root/out/rpmbuild"
mkdir -p "$top"/{BUILD,RPMS,SRPMS,SPECS}
rpmbuild -ba "$dir/$name.spec" \
    --define "_topdir $top" \
    --define "_sourcedir $dir" \
    --define "nisse_root $root" \
    --define "fedora_release $(cat "$root/build/FEDORA_RELEASE")"
