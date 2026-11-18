#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306d and N-306e: the nisse-setup wizard starts, loads EVERY page (KDE's eight and nisse's choices page), its helper names are
# consistent, and the choices page's backend runs the engine. Run in the Fedora build VM (the Qt and KDE runtime libraries are
# there as build dependencies; strace is installed if it is missing) after: tools/rpm/build-rpm.sh nisse-setup
# The RPM is extracted to a scratch directory and run on Qt's offscreen platform under a private session bus, so nothing is
# installed and the VM's own boot is untouched. The evidence is a system-call trace of the files the wizard opens and the
# programs it runs: a wizard that only sat waiting would show none of them. A control run with the QML modules hidden must fail.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

command -v strace >/dev/null 2>&1 || sudo dnf install -y strace >/dev/null 2>&1
command -v strace >/dev/null 2>&1 || { echo "FAIL: strace is not available"; exit 1; }
command -v dbus-run-session >/dev/null 2>&1 || { echo "FAIL: dbus-run-session is not available"; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/x86_64/nisse-setup-[0-9]*.rpm 2>/dev/null | tail -1)"
[ -n "$rpmf" ] || { echo "FAIL: build nisse-setup first"; exit 1; }
s="$(mktemp -d)"
trap 'rm -rf "$s"' EXIT
(cd "$s" && rpm2cpio "$OLDPWD/$rpmf" | cpio -idm --quiet 2>/dev/null)
bin="$s/usr/libexec/nisse-setup"
[ -x "$bin" ] || { echo "FAIL: no $bin in the RPM"; exit 1; }
export XDG_RUNTIME_DIR="$s/run"; mkdir -m 700 -p "$XDG_RUNTIME_DIR"
export QT_QPA_PLATFORM=offscreen

# a stand-in for nisse-choices: answers `list --json` with two choices
cat > "$s/fake-engine" <<'ENGINE'
#!/bin/sh
case "$1" in
  list) cat <<'JSON'
[{"id":"sudo-mode","title":"Administrator rights for the AI","description":"How it works.","stage":"firstboot","order":10,"kind":"enum",
  "options":[{"value":"full","title":"All passwordless","description":"No prompts."},{"value":"limited","title":"Limited, ask me","description":"A window asks."}],
  "default":"full","answer":null,"effective":"full","current":"full","state":null},
 {"id":"remote-login","title":"Remote login","description":"From another computer.","stage":"firstboot","order":20,"kind":"bool",
  "options":[],"default":false,"answer":null,"effective":false,"current":null,"state":null}]
JSON
  ;;
esac
ENGINE
chmod 755 "$s/fake-engine"

errors='error|not installed|is not a type|cannot load|failed to load|referenceerror|is not defined|undefined is not|module .* is not installed'

# 1. the real run, traced
QML_IMPORT_PATH="$s/usr/lib64/qt6/qml" QT_PLUGIN_PATH="$s/usr/lib64/qt6/plugins" XDG_DATA_DIRS="$s/usr/share:/usr/share" NISSE_CHOICES_COMMAND="$s/fake-engine" \
    dbus-run-session -- timeout 10 strace -f -e trace=openat,execve -o "$s/trace.txt" "$bin" > "$s/real.txt" 2>&1
[ -s "$s/trace.txt" ] && ok "the wizard ran under a private session bus (the trace has $(wc -l < "$s/trace.txt") calls)" || bad "no trace: $(head -3 "$s/real.txt")"
for page in account finished hostname keyboard language prepare time wifi; do
    grep -q "plasma/packages/org.kde.plasmasetup.$page/contents/ui/main.qml" "$s/trace.txt" && ok "loaded page $page" || bad "never opened the $page page"
done
grep -q 'plasma/packages/org.nisse.setup.choices/contents/ui/main.qml' "$s/trace.txt" && ok "loaded nisse's choices page" || bad "never opened the choices page"
grep -q 'nisse/setup/choicesutil/libplasmasetup_choicesutil.so' "$s/trace.txt" && ok "loaded the choicesutil QML module" || bad "never loaded the choicesutil module"
grep -qE 'execve\(".*/fake-engine", \["[^"]*fake-engine", "list", "--json", "--stage", "firstboot"\]' "$s/trace.txt" \
    && ok "the choices page's backend ran the engine as: list --json --stage firstboot" || bad "the engine was not run for the page: $(grep fake-engine "$s/trace.txt" | head -2)"
# the private bus also starts the desktop portal daemon, which complains about having no display: not the wizard
own="$(grep -v -E 'xdg-desktop-portal|dbus-daemon|Gtk-WARNING|^$' "$s/real.txt")"
if grep -iqE "$errors" <<< "$own"; then bad "errors while starting: $(grep -iE "$errors" <<< "$own" | head -3)"; else ok "no QML or plugin error from the wizard while it starts"; fi

# 2. the control: with the wizard's QML modules and pages hidden the same run must show none of that
XDG_DATA_DIRS="/usr/share" QML_IMPORT_PATH="" QT_PLUGIN_PATH="" NISSE_CHOICES_COMMAND="$s/fake-engine" \
    dbus-run-session -- timeout 10 strace -f -e trace=openat,execve -o "$s/ctrace.txt" "$bin" > "$s/control.txt" 2>&1
if grep -q 'plasma/packages/org.nisse.setup.choices/contents/ui/main.qml' "$s/ctrace.txt"; then bad "control: the choices page was still found with the modules hidden, so the trace proves nothing"; else ok "control: with the modules hidden no page is loaded, so the check can fail"; fi

# 3. the helper's names are consistent: the actions the program asks for are the ones the helper and polkit declare
ids="$(grep -rhoE 'org\.nisse\.setup\.[a-z]+' "$s/usr/share/polkit-1/rules.d" | sort -u)"
for a in $ids; do grep -q "action id=\"$a\"" "$s/usr/share/polkit-1/actions/org.nisse.setup.policy" && ok "polkit allows $a and the helper declares it" || bad "$a is allowed by polkit but not declared"; done
# Qt stores string literals as UTF-16: read the strings of the programs as 16-bit text as well as 8-bit
progstrings="$( (strings -a "$bin"; strings -a -e l "$bin"; strings -a -e l "$s"/usr/lib64/qt6/qml/org/nisse/setup/choicesutil/libplasmasetup_choicesutil.so) )"
grep -q 'org.nisse.setup' <<< "$progstrings" && ok "the program asks the helper org.nisse.setup" || bad "the program does not mention the helper id org.nisse.setup"
grep -q 'org.nisse.setup.setchoice' <<< "$progstrings" && ok "the choices page asks for the action org.nisse.setup.setchoice" || bad "no program asks for org.nisse.setup.setchoice"
if grep -q 'org.kde.plasmasetup\.\(createuser\|createflagfile\|removeautologin\|setnewuser\)' <<< "$progstrings"; then bad "a program still asks a KDE action id"; else ok "no program asks a KDE action id"; fi
helper="$s/usr/libexec/kf6/kauth/nisse-setup-auth-helper"
strings -a "$helper" | grep -q 'org.nisse.setup' && ok "the helper answers to org.nisse.setup" || bad "the helper does not answer to org.nisse.setup"
(strings -a "$helper"; strings -a -e l "$helper") | grep -q 'nisse-choices' && ok "the helper knows the engine nisse-choices" || bad "the helper does not mention nisse-choices"

echo
[ "$failures" = 0 ] && echo "PASS: nisse-setup loads every page, runs the engine for the choices page, and its names are consistent" || { echo "$failures failed"; exit 1; }
