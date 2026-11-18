#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306d: the nisse-setup wizard starts and loads its QML (every page module) with no error. Run in the Fedora build VM (the
# Qt and KDE runtime libraries are there as build dependencies) after: tools/rpm/build-rpm.sh nisse-setup
# The RPM is extracted to a scratch directory and run on Qt's offscreen platform, so nothing is installed and the VM's own
# boot is untouched. A control run with the QML modules hidden must fail, which proves the check can fail.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

rpmf="$(ls -v out/rpmbuild/RPMS/x86_64/nisse-setup-[0-9]*.rpm 2>/dev/null | tail -1)"
[ -n "$rpmf" ] || { echo "FAIL: build nisse-setup first"; exit 1; }
s="$(mktemp -d)"
trap 'rm -rf "$s"' EXIT
(cd "$s" && rpm2cpio "$OLDPWD/$rpmf" | cpio -idm --quiet 2>/dev/null)
bin="$s/usr/libexec/nisse-setup"
[ -x "$bin" ] || { echo "FAIL: no $bin in the RPM"; exit 1; }
export XDG_RUNTIME_DIR="$s/run"; mkdir -m 700 -p "$XDG_RUNTIME_DIR"
export QT_QPA_PLATFORM=offscreen

errors='error|not installed|is not a type|cannot load|failed to|referenceerror|is not defined|unavailable|undefined is not'

# 1. the real run: stays up for 10 seconds (exit 124 from timeout) and prints no QML error
QML_IMPORT_PATH="$s/usr/lib64/qt6/qml" QT_PLUGIN_PATH="$s/usr/lib64/qt6/plugins" XDG_DATA_DIRS="$s/usr/share:/usr/share" \
    timeout 10 "$bin" > "$s/real.txt" 2>&1
rc=$?
[ "$rc" = 124 ] && ok "the wizard stays running (it started and showed its window)" || bad "the wizard exited with $rc: $(head -3 "$s/real.txt")"
if grep -qiE "$errors" "$s/real.txt"; then bad "errors on start: $(grep -iE "$errors" "$s/real.txt" | head -3)"; else ok "no QML or plugin error while it starts"; fi

# 2. the control: with the wizard's QML modules and pages hidden the same check must see a failure
XDG_DATA_DIRS="/usr/share" QML_IMPORT_PATH="" QT_PLUGIN_PATH="" timeout 10 "$bin" > "$s/control.txt" 2>&1
crc=$?
if [ "$crc" != 124 ] || grep -qiE "$errors" "$s/control.txt"; then ok "control: with the modules hidden the run fails or prints errors (exit $crc), so the check can fail"; else bad "control: the check passed with the modules hidden, so it proves nothing"; fi

# 3. the helper's names are consistent: the actions the program asks for are the ones the helper and polkit declare
ids="$(grep -rhoE 'org\.nisse\.setup\.[a-z]+' "$s/usr/share/polkit-1/rules.d" | sort -u)"
for a in $ids; do grep -q "action id=\"$a\"" "$s/usr/share/polkit-1/actions/org.nisse.setup.policy" && ok "polkit allows $a and the helper declares it" || bad "$a is allowed by polkit but not declared"; done
# Qt stores string literals as UTF-16: read the program's strings as 16-bit text as well as 8-bit
progstrings="$( (strings -a "$bin"; strings -a -e l "$bin") )"
grep -q 'org.nisse.setup' <<< "$progstrings" && ok "the program asks the helper org.nisse.setup" || bad "the program does not mention the helper id org.nisse.setup"
if grep -q 'org.kde.plasmasetup\.\(createuser\|createflagfile\|removeautologin\|setnewuser\)' <<< "$progstrings"; then bad "the program still asks a KDE action id"; else ok "the program asks no KDE action id"; fi
helper="$s/usr/libexec/kf6/kauth/nisse-setup-auth-helper"
strings "$helper" | grep -q 'org.nisse.setup' && ok "the helper answers to org.nisse.setup" || bad "the helper does not answer to org.nisse.setup"

echo
[ "$failures" = 0 ] && echo "PASS: nisse-setup starts and its names are consistent" || { echo "$failures failed"; exit 1; }
