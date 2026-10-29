#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Open a Nisse VM with a window (QEMU, UEFI, WHPX) on the Windows host, for installing and trying things by hand.
# Run from Git Bash.
#
#   tools/vm/run-vm.sh DISK.qcow2 [--iso ISO] [--vendor V] [--product P] [--family F]
#
# The disk is created (40 GB, sparse) if it does not exist. Boot from the ISO to install; leave --iso out to boot
# the installed system. --vendor/--product/--family spoof SMBIOS so hardware routing sees a Surface or a MacBook.
#   --vendor "Microsoft Corporation" --product "Surface Go" --family Surface
#   --vendor "Apple Inc." --product MacBookPro15,2
set -euo pipefail

disk="${1:?usage: run-vm.sh DISK.qcow2 [options]}"; shift
iso="" vendor="" product="" family=""
while [ $# -gt 0 ]; do
    case "$1" in
        --iso) iso="$2"; shift 2 ;;
        --vendor) vendor="$2"; shift 2 ;;
        --product) product="$2"; shift 2 ;;
        --family) family="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

qemu_dir="${QEMU_DIR:-/c/Program Files/qemu}"
qemu="$qemu_dir/qemu-system-x86_64.exe"
[ -x "$qemu" ] || { echo "QEMU not found at $qemu (set QEMU_DIR)" >&2; exit 2; }
w() { cygpath -m "$1"; }

[ -f "$disk" ] || "$qemu_dir/qemu-img.exe" create -f qcow2 "$(w "$disk")" 40G
vars="${disk%.qcow2}.OVMF_VARS.fd"
[ -f "$vars" ] || cp "$qemu_dir/share/edk2-i386-vars.fd" "$vars"

args=(-machine q35 -accel whpx,kernel-irqchip=off -cpu max -smp 4 -m 6144
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=$(w "$qemu_dir/share/edk2-x86_64-code.fd")"
      -drive "if=pflash,format=raw,unit=1,file=$(w "$vars")"
      -drive "file=$(w "$disk"),if=virtio,format=qcow2"
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0
      -device virtio-vga -device qemu-xhci -device usb-tablet)
[ -n "$iso" ] && args+=(-cdrom "$(w "$iso")" -boot d)
if [ -n "$vendor$product$family" ]; then
    esc() { printf '%s' "${1//,/,,}"; }
    spec="type=1"
    [ -n "$vendor" ] && spec="$spec,manufacturer=$(esc "$vendor")"
    [ -n "$product" ] && spec="$spec,product=$(esc "$product")"
    [ -n "$family" ] && spec="$spec,family=$(esc "$family")"
    args+=(-smbios "$spec")
fi
exec "$qemu" "${args[@]}"
