#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# A build that fails before kiwi even starts must not leave an old out/nisse-live.iso that looks like a fresh success.
# Runs on a scratch copy of the scripts, so it needs neither kiwi nor the VM.
set -u
cd "$(dirname "$0")/../.."
repo="$PWD"
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fresh_tree() { # DIR : scripts plus a stale ISO
    mkdir -p "$1/build" "$1/tools/rpm" "$1/out"
    cp "$repo/build/build-iso.sh" "$repo/build/build-all.sh" "$1/build/"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$1/tools/rpm/build-rpm.sh"
    echo stale > "$1/out/nisse-live.iso"
}

# build-iso.sh with no local repo: fails at its pre-check
fresh_tree "$tmp/iso"
(cd "$tmp/iso" && NISSE_REPO_URL="dir://$tmp/iso/no-such-repo" bash build/build-iso.sh >/dev/null 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok "build-iso.sh fails without a repo (exit $rc)" || bad "build-iso.sh succeeded without a repo"
[ ! -e "$tmp/iso/out/nisse-live.iso" ] && ok "build-iso.sh removed the stale ISO before its pre-check" || bad "build-iso.sh left the stale ISO behind"

# build-all.sh when the first RPM build fails
fresh_tree "$tmp/all"
(cd "$tmp/all" && bash build/build-all.sh >/dev/null 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok "build-all.sh fails when an RPM build fails (exit $rc)" || bad "build-all.sh succeeded with a failing RPM build"
[ ! -e "$tmp/all/out/nisse-live.iso" ] && ok "build-all.sh removed the stale ISO before building" || bad "build-all.sh left the stale ISO behind"

# ---- build-iso.sh past its pre-checks, with stub sudo/kiwi-ng/findmnt so it needs neither kiwi nor root
iso_tree() { # DIR : a tree where build-iso.sh gets as far as running "kiwi"
    mkdir -p "$1/build" "$1/out/repo/repodata" "$1/bin"
    cp "$repo/build/build-iso.sh" "$1/build/"
    : > "$1/out/repo/repodata/repomd.xml"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1/build/render-kiwi.sh"
    printf '#!/bin/sh\nexec "$@"\n' > "$1/bin/sudo"
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/kiwi-ng"
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/findmnt"   # no mounts by default
    chmod +x "$1/bin/sudo" "$1/bin/kiwi-ng" "$1/bin/findmnt"
}

# kiwi exits 0 but leaves no ISO: say so (under set -e and pipefail the old `ls | head` aborted silently)
iso_tree "$tmp/noiso"
msg="$(cd "$tmp/noiso" && PATH="$tmp/noiso/bin:$PATH" bash build/build-iso.sh 2>&1 >/dev/null)"
rc=$?
[ "$rc" -ne 0 ] && ok "build-iso.sh fails when kiwi produces no ISO (exit $rc)" || bad "build-iso.sh succeeded without an ISO"
case "$msg" in
    *"kiwi finished but produced no ISO in out/kiwi-build"*) ok "build-iso.sh explains that kiwi produced no ISO" ;;
    *) bad "build-iso.sh printed no explanation for a missing ISO: $msg" ;;
esac

# a mount under out/kiwi-build must stop the rm -rf, even when the repo path contains regex characters
iso_tree "$tmp/a[b"
printf '#!/bin/sh\necho "%s/out/kiwi-build/proc"\n' "$(cd "$tmp/a[b" && pwd -P)" > "$tmp/a[b/bin/findmnt"
chmod +x "$tmp/a[b/bin/findmnt"
mkdir -p "$tmp/a[b/out/kiwi-build"
msg="$(cd "$tmp/a[b" && PATH="$tmp/a[b/bin:$PATH" bash build/build-iso.sh 2>&1 >/dev/null)"
rc=$?
[ "$rc" -ne 0 ] && ok "build-iso.sh refuses to delete a target that still has mounts (exit $rc)" || bad "build-iso.sh ignored a mount under out/kiwi-build"
case "$msg" in
    *"still has mounts"*) ok "build-iso.sh names the mount problem (path with a bracket)" ;;
    *) bad "build-iso.sh did not report the mount (a path with [ broke the guard): $msg" ;;
esac
[ -d "$tmp/a[b/out/kiwi-build" ] && ok "the mounted target was left in place" || bad "the mounted target was deleted"

if [ "$fail" -eq 0 ]; then echo "PASS: build guards"; else echo "$fail failure(s)"; exit 1; fi
