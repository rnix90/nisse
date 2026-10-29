#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Boot an ISO headless under QEMU (UEFI, WHPX) on the Windows host and wait for a marker on the serial
# console. Run from Git Bash. The ISO must have console=ttyS0 on its kernel line (build-iso.sh does that).
#
#   tools/vm/smoke-boot.sh ISO [--vendor V] [--product P] [--family F]
#                              [--wait-for TEXT] [--timeout SECS] [--out DIR]
#                              [--screenshot FILE.png] [--settle SECS]
#
# --vendor/--product/--family spoof SMBIOS type 1 so hardware detection can be tested without the machine.
# Exit 0 if TEXT shows up within the timeout (default TEXT: "login:", 300 s), 1 otherwise. systemd stops
# printing target status once the display manager takes the console, so the serial getty prompt is the marker.
# --screenshot waits --settle seconds after the marker (default 90) and saves the screen as a PNG.
# The serial log is kept in DIR (default out/vm/serial.log).
set -euo pipefail

iso="${1:?usage: smoke-boot.sh ISO [options]}"; shift
vendor="" product="" family="" want="login:" timeout=300 outdir="out/vm" shot="" settle=90
while [ $# -gt 0 ]; do
    case "$1" in
        --vendor) vendor="$2"; shift 2 ;;
        --product) product="$2"; shift 2 ;;
        --family) family="$2"; shift 2 ;;
        --wait-for) want="$2"; shift 2 ;;
        --timeout) timeout="$2"; shift 2 ;;
        --out) outdir="$2"; shift 2 ;;
        --screenshot) shot="$2"; shift 2 ;;
        --settle) settle="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done

qemu_dir="${QEMU_DIR:-/c/Program Files/qemu}"
qemu="$qemu_dir/qemu-system-x86_64.exe"
[ -x "$qemu" ] || { echo "QEMU not found at $qemu (set QEMU_DIR)" >&2; exit 2; }
[ -f "$iso" ] || { echo "ISO not found: $iso" >&2; exit 2; }

mkdir -p "$outdir"
log="$outdir/serial.log"; pidfile="$outdir/qemu.pid"; vars="$outdir/OVMF_VARS.fd"
: > "$log"; rm -f "$pidfile"
cp "$qemu_dir/share/edk2-i386-vars.fd" "$vars"
w() { cygpath -m "$1"; }
monport=$((20000 + RANDOM % 20000))

smbios=()
if [ -n "$vendor$product$family" ]; then
    spec="type=1"
    [ -n "$vendor" ] && spec="$spec,manufacturer=$vendor"
    [ -n "$product" ] && spec="$spec,product=$product"
    [ -n "$family" ] && spec="$spec,family=$family"
    smbios=(-smbios "$spec")
fi

"$qemu" -machine q35 -accel whpx,kernel-irqchip=off -cpu max -smp 4 -m 6144 \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$(w "$qemu_dir/share/edk2-x86_64-code.fd")" \
    -drive "if=pflash,format=raw,unit=1,file=$(w "$vars")" \
    -cdrom "$(w "$iso")" -boot d "${smbios[@]}" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -monitor "tcp:127.0.0.1:$monport,server,nowait"     -display none -serial "file:$(w "$log")" -pidfile "$(w "$pidfile")" &
qpid=$!
cleanup() { kill "$qpid" 2>/dev/null || true; taskkill //F //PID "$(cat "$pidfile" 2>/dev/null)" >/dev/null 2>&1 || true; }
trap cleanup EXIT

end=$((SECONDS + timeout))
while [ "$SECONDS" -lt "$end" ]; do
    if grep -qF "$want" "$log" 2>/dev/null; then
        echo "PASS: saw '$want' after $((timeout - (end - SECONDS))) s ($log)"
        if [ -n "$shot" ]; then
            sleep "$settle"
            exec 3<>"/dev/tcp/127.0.0.1/$monport"
            printf 'screendump %s -f png
' "$(w "$shot")" >&3
            sleep 3
            exec 3>&-
            echo "screenshot: $shot"
        fi
        exit 0
    fi
    sleep 5
done
echo "FAIL: '$want' not seen within ${timeout} s; last serial lines:" >&2
tail -5 "$log" >&2
exit 1
