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

if [ "$fail" -eq 0 ]; then echo "PASS: build guards"; else echo "$fail failure(s)"; exit 1; fi
