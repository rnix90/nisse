#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-installer RPM (the nisse Anaconda profile, N-304). Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-installer
# The last step runs Anaconda's own automatic partitioning (tools/spike/autopart_dryrun.py, nothing is written) with the
# packaged profile and needs anaconda-core, libblockdev-btrfs, libblockdev-lvm and libblockdev-dm in the VM.
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-installer-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-installer RPM not found (run tools/rpm/build-rpm.sh nisse-installer)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
printf '%s\n' "$files" | grep -qxF /etc/anaconda/profile.d/nisse.conf || fail "RPM lacks /etc/anaconda/profile.d/nisse.conf"
printf '%s\n' "$files" | grep -qx '/etc/anaconda/profile.d' && fail "must not own /etc/anaconda/profile.d (anaconda-core does)"
rpm -qp --requires "$rpmf" | grep -q 'anaconda-core' || fail "RPM must require anaconda-core (it reads the profile)"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"

conf="$(member etc/anaconda/profile.d/nisse.conf)"
printf '%s\n' "$conf" | grep -qx 'profile_id = nisse' || fail "profile_id must be nisse"
printf '%s\n' "$conf" | grep -qx 'os_id = nisse' || fail "must be detected from os-release ID=nisse (Anaconda ignores ID_LIKE)"
printf '%s\n' "$conf" | grep -qx 'base_profile = fedora' || fail "must inherit the fedora profile (efi_dir = fedora, btrfs defaults)"
printf '%s\n' "$conf" | grep -qx 'default_scheme = BTRFS' || fail "default_scheme must be BTRFS"
printf '%s\n' "$conf" | grep -qx 'btrfs_compression = zstd:1' || fail "btrfs_compression must be zstd:1"
for mp in '/ ' '/home ' '/var/log ' '/var/cache '; do
    printf '%s\n' "$conf" | grep -qE "^    ${mp}" || fail "default_partitioning must list $mp"
done
printf '%s\n' "$conf" | grep -qE '^    /var/lib/' && fail "no model-store subvolume until a backend defines a path (N-302)"

# Anaconda itself: load the packaged profile for ID=nisse and plan a disk (UEFI, nothing written)
python3 -c "import pyanaconda" 2>/dev/null || fail "anaconda-core is not installed in this VM (see docs/storage-spike.md, Reproduce)"
sudo cp "$(dirname "$0")/../../packaging/rpm/nisse-installer/nisse.conf" /etc/anaconda/profile.d/nisse.conf
trap 'sudo rm -f /etc/anaconda/profile.d/nisse.conf' EXIT
plan="$(sudo python3 tools/spike/autopart_dryrun.py --id nisse 2>&1 | grep -v 'failed to load')"
echo "$plan" | grep -E 'default_scheme|subvolume|partition ' | cut -c1-120
echo "$plan" | grep -q 'default_scheme    : 1' || fail "Anaconda did not select the BTRFS scheme for ID=nisse"
echo "$plan" | grep -q 'btrfs_compression : zstd:1' || fail "compression not zstd:1"
subs="$(echo "$plan" | grep -c 'btrfs subvolume')"
[ "$subs" = "4" ] || fail "expected exactly 4 subvolumes, Anaconda planned $subs"
for want in 'root  .*mount=/ ' 'home  .*mount=/home ' 'var_log  .*mount=/var/log ' 'var_cache  .*mount=/var/cache '; do
    echo "$plan" | grep -E "^ +${want}" | grep -q 'btrfs subvolume' || fail "no planned subvolume for: $want"
done

out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-installer"
