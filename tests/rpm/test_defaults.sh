#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-defaults RPM (the approved desktop defaults, docs/defaults.md, ledger N-111). Run in the Fedora
# build VM after:
#   tools/rpm/build-rpm.sh nisse-defaults
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm_path="$(ls -v "$RPMS"/nisse-defaults-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpm_path" ] || fail "nisse-defaults RPM not found (run tools/rpm/build-rpm.sh nisse-defaults)"

files="$(rpm -qlp "$rpm_path")"
printf '%s\n' "$files" | grep -qxF /etc/xdg/kwinrc || fail "defaults RPM lacks /etc/xdg/kwinrc"
echo "ok   the system kwinrc is in the package"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpm_path" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)

want() { # file section key value
    awk -v s="[$2]" -v k="$3" -F= '$0 == s {in_s=1; next} /^\[/ {in_s=0} in_s && $1 == k {print $2}' "$1" | grep -qxF "$4" \
        || fail "$1 lacks $3=$4 under $2"
}
# Night Light (approved line 3, changed at N-111): on, Plasma's own day-night schedule, 4500 K at night. The keys are the
# ones in Plasma 6.6.4's nightlightsettings.kcfg (group NightColor: Active, Mode, DayTemperature, NightTemperature).
k="$scratch/etc/xdg/kwinrc"
want "$k" NightColor Active true
want "$k" NightColor Mode DarkLight
want "$k" NightColor NightTemperature 4500
echo "ok   Night Light on, automatic schedule, 4500 K"

# the default terminal profile (ledger N-112): Fedora's konsole-part owns /etc/xdg/konsolerc, so ours lives in the
# kde-settings profile directory the Plasma session searches after /etc/xdg
kr=/usr/share/kde-settings/kde-profile/default/xdg/konsolerc
printf '%s\n' "$files" | grep -qxF "$kr" || fail "defaults RPM lacks $kr"
if printf '%s\n' "$files" | grep -qxF /etc/xdg/konsolerc; then fail "defaults RPM must not ship /etc/xdg/konsolerc (konsole-part owns it)"; fi
want "$scratch$kr" 'Desktop Entry' DefaultProfile Nisse.profile
echo "ok   the nisse terminal profile is the default"

# N-508: the mail suite is shipped but wired to nothing. Calendar Reminders (kalendarac, from akonadi-calendar) is the one PIM program
# that autostarts, and the autostart file asks "kalendaracrc:General:Autostart:true"; the system default says false.
printf '%s\n' "$files" | grep -qxF /etc/xdg/kalendaracrc || fail "defaults RPM lacks /etc/xdg/kalendaracrc"
want "$scratch/etc/xdg/kalendaracrc" General Autostart false
echo "ok   Calendar Reminders does not autostart (Autostart=false in the system kalendaracrc)"

# N-508: a package that cannot be dropped (something requires it) keeps its program but not its launcher entry: a file trigger sets
# NoDisplay=true in the entries listed in /usr/share/nisse/hidden-launchers.txt whenever they are installed or updated
printf '%s\n' "$files" | grep -qxF /usr/share/nisse/hidden-launchers.txt || fail "defaults RPM lacks the hidden launchers list"
grep -qxF org.kde.kwatchgnupg.desktop "$scratch/usr/share/nisse/hidden-launchers.txt" || fail "the GnuPG Log Viewer entry is not in the hidden list"
trig="$(rpm -qp --filetriggers "$rpm_path")"
grep -qF /usr/share/applications <<< "$trig" && grep -qF /usr/libexec/nisse-hide-launchers <<< "$trig" || fail "no file trigger on /usr/share/applications running nisse-hide-launchers"
hide="$scratch/usr/libexec/nisse-hide-launchers"
[ -x "$hide" ] || fail "nisse-hide-launchers is not executable"
apps="$scratch/usr/share/applications"; mkdir -p "$apps"
printf '[Desktop Entry]\nName=GnuPG Log Viewer\nName[de]=Protokoll\nExec=kwatchgnupg\nType=Application\n' > "$apps/org.kde.kwatchgnupg.desktop"
printf '[Desktop Entry]\nName=Kleopatra\nNoDisplay=false\nExec=kleopatra\n\n[Desktop Action x]\nName=Act\n' > "$apps/org.kde.kleopatra.desktop"
printf '[Desktop Entry]\nName=Other\nExec=other\nNoDisplay=false\n' > "$apps/other.desktop"
printf '%s\n' /usr/share/applications/org.kde.kwatchgnupg.desktop /usr/share/applications/other.desktop /usr/share/applications/gone.desktop | NISSE_ROOT="$scratch" "$hide"
grep -qxF 'NoDisplay=true' "$apps/org.kde.kwatchgnupg.desktop" || fail "the GnuPG Log Viewer entry is not hidden"
grep -qxF 'Name[de]=Protokoll' "$apps/org.kde.kwatchgnupg.desktop" && grep -qxF 'Exec=kwatchgnupg' "$apps/org.kde.kwatchgnupg.desktop" || fail "the hidden entry lost lines"
[ "$(grep -c '^NoDisplay' "$apps/org.kde.kwatchgnupg.desktop")" = 1 ] || fail "more than one NoDisplay line"
grep -qxF 'NoDisplay=false' "$apps/other.desktop" || fail "an entry that is not in the list was changed"
printf '%s\n' /usr/share/applications/org.kde.kwatchgnupg.desktop | NISSE_ROOT="$scratch" "$hide"      # an update fires the trigger again
[ "$(grep -c '^NoDisplay' "$apps/org.kde.kwatchgnupg.desktop")" = 1 ] || fail "the second run added a second NoDisplay line"
printf '[Desktop Entry]\nName=Log\nNoDisplay=false\nExec=kwatchgnupg\n' > "$apps/org.kde.kwatchgnupg.desktop"
printf '%s\n' /usr/share/applications/org.kde.kwatchgnupg.desktop | NISSE_ROOT="$scratch" "$hide"
grep -qxF 'NoDisplay=true' "$apps/org.kde.kwatchgnupg.desktop" && ! grep -qxF 'NoDisplay=false' "$apps/org.kde.kwatchgnupg.desktop" || fail "an entry that said NoDisplay=false was not turned off"
echo "ok   the launcher entries of kept-but-unwanted packages are hidden, once, and nothing else is touched"

# the lines the list keeps from Fedora must not be overridden here: this package sets only what changed
for bad in SingleClick loginMode VirtualKeyboardEnabled; do
    if grep -rq "$bad" "$scratch/etc"; then fail "the package overrides $bad (approved line: keep Fedora's value)"; fi
done
if grep -rq -i "baloo\|exclude folders" "$scratch/etc"; then fail "the package overrides the file indexing setting"; fi
echo "ok   only the changed lines are set"

[ "$(rpm -qp --qf '%{LICENSE}' "$rpm_path")" = "GPL-2.0-or-later" ] || fail "defaults License must be GPL-2.0-or-later"
[ "$(rpm -qp --qf '%{ARCH}' "$rpm_path")" = "noarch" ] || fail "defaults must be noarch"
for dep in kwin-common kde-settings nisse-theme nisse-release-common; do
    rpm -qp --requires "$rpm_path" | grep -qxE "$dep( .*)?" || fail "defaults RPM must require $dep"
done
echo "ok   requires kwin-common, kde-settings, nisse-theme and nisse-release-common"

out="$(rpmlint "$rpm_path" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"

echo "PASS: defaults"
