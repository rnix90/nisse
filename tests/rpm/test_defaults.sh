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

# the lines the list keeps from Fedora must not be overridden here: this package sets only what changed
for bad in SingleClick loginMode VirtualKeyboardEnabled; do
    if grep -rq "$bad" "$scratch/etc"; then fail "the package overrides $bad (approved line: keep Fedora's value)"; fi
done
if grep -rq -i "baloo\|exclude folders" "$scratch/etc"; then fail "the package overrides the file indexing setting"; fi
echo "ok   only the changed lines are set"

[ "$(rpm -qp --qf '%{LICENSE}' "$rpm_path")" = "GPL-2.0-or-later" ] || fail "defaults License must be GPL-2.0-or-later"
[ "$(rpm -qp --qf '%{ARCH}' "$rpm_path")" = "noarch" ] || fail "defaults must be noarch"
rpm -qp --requires "$rpm_path" | grep -qx 'kwin-common\( .*\)\?' || fail "defaults RPM must require kwin-common (it owns the Night Light schema)"
echo "ok   requires kwin-common"

out="$(rpmlint "$rpm_path" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"

echo "PASS: defaults"
