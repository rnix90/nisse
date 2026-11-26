#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-501: the nisse-plymouth package carries the whole boot theme, needs the script plugin, and its install step makes "nisse" the
# default theme (checked in a sandbox with Plymouth's own chooser, plymouth-set-default-theme). Run in the Fedora build VM:
#   tools/rpm/build-rpm.sh nisse-plymouth && tests/rpm/test_nisse_plymouth.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-plymouth-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-plymouth RPM not found (run tools/rpm/build-rpm.sh nisse-plymouth)"
files="$(rpm -qlp "$rpmf")"
base=/usr/share/plymouth/themes/nisse

# every file of the theme folder is in the package, and nothing else is
want="$(python3 - <<'PY'
import sys
sys.path.insert(0, "tools/art")
import plymouth_theme
for f in plymouth_theme.theme_files():
    print(f)
PY
)"
n=0
while read -r f; do
    printf '%s\n' "$files" | grep -qxF "$base/$f" || fail "RPM lacks $base/$f"
    n=$((n + 1))
done <<< "$want"
[ "$n" -ge 50 ] || fail "expected the theme files and 48 bar frames, found $n names"
extra="$(printf '%s\n' "$files" | grep -vxF "$base" | grep -vF "$base/" | grep -v '^/usr/share/licenses/' || true)"
[ -z "$extra" ] || fail "the RPM owns more than the theme folder: $extra"
printf '%s\n' "$files" | grep -qx '/usr/share/plymouth/themes' && fail "must not own /usr/share/plymouth/themes"
echo "ok   all $n theme files are in the package and nothing else"

reqs="$(rpm -qp --requires "$rpmf")"
for r in plymouth plymouth-scripts plymouth-plugin-script; do
    printf '%s\n' "$reqs" | grep -qxE "$r( .*)?" || fail "must require $r"
done
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
echo "ok   it requires the script plugin and Plymouth's chooser"

# the install step: in a sandbox (Plymouth's chooser honors these folders), "nisse" becomes the default theme on a first install,
# and a reinstall or upgrade leaves the administrator's own choice alone
tmp="$(mktemp -d)"; trap 'sudo rm -rf "$tmp"' EXIT
rpm2cpio "$rpmf" | (cd "$tmp" && cpio -idm --quiet)
command -v plymouth-set-default-theme >/dev/null || fail "plymouth-set-default-theme not installed here (sudo dnf install plymouth-scripts plymouth-plugin-script)"
scriptlet="$(rpm -qp --qf '%{POSTIN}' "$rpmf")"
[ -n "$scriptlet" ] || fail "the package has no install step: nothing makes nisse the default theme"
sandbox() {   # sandbox N: run the install step with $1 (1 = first install, 2 = upgrade) against the sandbox root
    mkdir -p "$tmp/etc/plymouth" "$tmp/usr/share/plymouth/themes"
    [ -f "$tmp/usr/share/plymouth/plymouthd.defaults" ] || printf '[Daemon]\nTheme=bgrt\n' > "$tmp/usr/share/plymouth/plymouthd.defaults"
    # Plymouth's chooser refuses to run as anyone but root, as the package's own install step does
    sudo env PLYMOUTH_DATADIR="$tmp/usr/share" PLYMOUTH_CONFDIR="$tmp/etc/plymouth/" PLYMOUTH_POLICYDIR="$tmp/usr/share/plymouth/" \
        PLYMOUTH_PLUGIN_PATH=/usr/lib64/plymouth/ sh -c "$scriptlet" sh "$1" > "$tmp/scriptlet.out" 2>&1 \
        || { cat "$tmp/scriptlet.out" >&2; fail "the install step failed"; }
}
mkdir -p "$tmp/etc/plymouth"
printf '# Administrator customizations go in this file\n#[Daemon]\n#Theme=fade-in\n' > "$tmp/etc/plymouth/plymouthd.conf"
sandbox 1
grep -qx 'Theme=nisse' "$tmp/etc/plymouth/plymouthd.conf" || { cat "$tmp/etc/plymouth/plymouthd.conf" >&2; fail "a first install did not make nisse the default theme"; }
sudo rm -f "$tmp/etc/plymouth/plymouthd.conf"
printf '[Daemon]\nTheme=spinner\n' > "$tmp/etc/plymouth/plymouthd.conf"
sandbox 2
grep -qx 'Theme=spinner' "$tmp/etc/plymouth/plymouthd.conf" || fail "an upgrade overrode the administrator's own theme choice"
echo "ok   a first install makes nisse the default theme; an upgrade leaves a chosen theme alone"

# Plymouth lists it
PLYMOUTH_DATADIR="$tmp/usr/share" PLYMOUTH_PLUGIN_PATH=/usr/lib64/plymouth/ plymouth-set-default-theme --list | grep -qx nisse \
    || fail "Plymouth's chooser does not list the theme"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-plymouth"
