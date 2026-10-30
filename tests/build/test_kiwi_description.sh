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

# Windows line endings would break config.sh and the other scripts inside the Linux build VM.
cr="$(printf '\r')"
crlf="$(grep -rlI "$cr" "$V" 2>/dev/null | head -3 | tr '\n' ' ')"
[ -z "$crlf" ] && ok "vendored files have Unix line endings" || bad "CRLF line endings in: $crlf"

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

# nisse-live.xml carries a hand-copy of Fedora's LiveInstall <packages type="iso"> block (the profile cannot be
# required without Fedora's volume id and publisher). This fails when a refresh of the vendored copy changes that
# block, so the copy gets re-merged on purpose instead of drifting.
iso_block() { # FILE : one line per child of every <packages type="iso">: tag, name, target
    "$py" -c '
import sys, xml.etree.ElementTree as E
for p in E.parse(sys.argv[1]).getroot().iter("packages"):
    if p.get("type") == "iso":
        for c in p:
            print(p.get("patternType"), c.tag, c.get("name"), c.get("target"))' "$1"
}
if diff <(iso_block "$V/components/liveinstall.xml") <(iso_block build/kiwi/nisse/components/nisse-live.xml) >"$tmp/isoblock.diff" 2>&1; then
    ok "nisse-live.xml's iso package block matches Fedora's liveinstall.xml"
else
    bad "nisse-live.xml's iso package block drifted from the vendored liveinstall.xml (re-merge it): $(head -4 "$tmp/isoblock.diff" | tr '\n' ' ')"
fi

# Licenses: the vendored XML files carry no header and upstream's COPYING is the GPL-3.0, so the Nisse file that copies a
# block from them is labelled GPL-3.0-only (never relabelled GPL-2.0-or-later), and the docs say the same thing.
grep -q 'SPDX-License-Identifier: GPL-3.0-only' build/kiwi/nisse/components/nisse-live.xml     && ok "nisse-live.xml is labelled GPL-3.0-only (it copies Fedora's GPL-3.0 block)"     || bad "nisse-live.xml must be labelled GPL-3.0-only (it copies Fedora's GPL-3.0 liveinstall.xml)"
grep -q 'build/kiwi/fedora' README.md && ok "README names build/kiwi/fedora as third-party" || bad "README does not list build/kiwi/fedora under third-party licenses"
if grep -q 'GPL-3.0-or-later' docs/build-host.md; then bad "docs/build-host.md claims GPL-3.0-or-later for the vendored files (upstream states GPL-3.0 in COPYING)"; else ok "build-host.md does not overstate the vendored license"; fi

# ---- part 2: the rendered Nisse description (needs kiwi-ng, so it runs in the build VM)
if command -v kiwi-ng >/dev/null 2>&1; then
    D=out/kiwi-description
    if bash build/render-kiwi.sh >"$tmp/render.log" 2>&1; then ok "render-kiwi.sh renders $D"
    else bad "render-kiwi.sh failed: $(tail -2 "$tmp/render.log" | tr '\n' ' ')"; fi

    # Selecting the profile makes kiwi resolve its "requires"; Fedora's config.sh keys off "Live" and "KDE" in that list.
    profiles="$(kiwi-ng --profile Nisse-Live --type iso image info --description "$D" --list-profiles 2>&1)"
    case "$profiles" in
        *"Selected profiles: Nisse-Live,"*KDE-Desktop*BootCoreLive*) ok "kiwi resolves Nisse-Live to KDE-Desktop + BootCoreLive";;
        *) bad "profile Nisse-Live did not resolve: $(echo "$profiles" | grep -E 'ERROR|Selected' | tail -2 | tr '\n' ' ')";;
    esac

    live="$D/nisse/components/nisse-live.xml"
    for p in nisse-release nisse-release-common nisse-branding nisse-fonts-nunito nisse-hw nisse-firstboot nisse-daemon nisse-panel anaconda-live; do
        grep -q "<package name=\"$p\"/>" "$live" && ok "Nisse-Live installs $p" || bad "Nisse-Live lacks $p"
    done
    for p in fedora-release-kde fedora-release; do
        if grep -q "<package name=\"$p\"/>" "$live"; then bad "Nisse-Live installs $p"; else ok "Nisse-Live does not install $p"; fi
    done

    repos="$D/nisse/repositories/nisse.xml"
    grep -q 'alias="fedora"' "$repos" && ok "repository alias fedora" || bad "no repository alias fedora"
    grep -q 'alias="nisse"' "$repos" && ok "repository alias nisse" || bad "no repository alias nisse"
    grep -q 'alias="updates"' "$repos" && bad "an updates repository is configured (release repo only)" || ok "no updates repository"
    grep -q 'volid="Nisse-44"' "$live" && ok "volid is Nisse-44" || bad "volid is not Nisse-44"
    if grep -rn '@[A-Z_]*@' "$D/Nisse.kiwi" "$D/nisse" >/dev/null 2>&1; then bad "unfilled @...@ placeholder"; else ok "no unfilled placeholder"; fi
else
    echo "skip part 2 (rendered description): kiwi-ng not installed; run this test in the build VM"
fi

if [ "$fail" -eq 0 ]; then echo "PASS: kiwi description"; else echo "$fail failure(s)"; exit 1; fi
