#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-502: the nisse-grub-theme package carries the whole GRUB theme (theme.txt, the pictures, and the GRUB fonts it makes from the
# static Nunito files), and the fonts it makes carry the names theme.txt asks for. Run in the Fedora build VM:
#   tools/rpm/build-rpm.sh nisse-grub-theme && tests/rpm/test_nisse_grub_theme.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-grub-theme-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-grub-theme RPM not found (run tools/rpm/build-rpm.sh nisse-grub-theme)"
files="$(rpm -qlp "$rpmf")"
base=/usr/share/grub/themes/nisse

# the theme folder as the package installs it: theme.txt and the pictures from the repository, the GRUB fonts made at build time, and
# GRUB's own unicode.pf2 (the editor's font); the static Nunito files are only the source of the fonts, they are not installed
want="$(python3 - <<'PY'
import sys
sys.path.insert(0, "tools/art")
import grub_theme
for f in grub_theme.theme_files():
    if not f.endswith(".ttf"):
        print(f)
for name in grub_theme.font_names():
    print(name.lower().replace(" ", "-") + ".pf2")
print("unicode.pf2")
PY
)"
n=0
while read -r f; do
    printf '%s\n' "$files" | grep -qxF "$base/$f" || fail "RPM lacks $base/$f"
    n=$((n + 1))
done <<< "$want"
[ "$n" -ge 33 ] || fail "expected the theme files and the fonts, found $n names"
printf '%s\n' "$files" | grep -q '\.ttf$' && fail "the static Nunito sources must not be installed (they only make the .pf2 fonts)"
printf '%s\n' "$files" | grep -qxF /usr/share/licenses/nisse-grub-theme/OFL.txt || fail "the font license (OFL.txt) must travel with the package"
extra="$(printf '%s\n' "$files" | grep -vxF "$base" | grep -vF "$base/" | grep -v '^/usr/share/licenses/' || true)"
[ -z "$extra" ] || fail "the RPM owns more than the theme folder: $extra"
for parent in /usr/share/grub /usr/share/grub/themes; do
    printf '%s\n' "$files" | grep -qx "$parent" && fail "must not own $parent"
done
echo "ok   all $n theme files are in the package and nothing else"

# the fonts: GRUB names a font from its file ('<family> <style> <size>'), and theme.txt asks for exactly those names
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rpm2cpio "$rpmf" | (cd "$tmp" && cpio -idm --quiet)
for f in $(python3 -c 'import sys; sys.path.insert(0, "tools/art"); import grub_theme; print(*grub_theme.font_names(), sep="\n")' | tr ' ' '-' | tr 'A-Z' 'a-z'); do
    [ -s "$tmp$base/$f.pf2" ] || fail "$f.pf2 is missing or empty"
done
python3 - "$tmp$base" <<'PY' || fail "a font does not carry the name theme.txt asks for"
import pathlib, sys
sys.path.insert(0, "tools/art")
import grub_theme
d = pathlib.Path(sys.argv[1])
for name in grub_theme.font_names():
    data = (d / (name.lower().replace(" ", "-") + ".pf2")).read_bytes()
    assert data.startswith(b"FILE") and b"NAME" in data, name
    assert name.encode() in data, f"{name}: not named inside its .pf2"
uni = (d / "unicode.pf2").read_bytes()
assert grub_theme.TERMINAL_FONT.encode() in uni, "unicode.pf2 is not " + grub_theme.TERMINAL_FONT
PY
echo "ok   the GRUB fonts carry the names theme.txt asks for"

reqs="$(rpm -qp --requires "$rpmf")"
printf '%s\n' "$reqs" | grep -qxE "grub2-common( .*)?" || fail "must require grub2-common (it owns /usr/share/grub)"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
cmp -s "$tmp$base/theme.txt" assets/art/grub/nisse/theme.txt || fail "theme.txt differs from the committed one"
echo "ok   it requires grub2-common and installs the committed theme.txt"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-grub-theme"
