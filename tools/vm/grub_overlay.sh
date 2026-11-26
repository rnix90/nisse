#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-502: try the GRUB menu without rebuilding the ISO (a rebuild is 33 minutes). Makes a small copy of a live ISO that boots only as
# far as GRUB's menu (the root image and the kernel are left out, so it is about 70 MB), with this repository's menu template filled in
# the way kiwi fills it and the theme taken from the built nisse-grub-theme package. Photograph it with tools/vm/grub_boot.sh.
# Run in the Fedora build VM (needs xorriso, cpio, rpm2cpio, python3):
#   tools/rpm/build-rpm.sh nisse-grub-theme
#   tools/vm/grub_overlay.sh out/nisse-live.iso OUT.iso [--plain]
# --plain adds nothing: it only trims the ISO, to photograph the menu a rebuilt ISO really has.
set -euo pipefail
iso="${1:?usage: grub_overlay.sh ISO OUT.iso [--plain]}"; out="${2:?}"; mode="${3:-}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
rm -f "$out"
maps=()
if [ "$mode" != "--plain" ]; then
    rpmf="$(ls -v "$repo"/out/rpmbuild/RPMS/noarch/nisse-grub-theme-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
    [ -n "$rpmf" ] || { echo "no nisse-grub-theme RPM (run tools/rpm/build-rpm.sh nisse-grub-theme)" >&2; exit 2; }
    xorriso -osirrox on -indev "$iso" -extract /boot/grub2/grub.cfg "$w/orig.cfg" >/dev/null 2>&1
    search="$(sed -n 's/^search //p' "$w/orig.cfg" | head -1)"
    options="$(sed -n 's|^[[:space:]]*linux (\$root)/boot/x86_64/loader/linux ||p' "$w/orig.cfg" | head -1)"
    [ -n "$search" ] && [ -n "$options" ] || { echo "could not read the search line and kernel options from the ISO's grub.cfg" >&2; exit 2; }
    # kiwi turns the options ("rd.live.check" and so on are added by the template's own entries) into one string
    options="$(printf '%s' "$options" | sed 's/ rd.live.check//; s/ nomodeset//')"
    python3 - "$repo/build/kiwi/nisse/grub-x86.cfg.iso-template" "$search" "$options" > "$w/grub.cfg" <<'PY'
import string, sys
t = string.Template(open(sys.argv[1], encoding="ascii").read())
print(t.substitute(search_params=sys.argv[2], terminal_output="console", boot_timeout="10", boot_timeout_style="menu",
                   bootpath="/boot/x86_64/loader", kernel_file="linux", initrd_file="initrd", boot_options=sys.argv[3]))
PY
    mkdir -p "$w/pkg"
    rpm2cpio "$rpmf" | (cd "$w/pkg" && cpio -idm --quiet)
    maps=(-map "$w/grub.cfg" /boot/grub2/grub.cfg -map "$w/pkg/usr/share/grub/themes/nisse" /boot/grub2/themes/nisse)
fi
xorriso -indev "$iso" -outdev "$out" -boot_image any replay -rm_r /LiveOS /boot/x86_64 -- "${maps[@]}" -commit >/dev/null 2>&1
ls -la "$out"
