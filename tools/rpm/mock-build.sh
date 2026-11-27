#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build packaging/rpm/NAME/NAME.spec in a CLEAN mock chroot against Fedora's release repository only (no updates), which is what the
# image carries. For packages built from upstream sources that are not in the git tree (ledger N-507a: moonlight-qt, sunshine). Run in the
# Fedora build VM (needs the mock package and the builder's sudo):
#   tools/rpm/mock-build.sh NAME
# If packaging/rpm/NAME/fetch-sources.sh exists it is run first, with out/sources/NAME as its argument; the spec's sources are taken from
# that folder and from the packaging folder. A file packaging/rpm/NAME/needs-network switches the chroot's network on (Sunshine fetches its
# web UI's npm packages and Boost while it builds). The RPMs (not the debug ones) land in out/rpmbuild/RPMS/ARCH like build-rpm.sh's.
set -euo pipefail
name="${1:?usage: mock-build.sh NAME}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
dir="$root/packaging/rpm/$name"
[ -f "$dir/$name.spec" ] || { echo "no such spec: $dir/$name.spec" >&2; exit 1; }
top="$root/out/rpmbuild"
src="$root/out/sources/$name"
res="$top/mock/$name"
mkdir -p "$src" "$top/RPMS"
[ -f "$dir/fetch-sources.sh" ] && bash "$dir/fetch-sources.sh" "$src"
# everything the spec lists as a source that is in the packaging folder is offered next to the fetched ones
for f in "$dir"/*; do case "$f" in *.spec|*/fetch-sources.sh|*/sources.sha256|*/needs-network) ;; *) cp -r "$f" "$src"/ ;; esac; done
net=()
[ -f "$dir/needs-network" ] && net=(--enable-network)
sudo rm -rf "$res"   # mock writes it as root
sudo mock -r fedora-44-x86_64 --disablerepo=updates "${net[@]}" --resultdir "$res" \
    --spec "$dir/$name.spec" --sources "$src"
for r in "$res"/*.rpm; do
    case "$r" in *.src.rpm|*-debuginfo-*|*-debugsource-*) continue ;; esac
    arch="$(rpm -qp --qf '%{ARCH}' "$r")"
    mkdir -p "$top/RPMS/$arch"
    sudo chown "$(id -u):$(id -g)" "$r"
    cp -f "$r" "$top/RPMS/$arch/"
    echo "built: $top/RPMS/$arch/$(basename "$r")"
done
