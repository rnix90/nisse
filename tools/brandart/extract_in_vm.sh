#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Extract the brand art inventory of a built ISO. Run from Git Bash in the repo root:
#   bash tools/brandart/extract_in_vm.sh [ISO_IN_VM]        (default: ~/nisse/out/nisse-live.iso inside the build VM)
# The ISO's root filesystem (EROFS) is mounted in the build VM, the selected files and their owning packages are staged
# there (inventory.py stage), pulled back to out/brandart-stage/, and inventory.py build writes out/brandart/ on the host.
set -euo pipefail
cd "$(dirname "$0")/../.."
iso="${1:-nisse/out/nisse-live.iso}"
vm="bash tools/build/vm.sh"
py="$(command -v python3 || command -v python)"

$vm sync </dev/null >/dev/null
info="$($vm ssh "
set -e
cd ~/nisse
iso=\"$iso\"; case \"\$iso\" in /*) ;; *) iso=\"\$HOME/\$iso\" ;; esac
[ -f \"\$iso\" ] || { echo \"no ISO at \$iso\" >&2; exit 1; }
w=\$(mktemp -d)
trap 'sudo umount \$w/m 2>/dev/null; rm -rf \$w' EXIT
xorriso -osirrox on -indev \"\$iso\" -extract /LiveOS/squashfs.img \$w/r.erofs >/dev/null 2>&1
mkdir \$w/m
sudo mount -t erofs -o loop,ro \$w/r.erofs \$w/m
rm -rf out/brandart-stage out/brandart-stage.tgz
python3 tools/brandart/inventory.py stage \$w/m --out out/brandart-stage --rpmdb \$w/m/usr/lib/sysimage/rpm >&2
tar -C out/brandart-stage -czf out/brandart-stage.tgz .
printf '%s|%s|%s\n' \"\$(basename \$iso)\" \"\$(date -u -r \$iso +%Y-%m-%dT%H:%MZ)\" \"\$(sha256sum \$iso | cut -c1-16)\"
" </dev/null)"
IFS='|' read -r iso_name built sha <<<"$(printf '%s\n' "$info" | tail -1)"

mkdir -p out
rm -rf out/brandart-stage
mkdir -p out/brandart-stage
$vm pull out/brandart-stage.tgz out/brandart-stage.tgz </dev/null
tar -C out/brandart-stage -xzf out/brandart-stage.tgz
"$py" tools/brandart/inventory.py build out/brandart-stage --out out/brandart --iso "$iso_name" --built "$built" --sha256 "$sha"
