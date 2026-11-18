#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-setup RPM (the nisse fork of Plasma Setup). Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-setup
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/x86_64/nisse-setup-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-setup RPM not found (run tools/rpm/build-rpm.sh nisse-setup)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }
files="$(rpm -qlp "$rpmf")"

for f in /etc/xdg/nissesetuprc /usr/lib/systemd/system/nisse-setup.service /usr/lib/sysusers.d/nisse-setup-sysuser.conf \
         /usr/lib/tmpfiles.d/nisse-setup-tmpfiles.conf /usr/lib/systemd/system-preset/86-nisse-setup.preset \
         /usr/share/dbus-1/system-services/org.nisse.setup.service /usr/share/dbus-1/system.d/org.nisse.setup.conf \
         /usr/share/polkit-1/actions/org.nisse.setup.policy /usr/share/polkit-1/rules.d/nisse-setup-polkit.rules \
         /usr/share/nisse-setup/nisse-setup.desktop /usr/share/nisse-setup/kglobalaccelrc \
         /usr/lib64/qt6/plugins/kf6/packagestructure/plasmasetup.so; do
    grep -qxF "$f" <<< "$files" || fail "RPM lacks $f"
done
grep -qxE '/usr/libexec/nisse-setup' <<< "$files" || fail "RPM lacks /usr/libexec/nisse-setup"
grep -qxE '/usr/libexec/nisse-setup-bootutil' <<< "$files" || fail "RPM lacks /usr/libexec/nisse-setup-bootutil"
grep -qxE '/usr/libexec/kf6/kauth/nisse-setup-auth-helper' <<< "$files" || fail "RPM lacks the privileged helper"

# nothing of KDE's wizard is installed under its own system-visible names (it would collide with plasma-setup)
for old in /usr/libexec/plasma-setup /usr/lib/systemd/system/plasma-setup.service /etc/xdg/plasmasetuprc \
           /usr/share/polkit-1/actions/org.kde.plasmasetup.policy /usr/lib/sysusers.d/plasma-setup-sysuser.conf; do
    grep -qxF "$old" <<< "$files" && fail "the RPM still installs $old"
done

# it replaces plasma-setup
prov="$(rpm -qp --provides "$rpmf")"; obs="$(rpm -qp --obsoletes "$rpmf")"
grep -qE '^plasma-setup = 6\.8\.3' <<< "$prov" || fail "nisse-setup must provide plasma-setup"
grep -qE '^plasma-setup < 7' <<< "$obs" || fail "nisse-setup must obsolete plasma-setup < 7"
reqs="$(rpm -qp --requires "$rpmf")"
for r in nisse-wallpaper nisse-lookandfeel kf6-kauth dbus-common; do grep -qx "$r" <<< "$reqs" || fail "nisse-setup must require $r"; done

# the unit: before the login screen, never on live media, never again once finished
unit="$(member usr/lib/systemd/system/nisse-setup.service)"
for want in 'Before=display-manager.service' 'ConditionPathExists=!/etc/nisse-setup-done' 'ConditionKernelCommandLine=!rd.live.image' \
            'ExecStart=/usr/libexec/nisse-setup-bootutil' 'Type=oneshot' 'WantedBy=multi-user.target'; do
    grep -qx "$want" <<< "$unit" || fail "nisse-setup.service lacks: $want"
done
grep -qx 'enable nisse-setup.service' <<< "$(member usr/lib/systemd/system-preset/86-nisse-setup.preset)" || fail "the preset must enable nisse-setup.service"
grep -qE '^u nisse-setup ' <<< "$(member usr/lib/sysusers.d/nisse-setup-sysuser.conf)" || fail "sysusers must create the user nisse-setup"
tmp="$(member usr/lib/tmpfiles.d/nisse-setup-tmpfiles.conf)"
grep -q '/run/nisse-setup' <<< "$tmp" && ! grep -q 'plasma-setup' <<< "$tmp" || fail "tmpfiles must use /run/nisse-setup and no plasma-setup path"
grep -q 'nisse-setup nisse-setup' <<< "$tmp" || fail "tmpfiles must hand /run/nisse-setup to the user nisse-setup"

# polkit: only the wizard's user, only actions the helper really declares
rules="$(member usr/share/polkit-1/rules.d/nisse-setup-polkit.rules)"
grep -q 'subject.user !== "nisse-setup"' <<< "$rules" || fail "the polkit rule must be for the user nisse-setup only"
policy="$(member usr/share/polkit-1/actions/org.nisse.setup.policy)"
declared="$(grep -o 'action id="org\.nisse\.setup\.[a-z]*"' <<< "$policy" | sed 's/.*id="//; s/"//' | sort -u)"
allowed="$(grep -o '"org\.nisse\.setup\.[a-z]*"' <<< "$rules" | tr -d '"' | sort -u)"
[ -n "$allowed" ] || fail "the polkit rule allows no nisse-setup action"
while read -r a; do
    grep -qx "$a" <<< "$declared" || fail "the polkit rule allows $a, which the helper does not declare"
done <<< "$allowed"
grep -q 'org.kde.plasmasetup.' <<< "$rules" && fail "the polkit rule still names a KDE action"
dbus="$(member usr/share/dbus-1/system-services/org.nisse.setup.service)"
grep -q 'nisse-setup-auth-helper' <<< "$dbus" || fail "the helper's D-Bus service must start nisse-setup-auth-helper"

# every KPackage page the wizard discovers is there (KDE's modules, KDE/PlasmaSetup)
for page in account finished hostname keyboard language prepare time wifi; do
    grep -qx "/usr/share/plasma/packages/org.kde.plasmasetup.$page/metadata.json" <<< "$files" || fail "page $page is missing"
done

if command -v systemd-analyze >/dev/null 2>&1; then
    scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
    rpm2cpio "$rpmf" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
    out="$(systemd-analyze verify "$scratch/usr/lib/systemd/system/nisse-setup.service" 2>&1 | grep -v -E 'is not executable|Failed to prepare filename|^$' || true)"
    [ -z "$out" ] || fail "systemd-analyze verify: $out"
fi

out="$(rpmlint -r tests/rpm/nisse-setup.rpmlintrc "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-setup"
