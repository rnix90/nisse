#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fetch the source of Sunshine (ledger N-507a, docs/streaming-spike.md) into the folder given as the first argument, as
# sunshine-VERSION.tar.zst. The release is a git tag WITH submodules (about 1.6 GB checked out); the tag's commit is checked against the
# one pinned here, and the submodule commits are pinned by that commit. The tarball is trimmed to what the Linux build needs:
#   - no .git data (except SVT-AV1's, see below);
#   - no x264 and no x265 sources (nisse builds its FFmpeg without them, so the tarball never carries them);
#   - of AMD's AMF repository (1.2 GB) only the headers FFmpeg's AMF encoder needs (amf/public/include) and the license.
# Nothing here is committed: out/sources is a build folder.
set -euo pipefail
dest="${1:?usage: fetch-sources.sh DEST_DIR}"
tag=v2026.914.233613
commit=63d35f702ee9e362e43263742981836ec0710384
version="${tag#v}"
out="$dest/sunshine-$version.tar.zst"
mkdir -p "$dest"
if [ -s "$out" ]; then echo "sunshine sources are already in $out"; exit 0; fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tree="$tmp/sunshine-$version"
git clone -q --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules https://github.com/LizardByte/Sunshine.git "$tree"
got="$(git -C "$tree" rev-parse HEAD)"
[ "$got" = "$commit" ] || { echo "tag $tag is at $got, not the pinned $commit" >&2; exit 1; }
ff="$tree/third-party/build-deps/third-party/FFmpeg"
rm -rf "$ff/x264" "$ff/x265_git"
if [ -d "$ff/AMF" ]; then
    mkdir -p "$tmp/amf-keep"
    cp -r "$ff/AMF/amf/public/include" "$tmp/amf-keep/include"
    cp "$ff"/AMF/LICENSE* "$tmp/amf-keep/" 2>/dev/null || true
    rm -rf "$ff/AMF"
    mkdir -p "$ff/AMF/amf/public"
    cp -r "$tmp/amf-keep/include" "$ff/AMF/amf/public/include"
    cp "$tmp/amf-keep"/LICENSE* "$ff/AMF/" 2>/dev/null || true
fi
# SVT-AV1 cannot work out its version without its git history, and the recipe fetches its tags while building: that one submodule keeps
# a real (shallow) git directory. Everything else loses its .git data.
svt="$ff/SVT-AV1"
gd="$(git -C "$svt" rev-parse --absolute-git-dir)"
rm -f "$svt/.git"
cp -r "$gd" "$svt/.git"
# the submodule's config points at a worktree by a relative path that no longer exists; edit the file directly (git itself cannot, it tries
# to enter that worktree first) and check that git now works in the folder
git config --file "$svt/.git/config" --unset core.worktree
git -c safe.directory='*' -C "$svt" rev-parse --is-inside-work-tree >/dev/null
find "$tree" -path "$svt/.git" -prune -o -name .git -prune -exec rm -rf {} +
rm -rf "$tree/.git"
tar -C "$tmp" -cf - "sunshine-$version" | zstd -q -T0 -10 -o "$out"
echo "wrote $out ($(du -h "$out" | cut -f1))"
