#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-502: boot an ISO's GRUB menu headless under QEMU on the Windows host and photograph the screen at chosen seconds, to see the
# nisse GRUB theme. BIOS (SeaBIOS) by default, --efi for UEFI (the host QEMU's edk2 firmware), --secure for UEFI with Secure Boot on.
# Run from Git Bash.
#
#   tools/vm/grub_boot.sh ISO OUTDIR [--efi | --secure] [--res 1920x1080] [--at "3 6"] [--keys "4:down,ret"]
# --keys SECONDS:key,key sends those keys (QEMU key names) at that second, to move through the menu.
#
# Writes OUTDIR/shot-<seconds>.png (QEMU's own screendump) and OUTDIR/serial.log. The ISO may be a trimmed one made by
# tools/vm/grub_overlay.sh (the menu is all that is needed, so the kernel and the root image are left out).
set -euo pipefail
iso="${1:?usage: grub_boot.sh ISO OUTDIR [options]}"; out="${2:?}"; shift 2
mode=bios res="1920x1080" at="3 6" keys=""
while [ $# -gt 0 ]; do
    case "$1" in
        --efi) mode=efi; shift ;;
        --secure) mode=secure; shift ;;
        --res) res="$2"; shift 2 ;;
        --at) at="$2"; shift 2 ;;
        --keys) keys="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done
qemu_dir="${QEMU_DIR:-/c/Program Files/qemu}"
qemu="$qemu_dir/qemu-system-x86_64.exe"
[ -x "$qemu" ] || { echo "QEMU not found at $qemu (set QEMU_DIR)" >&2; exit 2; }
[ -f "$iso" ] || { echo "no such ISO: $iso" >&2; exit 2; }
mkdir -p "$out"; log="$out/serial.log"; pidfile="$out/qemu.pid"; : > "$log"; rm -f "$pidfile" "$out"/shot-*.png
w() { cygpath -m "$1"; }
fw=()
case "$mode" in
    efi|secure)
        code="edk2-x86_64-code.fd"; [ "$mode" = secure ] && code="edk2-x86_64-secure-code.fd"
        vars="$out/vars.fd"; cp "$qemu_dir/share/edk2-i386-vars.fd" "$vars"
        fw=(-drive "if=pflash,format=raw,readonly=on,file=$(w "$qemu_dir/share/$code")" -drive "if=pflash,format=raw,file=$(w "$vars")") ;;
esac
monport=$((20000 + RANDOM % 20000))
xres="${res%x*}"; yres="${res#*x}"
vga=(-device "virtio-vga,xres=$xres,yres=$yres")
[ "$mode" = bios ] && vga=(-vga std)
"$qemu" -machine q35 -accel whpx,kernel-irqchip=off -cpu max -smp 2 -m 2048 "${fw[@]}" \
    -cdrom "$(w "$iso")" -boot d "${vga[@]}" \
    -monitor "tcp:127.0.0.1:$monport,server,nowait" -display none -serial "file:$(w "$log")" -pidfile "$(w "$pidfile")" &
qpid=$!
cleanup() { kill "$qpid" 2>/dev/null || true; taskkill //F //PID "$(cat "$pidfile" 2>/dev/null)" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for _ in $(seq 1 100); do (exec 3<>"/dev/tcp/127.0.0.1/$monport") 2>/dev/null && break; sleep 0.2; done
start=$SECONDS
if [ -n "$keys" ]; then
    (
        ks="${keys#*:}"; ksec="${keys%%:*}"
        while [ $((SECONDS - start)) -lt "$ksec" ]; do sleep 0.5; done
        exec 4<>"/dev/tcp/127.0.0.1/$monport"
        IFS=, read -ra kk <<< "$ks"
        for k in "${kk[@]}"; do printf 'sendkey %s\n' "$k" >&4; sleep 0.4; done
        sleep 1; exec 4>&-
    ) &
fi
for s in $at; do
    while [ $((SECONDS - start)) -lt "$s" ]; do sleep 0.5; done
    exec 3<>"/dev/tcp/127.0.0.1/$monport"
    printf 'screendump %s -f png\n' "$(w "$out/shot-$(printf '%03d' "$s").png")" >&3
    sleep 1.5
    exec 3>&-
    echo "shot at ${s}s"
done
