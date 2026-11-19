#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Before kiwi spends 20 minutes: can every nisse package the image installs be installed from the image's OWN repositories,
# the Fedora RELEASE repository (no updates, Bert's decision of 2026-10-29, see build/kiwi/nisse/repositories/nisse.xml) plus
# out/repo? A package built on a build VM that had drifted onto Fedora updates (Qt 6.11 while the release has 6.10) fails here at
# once with "nothing provides ..." instead of at the end of an ISO build (found 2026-11-19, N-415a).
# Run in the Fedora build VM after tools/rpm/make-repo.sh. Environment overrides (the unit test uses fakes):
#   NISSE_DNF=...        the dnf command (default: sudo dnf)
#   NISSE_REPO_DIR=...   the local repo (default: out/repo)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
repo="${NISSE_REPO_DIR:-$root/out/repo}"
dnf="${NISSE_DNF:-sudo dnf}"
release="$(tr -d '[:space:]' < build/FEDORA_RELEASE)"
[ -f "$repo/repodata/repomd.xml" ] || { echo "no local repo at $repo: run tools/rpm/make-repo.sh first" >&2; exit 1; }

pkgs="$(grep -o '<package name="nisse-[^"]*"' build/kiwi/nisse/components/nisse-live.xml | sed 's/.*name="//; s/"$//' | sort -u | tr '\n' ' ')"
[ -n "$pkgs" ] || { echo "no nisse packages found in build/kiwi/nisse/components/nisse-live.xml" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp" 2>/dev/null || sudo rm -rf "$tmp" 2>/dev/null || true' EXIT
# An empty install root, so what happens to be installed on the build VM cannot hide a missing dependency. --assumeno stops
# before anything is installed (it always exits 1), so the answer is read from the text.
out="$($dnf install --assumeno --use-host-config --installroot="$tmp" --releasever="$release" --disablerepo='*' --enablerepo=fedora \
    --repofrompath="nisse,file://$repo" --setopt=nisse.gpgcheck=0 --setopt=nisse.priority=90 --setopt=install_weak_deps=False \
    $pkgs 2>&1 || true)"
if printf '%s\n' "$out" | grep -qE 'Failed to resolve|nothing provides|conflicting requests|cannot install|No match for argument'; then
    echo "FAIL: the nisse packages cannot be installed from the image's repositories (Fedora $release release + out/repo):" >&2
    printf '%s\n' "$out" | grep -E 'Problem|nothing provides|conflict|cannot install|No match' | head -12 >&2
    echo "A 'nothing provides ... Qt_6.11' line means the build VM is ahead of the release repository: downgrade it (docs/build-host.md)." >&2
    exit 1
fi
printf '%s\n' "$out" | grep -q 'Operation aborted\|Transaction Summary' || { echo "FAIL: unexpected dnf output:" >&2; printf '%s\n' "$out" | tail -5 >&2; exit 1; }
echo "ok   every nisse package in the image can be installed from the release repository plus out/repo"
