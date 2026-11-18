#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-update RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-update
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-update-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-update RPM not found (run tools/rpm/build-rpm.sh nisse-update)"

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-apply-updates /usr/share/doc/nisse-update/safe-apply.md /var/lib/nisse/update; do
    grep -qxF "$f" <<< "$files" || fail "RPM lacks $f"
done

reqs="$(rpm -qp --requires "$rpmf")"
for r in dnf5 snapper nisse-boot nisse-snapshots util-linux-core; do
    grep -qx "$r" <<< "$reqs" || fail "RPM must require $r"
done
# nisse-hw is optional (a machine without hardware routing still updates)
rpm -qp --recommends "$rpmf" | grep -qx nisse-hw || fail "RPM should recommend nisse-hw"

modes="$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpmf")"
grep -q '^-rwxr-xr-x /usr/bin/nisse-apply-updates$' <<< "$modes" || fail "nisse-apply-updates must be mode 0755"

scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpmf" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
sh -n "$scratch/usr/bin/nisse-apply-updates" || fail "nisse-apply-updates has a syntax error"
# it must use the state directory the RPM creates, and the tools the requirements bring
grep -q 'state_dir="${NISSE_STATE_DIR:-/var/lib/nisse/update}"' "$scratch/usr/bin/nisse-apply-updates" || fail "the state directory does not match the RPM's"
grep -q 'boot_tool="${NISSE_BOOT_TOOL:-/usr/bin/nisse-boot}"' "$scratch/usr/bin/nisse-apply-updates" || fail "it must call /usr/bin/nisse-boot"
# the usage is printed with no argument and fails (a smoke test of the real script)
out="$(sh "$scratch/usr/bin/nisse-apply-updates" 2>&1 || true)"
grep -q '^usage: nisse-apply-updates' <<< "$out" || fail "no usage line: $out"

[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-update"
