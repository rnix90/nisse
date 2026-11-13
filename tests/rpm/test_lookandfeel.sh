#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-lookandfeel RPM (the Nisse global themes and the system defaults, ledger N-108). Run in the
# Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-lookandfeel
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm_path="$(ls -v "$RPMS"/nisse-lookandfeel-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpm_path" ] || fail "nisse-lookandfeel RPM not found (run tools/rpm/build-rpm.sh nisse-lookandfeel)"

files="$(rpm -qlp "$rpm_path")"
LAF=/usr/share/plasma/look-and-feel
for id in org.nisse.desktop org.nisse.desktop.light; do
    for f in metadata.json contents/defaults \
             contents/plasmoidsetupscripts/org.kde.plasma.kickoff.js \
             contents/plasmoidsetupscripts/org.kde.plasma.kicker.js \
             contents/plasmoidsetupscripts/org.kde.plasma.kickerdash.js; do
        printf '%s\n' "$files" | grep -qxF "$LAF/$id/$f" || fail "look-and-feel RPM lacks $LAF/$id/$f"
    done
done
printf '%s\n' "$files" | grep -qxF /etc/xdg/kdeglobals || fail "look-and-feel RPM lacks /etc/xdg/kdeglobals (the system default)"
echo "ok   both look-and-feel packages and the system default are in the package"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpm_path" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)

# nothing in the package names Fedora's look-and-feel (it stays installed because plasma-workspace requires it,
# but it must never be our default or be copied into ours)
if grep -rqi "org.fedoraproject" "$scratch"; then fail "the package refers to a Fedora look-and-feel id"; fi
echo "ok   no Fedora look-and-feel id anywhere in the package"

# metadata ids match their folders (Plasma ignores a package whose id and folder differ)
for id in org.nisse.desktop org.nisse.desktop.light; do
    got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["KPlugin"]["Id"])' "$scratch$LAF/$id/metadata.json")"
    [ "$got" = "$id" ] || fail "$id/metadata.json has Id $got"
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["KPackageStructure"]=="Plasma/LookAndFeel"' \
        "$scratch$LAF/$id/metadata.json" || fail "$id/metadata.json is not a Plasma/LookAndFeel package"
done
echo "ok   metadata ids match the folders"

# the defaults each look applies: the Nisse scheme (which must exist in nisse-theme's source), Breeze shapes (ledger N-106)
want() { # file section key value
    awk -v s="[$2]" -v k="$3" -F= '$0 == s {in_s=1; next} /^\[/ {in_s=0} in_s && $1 == k {print $2}' "$1" | grep -qxF "$4" \
        || fail "$1 lacks $3=$4 under $2"
}
dark="$scratch$LAF/org.nisse.desktop/contents/defaults"
light="$scratch$LAF/org.nisse.desktop.light/contents/defaults"
want "$dark"  'kdeglobals][General' ColorScheme NisseEmber
want "$light" 'kdeglobals][General' ColorScheme NisseEmberLight
want "$dark"  'kdeglobals][Icons'   Theme breeze-dark
want "$light" 'kdeglobals][Icons'   Theme breeze
for f in "$dark" "$light"; do
    want "$f" 'kdeglobals][KDE' widgetStyle Breeze
    want "$f" 'kwinrc][org.kde.kdecoration2' library org.kde.breeze
    want "$f" 'kwinrc][org.kde.kdecoration2' theme Breeze
    want "$f" 'ksplashrc][KSplash' Theme org.kde.breeze.desktop
    want "$f" 'kcminputrc][Mouse' cursorTheme breeze_cursors
done
for n in NisseEmber NisseEmberLight; do
    [ -f "assets/theme/color-schemes/$n.colors" ] || fail "defaults name scheme $n but assets/theme/color-schemes/$n.colors is missing"
done
echo "ok   defaults name the Nisse schemes and the Breeze shapes"

# the system default for every new user
g="$scratch/etc/xdg/kdeglobals"
want "$g" KDE LookAndFeelPackage org.nisse.desktop
want "$g" General ColorScheme NisseEmber
want "$g" KDE widgetStyle Breeze
grep -qE '^font=Nunito,' "$g" || fail "system default font is not Nunito"
grep -qE '^fixed=Fira Code,' "$g" || fail "system default monospace font is not Fira Code"
echo "ok   system default is the Nisse dark look, Nunito and Fira Code"

# the start button icon script is Fedora's, unchanged in effect: it sets the icon to start-here, which nisse-branding owns
for id in org.nisse.desktop org.nisse.desktop.light; do
    for p in kickoff kicker kickerdash; do
        cmp -s "$scratch$LAF/$id/contents/plasmoidsetupscripts/org.kde.plasma.$p.js" assets/theme/lookandfeel/start-here-icon.js \
            || fail "$id $p setup script differs from assets/theme/lookandfeel/start-here-icon.js"
    done
done
grep -q 'writeConfig("icon", "start-here")' assets/theme/lookandfeel/start-here-icon.js || fail "start-here-icon.js does not set the start-here icon"
echo "ok   start button setup scripts match the one source file"

[ "$(rpm -qp --qf '%{LICENSE}' "$rpm_path")" = "GPL-2.0-or-later" ] || fail "look-and-feel License must be GPL-2.0-or-later"
[ "$(rpm -qp --qf '%{ARCH}' "$rpm_path")" = "noarch" ] || fail "look-and-feel must be noarch"
req="$(rpm -qp --requires "$rpm_path")"
for dep in nisse-theme plasma-workspace; do
    printf '%s\n' "$req" | grep -qxE "$dep( .*)?" || fail "look-and-feel RPM must require $dep"
done
echo "ok   requires nisse-theme and plasma-workspace"

out="$(rpmlint "$rpm_path" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"

echo "PASS: look-and-feel"
