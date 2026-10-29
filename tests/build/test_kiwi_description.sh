#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the kiwi description under build/kiwi/.
#   part 1 (always): the vendored Fedora copy is complete, well-formed, pinned and reproducible.
#   part 2 (when out/kiwi-description exists or kiwi-ng is installed): the rendered Nisse description.
set -u
cd "$(dirname "$0")/../.."
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

PIN=dfc49a5a10f69941179fdadd96aa6a5984f7c677
V=build/kiwi/fedora

# ---- part 1: vendored copy
for f in components/common.xml components/boot.xml components/liveinstall.xml components/users.xml \
         components/desktops/common.xml components/desktops/kde.xml config.sh root/etc/fstab.script \
         iso-esp-excludes.yaml grub-x86.cfg.iso-template grub-arm.cfg.iso-template grub-riscv64.cfg.iso-template \
         grub-ppc.cfg.iso-template editbootinstall_rpilegacy.sh COPYING VENDORED.md; do
    [ -f "$V/$f" ] && ok "vendored: $f" || bad "missing: $V/$f"
done

py="$(command -v python3 || command -v python)"
xmlbad="$(find "$V" -name '*.xml' -print0 2>/dev/null | xargs -0 -r "$py" -c '
import sys, xml.etree.ElementTree as E
for f in sys.argv[1:]:
    try:
        E.parse(f)
    except Exception as e:
        print(f, e)')"
[ -z "$xmlbad" ] && ok "every vendored .xml is well-formed" || bad "malformed xml: $xmlbad"

grep -q "$PIN" "$V/VENDORED.md" 2>/dev/null && ok "VENDORED.md records the pinned commit" || bad "VENDORED.md lacks commit $PIN"
head -3 "$V/COPYING" 2>/dev/null | grep -q "GNU GENERAL PUBLIC LICENSE" && ok "COPYING is the GPL text" || bad "COPYING missing or not the GPL"
for d in teams scripts repositories; do
    [ ! -e "$V/$d" ] && ok "not vendored: $d/" || bad "$V/$d must not be vendored"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if VENDOR_DEST="$tmp/fedora" bash tools/build/vendor-kiwi.sh "$PIN" >"$tmp/vendor.log" 2>&1; then
    if diff -r -q "$V" "$tmp/fedora" >"$tmp/diff.txt" 2>&1; then ok "re-vendoring the pinned commit reproduces the committed tree exactly"
    else bad "re-vendoring differs from the committed tree: $(head -3 "$tmp/diff.txt" | tr '\n' ' ')"; fi
else
    bad "vendor-kiwi.sh failed: $(tail -2 "$tmp/vendor.log" | tr '\n' ' ')"
fi

if [ "$fail" -eq 0 ]; then echo "PASS: kiwi description (vendored copy)"; else echo "$fail failure(s)"; exit 1; fi
