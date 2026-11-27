#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-streaming RPM (the Sunshine and trustworthy network install choices, ledger N-507c). Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-streaming
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm_path="$(ls -v "$RPMS"/nisse-streaming-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpm_path" ] || fail "nisse-streaming RPM not found (run tools/rpm/build-rpm.sh nisse-streaming)"

files="$(rpm -qlp "$rpm_path")"
for f in /usr/share/nisse/choices.d/40-trusted-network.toml /usr/share/nisse/choices.d/50-sunshine.toml /usr/share/nisse/choices.d/51-sunshine-web-ui.toml \
         /usr/share/nisse/choices.d/52-sunshine-start.toml /usr/libexec/nisse/nisse-network-trust /usr/libexec/nisse/nisse-sunshine-setup \
         /usr/libexec/nisse/nisse-apply-sunshine-config /etc/xdg/autostart/nisse-sunshine-config.desktop; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "nisse-streaming lacks $f"
done
echo "ok   the four manifests, the three scripts and the autostart entry are in the package"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpm_path" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
for s in nisse-network-trust nisse-sunshine-setup nisse-apply-sunshine-config; do
    [ -x "$scratch/usr/libexec/nisse/$s" ] || fail "$s is not executable"
    # rpm rewrites the first line (#!/bin/sh becomes #!/usr/bin/sh); everything after it is the source
    cmp -s <(tail -n +2 "$scratch/usr/libexec/nisse/$s") <(tail -n +2 "packaging/rpm/nisse-streaming/$s") || fail "$s differs from its source"
done
cmp -s "$scratch/usr/share/nisse/choices.d/50-sunshine.toml" packaging/rpm/nisse-streaming/choice-sunshine.toml || fail "the sunshine manifest differs from its source"
echo "ok   the scripts are executable and are the sources"

# the manifests pass the real engine's validation, and the order is right
engine="$(ls services/target/debug/nisse-choices services/target/release/nisse-choices 2>/dev/null | head -1 || true)"
if [ -n "$engine" ]; then
    "$engine" validate "$scratch/usr/share/nisse/choices.d" >/dev/null || fail "nisse-choices validate rejects a shipped manifest"
    echo "ok   all four manifests pass nisse-choices validate"
else
    echo "note: no built nisse-choices here (cargo build -p nisse-choices in services/): the manifests were not validated by the engine"
fi

req="$(rpm -qp --requires "$rpm_path")"
for dep in firewalld NetworkManager; do
    printf '%s\n' "$req" | grep -qxE "$dep( .*)?" || fail "nisse-streaming must require $dep"
done
[ "$(rpm -qp --qf '%{LICENSE}' "$rpm_path")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
[ "$(rpm -qp --qf '%{ARCH}' "$rpm_path")" = "noarch" ] || fail "must be noarch"
echo "ok   requires the firewall and NetworkManager, GPL-2.0-or-later, noarch"

out="$(rpmlint "$rpm_path" 2>&1 || true)"
errs="$(printf '%s\n' "$out" | grep -c ': E: ' || true)"
[ "$errs" = 0 ] || { printf '%s\n' "$out" | grep ': E: '; fail "rpmlint: $errs error(s)"; }
echo "ok   rpmlint: 0 errors"
echo "PASS: nisse-streaming"
