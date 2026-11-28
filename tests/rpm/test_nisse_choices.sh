#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-choices RPM, and that every choice manifest shipped by any built nisse package is valid.
# Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-choices && tools/rpm/build-rpm.sh nisse-sudo
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/x86_64/nisse-choices-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-choices RPM not found (run tools/rpm/build-rpm.sh nisse-choices)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/lib/systemd/system/nisse-choices-apply.service /usr/lib/systemd/system-preset/84-nisse-choices.preset \
         /usr/share/nisse/choices.d /var/lib/nisse/choices; do
    grep -qxF "$f" <<< "$files" || fail "RPM lacks $f"
done
grep -qxE '/usr/(s)?bin/nisse-choices' <<< "$files" || fail "RPM lacks the nisse-choices command"

# The first-boot apply: after the wizard, before login, never on live media, applies at every boot.
unit="$(member usr/lib/systemd/system/nisse-choices-apply.service)"
for want in 'Type=oneshot' 'ExecStart=/usr/bin/nisse-choices apply --boot' 'Before=display-manager.service' 'ConditionKernelCommandLine=!rd.live.image' 'WantedBy=multi-user.target'; do
    grep -qx "$want" <<< "$unit" || fail "nisse-choices-apply.service lacks: $want"
done
grep -qE '^After=.*nisse-setup.service' <<< "$unit" || fail "the apply service must run after the first-boot wizard"
grep -qx 'enable nisse-choices-apply.service' <<< "$(member usr/lib/systemd/system-preset/84-nisse-choices.preset)" || fail "preset must enable the apply service"

if command -v systemd-analyze >/dev/null 2>&1; then
    scratch0="$(mktemp -d)"
    rpm2cpio "$rpmf" | (cd "$scratch0" && cpio -idm --quiet 2>/dev/null)
    out="$(systemd-analyze verify "$scratch0/usr/lib/systemd/system/nisse-choices-apply.service" 2>&1 | grep -v -E 'is not executable|Failed to prepare filename|nisse-setup.service|^$' || true)"
    rm -rf "$scratch0"
    [ -z "$out" ] || fail "systemd-analyze verify: $out"
fi

# Every manifest any built nisse package ships must pass the engine's own validation (the packaged binary).
scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpmf" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
bin="$(ls "$scratch"/usr/bin/nisse-choices "$scratch"/usr/sbin/nisse-choices 2>/dev/null | head -1 || true)"
[ -x "$bin" ] || fail "cannot find the extracted nisse-choices command"
all="$scratch/all-choices.d"; mkdir -p "$all"
shipped=0
for pkg in out/rpmbuild/RPMS/*/nisse-*.rpm; do
    [ -e "$pkg" ] || continue
    for m in $(rpm -qlp "$pkg" | grep '^/usr/share/nisse/choices\.d/.*\.toml$' || true); do
        rpm2cpio "$pkg" | cpio -i --to-stdout --quiet ".$m" > "$all/$(basename "$m")"
        shipped=$((shipped + 1))
    done
done
echo "manifests shipped by built packages: $shipped"
out="$("$bin" validate "$all" 2>&1)" || fail "validate: $out"
echo "$out"
if ls out/rpmbuild/RPMS/noarch/nisse-sudo-[0-9]*.rpm >/dev/null 2>&1; then
    [ -f "$all/10-sudo-mode.toml" ] || fail "nisse-sudo must ship the sudo-mode choice"
    NISSE_CHOICES_MANIFESTS="$all" NISSE_CHOICES_DIR="$scratch/state" "$bin" list | grep -q '^sudo-mode ' || fail "the engine does not list sudo-mode"
fi

[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-choices"
