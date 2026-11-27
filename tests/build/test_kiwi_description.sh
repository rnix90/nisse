#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the kiwi description under build/kiwi/.
#   part 1 (always): the vendored Fedora copy is complete, well-formed, pinned and reproducible.
#   part 2 (when out/kiwi-description exists or kiwi-ng is installed): the rendered nisse description.
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

# Licenses: the vendored XML files carry no header and upstream's COPYING is the GPL-3.0, so the nisse file that copies a
# block from them is labelled GPL-3.0-only (never relabelled GPL-2.0-or-later), and the docs say the same thing.
grep -q 'SPDX-License-Identifier: GPL-3.0-only' build/kiwi/nisse/components/nisse-live.xml     && ok "nisse-live.xml is labelled GPL-3.0-only (it copies Fedora's GPL-3.0 block)"     || bad "nisse-live.xml must be labelled GPL-3.0-only (it copies Fedora's GPL-3.0 liveinstall.xml)"
grep -q 'build/kiwi/fedora' README.md && ok "README names build/kiwi/fedora as third-party" || bad "README does not list build/kiwi/fedora under third-party licenses"
if grep -q 'GPL-3.0-or-later' docs/build-host.md; then bad "docs/build-host.md claims GPL-3.0-or-later for the vendored files (upstream states GPL-3.0 in COPYING)"; else ok "build-host.md does not overstate the vendored license"; fi

# Values are substituted into XML attributes: sed metacharacters (| & \) must stay literal and XML metacharacters
# (& < > ") must be escaped, or the rendered description is wrong or not even well-formed.
r="$tmp/render"
mkdir -p "$r/tools/build" && cp -a build "$r/build" && cp tools/build/apply_drops.py "$r/tools/build/"   # render-kiwi.sh runs tools/build/apply_drops.py (N-508)
cmd='quiet a|b&c\d "q" <x>'
if NISSE_KERNELCMDLINE="$cmd" NISSE_REPO_URL='dir:///re|po&x' bash "$r/build/render-kiwi.sh" >"$tmp/render-odd.log" 2>&1; then
    rl="$r/out/kiwi-description/nisse/components/nisse-live.xml"
    grep -qF 'kernelcmdline="quiet a|b&amp;c\d &quot;q&quot; &lt;x&gt;"' "$rl" \
        && ok "render-kiwi.sh keeps | & and backslash literal and XML-escapes the kernel command line" \
        || bad "render-kiwi.sh mangled the kernel command line: $(grep -o 'kernelcmdline="[^"]*"' "$rl" | head -1)"
    grep -qF 'path="dir:///re|po&amp;x"' "$r/out/kiwi-description/nisse/repositories/nisse.xml" \
        && ok "render-kiwi.sh substitutes an odd repository path literally" \
        || bad "render-kiwi.sh mangled the repository path"
    xmlodd="$(find "$r/out/kiwi-description" -name '*.xml' -o -name '*.kiwi' | xargs "$py" -c '
import sys, xml.etree.ElementTree as E
for f in sys.argv[1:]:
    try:
        E.parse(f)
    except Exception as e:
        print(f, e)')"
    [ -z "$xmlodd" ] && ok "the description with odd values is still well-formed XML" || bad "malformed XML after rendering odd values: $xmlodd"
else
    bad "render-kiwi.sh failed on odd values: $(tail -2 "$tmp/render-odd.log" | tr '\n' ' ')"
fi

# Modes: three vendored files are executable upstream; Windows git drops the bit, so check the index.
if git rev-parse --git-dir >/dev/null 2>&1; then
    for f in config.sh editbootinstall_rpilegacy.sh root/etc/fstab.script; do
        mode="$(git ls-files -s "$V/$f" | cut -d' ' -f1)"
        [ "$mode" = 100755 ] && ok "$f is mode 100755 in git" || bad "$f is mode $mode in git, upstream has 100755"
    done
else
    echo "skip modes: not a git checkout (the build VM copy has no .git); the host run checks them"
fi

tmp0="$(mktemp -u)"
# N-502: the ISO's boot menu is nisse's own template (the vendored Fedora one stays as published) and the nisse GRUB theme comes with it
T=build/kiwi/nisse/grub-x86.cfg.iso-template
live=build/kiwi/nisse/components/nisse-live.xml
[ -f "$T" ] && ok "nisse has its own ISO menu template" || bad "no $T"
grep -q 'grub_template="nisse/grub-x86.cfg.iso-template"' "$live" && ok "nisse-live.xml uses the nisse menu template" || bad "nisse-live.xml does not use the nisse menu template"
grep -q '<bootloader-theme>nisse</bootloader-theme>' "$live" && ok "kiwi is told to copy the nisse boot theme to the ISO" || bad "nisse-live.xml lacks <bootloader-theme>nisse</bootloader-theme>"
grep -q '<package name="nisse-grub-theme"/>' "$live" && ok "Nisse-Live installs nisse-grub-theme" || bad "Nisse-Live lacks nisse-grub-theme"
for entry in 'menuentry " *nisse" ' 'menuentry " *Computer Settings"' 'submenu " *More Ways to Start"' 'menuentry " *Check This Media and Start nisse"' 'menuentry " *Start nisse in Basic Graphics Mode"'; do
    grep -qE "$entry" "$T" && ok "the menu has $entry (titles are padded to center them)" || bad "the menu lacks $entry"
done
if grep -qE 'menuentry "Start nisse"|menuentry "Test this media|submenu "Troubleshooting|-->' "$T"; then bad "the menu still has a stock Fedora-style entry or an arrow"; else ok "no stock entry names, no arrows"; fi
grep -q 'set default="0"' "$T" && ok "the default entry is the first one, nisse" || bad "the default entry is not the first"
grep -q -- '-f \$\${nisse_theme}/theme.txt' "$T" && ok "the theme is used only when it is on the media (else the plain text menu)" || bad "the template does not check that the theme is there"
grep -q 'set gfxmode=1920x1080' "$T" && ok "GRUB is asked for 1920x1080 first" || bad "no gfxmode request"
for f in unicode.pf2 nunito-regular-28.pf2 nunito-semibold-regular-28.pf2 nunito-regular-22.pf2 nunito-regular-18.pf2; do
    grep -q "loadfont .*/$f" "$T" && ok "the menu loads $f" || bad "the menu does not load $f"
done
# kiwi fills the template with Python's string.Template: a stray dollar sign (a comment that quotes the form, a bare variable) is an error there
"$py" -c '
import string, sys
string.Template(open(sys.argv[1], encoding="ascii").read()).substitute(
    search_params="x", terminal_output="console", boot_timeout="10", boot_timeout_style="menu", bootpath="/b", kernel_file="k",
    initrd_file="i", boot_options="o")' "$T" >/dev/null 2>"$tmp0.err"     && ok "the menu template fills in with kiwi's variable names and no stray dollar sign" || bad "the menu template does not fill in like kiwi does: $(tail -1 "$tmp0.err")"
rm -f "$tmp0.err"
if LC_ALL=C grep -q '[^ -~[:space:]]' "$T"; then bad "the menu template has non-ASCII characters"; else ok "the menu template is ASCII"; fi

# ---- part 2: the rendered nisse description (needs kiwi-ng, so it runs in the build VM)
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
    for p in nisse-release nisse-release-common nisse-branding nisse-fonts-nunito nisse-theme nisse-wallpaper nisse-cursors nisse-icons nisse-sounds nisse-lookandfeel nisse-defaults nisse-hw nisse-installer nisse-snapshots nisse-boot nisse-update nisse-sudo nisse-choices nisse-setup nisse-avatars nisse-firstboot nisse-daemon nisse-panel nisse-plymouth anaconda-live; do
        grep -q "<package name=\"$p\"/>" "$live" && ok "Nisse-Live installs $p" || bad "Nisse-Live lacks $p"
    done
    for p in fedora-release-kde fedora-release generic-logos fedora-logos plasma-setup kde-settings-plasmalogin; do
        if grep -q "<package name=\"$p\"/>" "$live"; then bad "Nisse-Live installs $p"; else ok "Nisse-Live does not install $p"; fi
    done

    # N-508: dnf5 refuses to install a package it is told to exclude, so no dropped app may also be listed by name (Fedora's own lists
    # name mediawriter): render-kiwi.sh takes those lines out of the rendered copy, and each drop is ignored.
    listed_and_dropped=""
    while IFS='|' read -r kind pkg rest; do
        [ "$kind" = drop ] || continue
        grep -rq "<package name=\"$pkg\"/>" "$D" && listed_and_dropped="$listed_and_dropped $pkg"
        grep -q "<ignore name=\"$pkg\"/>" "$live" || bad "the dropped $pkg is not ignored in the rendered nisse-live.xml"
    done < build/default-apps.txt
    [ -z "$listed_and_dropped" ] && ok "no dropped app is also listed by name in the rendered description" || bad "dropped but still listed by name (dnf5 would refuse the install):$listed_and_dropped"

    [ -f "$D/nisse/grub-x86.cfg.iso-template" ] && ok "the rendered description carries the nisse menu template" || bad "the rendered description lacks nisse/grub-x86.cfg.iso-template"
    if command -v grub2-script-check >/dev/null 2>&1; then
        "$py" tests/build/render_menu.py "$D/nisse/grub-x86.cfg.iso-template" > "$tmp/menu.cfg" 2>"$tmp/menu.err"             && grub2-script-check "$tmp/menu.cfg" >"$tmp/menu.chk" 2>&1             && ok "the filled-in menu passes grub2-script-check" || bad "the menu template does not pass grub2-script-check: $(tail -2 "$tmp/menu.err" "$tmp/menu.chk" | tr '
' ' ')"
    else
        echo "skip grub2-script-check: not installed here"
    fi
    repos="$D/nisse/repositories/nisse.xml"
    grep -q 'alias="fedora"' "$repos" && ok "repository alias fedora" || bad "no repository alias fedora"
    grep -q 'alias="nisse"' "$repos" && ok "repository alias nisse" || bad "no repository alias nisse"
    grep -rq 'alias="updates"' "$D" && bad "an updates repository is configured somewhere in the description (release repo only)" || ok "no updates repository"
    prod="$(tr -d '[:space:]' < build/PRODUCT_VERSION)"
    grep -q "volid=\"nisse-$prod\"" "$live" && ok "volid is nisse-$prod" || bad "volid is not nisse-$prod"
    # N-501: a serial console on the kernel line makes Plymouth fall back to its plain text theme ("serial consoles detected, managing
    # them with details forced"), so the boot screen would never show; this option keeps the serial console for the smoke test
    # and still lets the splash draw
    grep -q 'kernelcmdline="[^"]*plymouth.ignore-serial-consoles' "$live" && ok "the default kernel line lets Plymouth draw with a serial console on" || bad "the default kernel line lacks plymouth.ignore-serial-consoles: a serial console would force Plymouth's text theme"
    grep -q "volid=\"nisse-$(tr -d '[:space:]' < build/FEDORA_RELEASE)\"" "$live" && bad "the volid still uses the Fedora base release" || ok "the volid does not use the Fedora base release"
    if grep -rn '@[A-Z_]*@' "$D/Nisse.kiwi" "$D/nisse" >/dev/null 2>&1; then bad "unfilled @...@ placeholder"; else ok "no unfilled placeholder"; fi
else
    echo "skip part 2 (rendered description): kiwi-ng not installed; run this test in the build VM"
fi

if [ "$fail" -eq 0 ]; then echo "PASS: kiwi description"; else echo "$fail failure(s)"; exit 1; fi
