#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run in the Fedora build VM: builds the probe package in four versions and the local file repositories the safe-apply
# end-to-end test updates from, and packs them as out/e2e/probe-repos.tgz:
#   probe-1.0.rpm      what the test installs first
#   repo-none/         probe 1.0 only: nothing to update
#   repo-good/         probe 2.0: an ordinary update
#   repo-good2/        probe 2.5: a second update, the one that never gets verified
#   repo-bad/          probe 3.0 whose %pre fails: an update that cannot be applied
set -euo pipefail
cd "$(dirname "$0")/../../.."
spec="$PWD/tests/e2e/data/nisse-e2e-probe.spec"
out="$PWD/out/e2e"
top="$(mktemp -d)"
trap 'rm -rf "$top"' EXIT
rm -rf "$out"; mkdir -p "$out/pack"
build() { # version [bad]
    rpmbuild -bb --define "_topdir $top" --define "ver $1" ${2:+--define "badpre 1"} "$spec" >/dev/null 2>&1
    ls "$top/RPMS/noarch/nisse-e2e-probe-$1-1.noarch.rpm"
}
v1="$(build 1.0)"; v2="$(build 2.0)"; v25="$(build 2.5)"; v3="$(build 3.0 bad)"
cp "$v1" "$out/pack/probe-1.0.rpm"
for r in none good good2 bad; do mkdir -p "$out/pack/repo-$r"; done
cp "$v1" "$out/pack/repo-none/"; cp "$v2" "$out/pack/repo-good/"; cp "$v25" "$out/pack/repo-good2/"; cp "$v3" "$out/pack/repo-bad/"
for r in none good good2 bad; do createrepo_c "$out/pack/repo-$r" >/dev/null; done
tar -C "$out/pack" -czf "$out/probe-repos.tgz" .
ls -l "$out/probe-repos.tgz"
