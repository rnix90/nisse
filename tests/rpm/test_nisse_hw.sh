#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-hw RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-hw
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls out/rpmbuild/RPMS/noarch/nisse-hw-[0-9]*.rpm 2>/dev/null | head -1 || true)"
[ -n "$rpmf" ] || fail "nisse-hw RPM not found (run tools/rpm/build-rpm.sh nisse-hw)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-hwroute /usr/share/nisse/hw/profiles.toml /usr/lib/systemd/system/nisse-hwroute.service \
         /usr/lib/systemd/system-preset/81-nisse-hw.preset /usr/lib/systemd/system/nisse-hwroute-report.service          /usr/share/anaconda/post-scripts/90-nisse-hwroute.ks; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "RPM lacks $f"
done
printf '%s\n' "$files" | grep -qE '/site-packages/nisse_hw/route\.py$' || fail "RPM lacks the nisse_hw package"
printf '%s\n' "$files" | grep -qE '/site-packages/nisse_hw/detect\.py$' || fail "RPM lacks nisse_hw.detect"

member usr/lib/systemd/system-preset/81-nisse-hw.preset | grep -qx 'enable nisse-hwroute.service' || fail "preset must enable nisse-hwroute.service"
member usr/lib/systemd/system/nisse-hwroute.service | grep -qx 'ConditionKernelCommandLine=!rd.live.image' || fail "unit must skip live sessions"
member usr/lib/systemd/system-preset/81-nisse-hw.preset | grep -qx 'enable nisse-hwroute-report.service' || fail "preset must enable the live report unit"
report="$(member usr/lib/systemd/system/nisse-hwroute-report.service)"
printf '%s
' "$report" | grep -qx 'ConditionKernelCommandLine=rd.live.image' || fail "report unit must run only in live sessions"
printf '%s
' "$report" | grep -qx 'ExecStart=/usr/bin/nisse-hwroute --dry-run' || fail "report unit must only do a dry run"
member usr/share/anaconda/post-scripts/90-nisse-hwroute.ks | grep -q 'nisse-hwroute' || fail "anaconda post-script must call nisse-hwroute"
rpm -qp --requires "$rpmf" | grep -q 'dnf5-plugins' || fail "RPM must require dnf5-plugins (config-manager, copr)"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-hw"
