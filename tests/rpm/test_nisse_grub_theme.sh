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
extra="$(printf '%s\n' "$files" | grep -vxF "$base" | grep -vF "$base/" | grep -v '^/usr/share/licenses/' | grep -vxF /etc/grub.d/01_nisse_theme | grep -vxF /usr/libexec/nisse/nisse-grub-theme-install | grep -vxF /usr/libexec/nisse || true)"
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

# the installed system (N-502): a snippet for grub2-mkconfig turns the theme on, and an install step puts the theme where GRUB reads it
# (the boot partition: GRUB must not depend on the root subvolume, which a rollback swaps)
for f in /etc/grub.d/01_nisse_theme /usr/libexec/nisse/nisse-grub-theme-install; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "RPM lacks $f"
done
modes="$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpmf")"
for f in /etc/grub.d/01_nisse_theme /usr/libexec/nisse/nisse-grub-theme-install; do
    grep -q "^-rwxr-xr-x $f\$" <<< "$modes" || fail "$f must be mode 0755"
done
snip="$tmp/etc/grub.d/01_nisse_theme"
out="$tmp/01.cfg"
NISSE_GRUB_THEME_INSTALL=/nonexistent GRUB_TERMINAL_OUTPUT=console sh "$snip" > "$out" || fail "01_nisse_theme does not run"
command -v grub2-script-check >/dev/null 2>&1 && { grub2-script-check "$out" || fail "grub2-script-check rejects the output of 01_nisse_theme"; }
grep -qF 'set theme=${prefix}/themes/nisse/theme.txt' "$out" || fail "01_nisse_theme does not set the theme from the boot partition's grub folder"
grep -qxE '  terminal_output gfxterm' "$out" || fail "01_nisse_theme must switch the terminal to gfxterm (and only that, on a normal machine)"
for font in $(python3 -c 'import sys; sys.path.insert(0, "tools/art"); import grub_theme; print(*[n.lower().replace(" ", "-") for n in grub_theme.font_names()], "unicode", sep="\n")'); do
    grep -qF "loadfont \${prefix}/themes/nisse/$font.pf2" "$out" || fail "01_nisse_theme does not load $font.pf2"
done
grep -qF 'if [ -f ${prefix}/themes/nisse/theme.txt ]; then' "$out" || fail "01_nisse_theme must only use the theme when it is on the boot partition (else the plain menu)"
NISSE_GRUB_THEME_INSTALL=/nonexistent GRUB_TERMINAL="serial console" sh "$snip" > "$tmp/01-serial.cfg"
grep -qxE '  terminal_output gfxterm serial' "$tmp/01-serial.cfg" || fail "with a serial console configured the menu must also stay on the serial port (terminal_output gfxterm serial)"
echo "ok   01_nisse_theme turns the theme on, keeps a serial console, and only when the theme is there"

inst="$tmp/usr/libexec/nisse/nisse-grub-theme-install"
sh -n "$inst" || fail "the install step has a syntax error"
sandbox="$tmp/sandbox"; mkdir -p "$sandbox/boot"
NISSE_GRUB_THEME_SRC="$tmp$base" NISSE_BOOT_DIR="$sandbox/boot" sh "$inst" || fail "the install step failed"
for f in theme.txt logo.png unicode.pf2 nunito-bold-32.pf2 select_nw.png; do
    cmp -s "$tmp$base/$f" "$sandbox/boot/grub2/themes/nisse/$f" || fail "the install step did not copy $f to /boot/grub2/themes/nisse"
done
echo broken > "$sandbox/boot/grub2/themes/nisse/theme.txt"
NISSE_GRUB_THEME_SRC="$tmp$base" NISSE_BOOT_DIR="$sandbox/boot" sh "$inst"
cmp -s "$tmp$base/theme.txt" "$sandbox/boot/grub2/themes/nisse/theme.txt" || fail "the install step did not repair a changed theme file"
NISSE_GRUB_THEME_SRC="$tmp/nonexistent" NISSE_BOOT_DIR="$sandbox/boot" sh "$inst" && ok_missing=1 || fail "a missing source theme must not be an error (nothing to install)"
scripts="$(rpm -qp --scripts "$rpmf")"
grep -q 'nisse-grub-theme-install' <<< "$scripts" || fail "the package must run the install step after it is installed or updated"
echo "ok   the install step copies the theme to /boot/grub2/themes/nisse, repairs it, and a missing source is not an error"

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
