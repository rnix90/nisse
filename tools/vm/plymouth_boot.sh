#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-501: boot the live ISO's kernel and initramfs (as made by tools/vm/plymouth_overlay.sh) headless
# under QEMU on the Windows host and photograph the screen at chosen seconds, to see the Plymouth boot screen. Run from Git Bash.
#
#   tools/vm/plymouth_boot.sh ISO OVERLAYDIR OUTDIR [--res 1920x1080] [--at "5 10 20"] [--cmdline-extra "..."] [--keys "30:a,b,c"]
# --keys SECONDS:key,key sends those keys (QEMU key names) at that second, to type into a password prompt.
#
# OVERLAYDIR holds linux, initrd and label (copied out of the build VM). Writes OUTDIR/shot-<seconds>.png and OUTDIR/serial.log.
set -euo pipefail
iso="${1:?usage: plymouth_boot.sh ISO OVERLAYDIR OUTDIR [options]}"; ov="${2:?}"; out="${3:?}"; shift 3
res="1920x1080" at="6 10 16 24 40" extra="" keys=""
while [ $# -gt 0 ]; do
    case "$1" in
        --res) res="$2"; shift 2 ;;
        --at) at="$2"; shift 2 ;;
        --cmdline-extra) extra="$2"; shift 2 ;;
        --keys) keys="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done
qemu_dir="${QEMU_DIR:-/c/Program Files/qemu}"
qemu="$qemu_dir/qemu-system-x86_64.exe"
[ -x "$qemu" ] || { echo "QEMU not found at $qemu (set QEMU_DIR)" >&2; exit 2; }
[ -f "$iso" ] && [ -f "$ov/linux" ] && [ -f "$ov/initrd" ] || { echo "need the ISO and linux + initrd in $ov" >&2; exit 2; }
label="$(tr -d '[:space:]' < "$ov/label")"
mkdir -p "$out"; log="$out/serial.log"; pidfile="$out/qemu.pid"; : > "$log"; rm -f "$pidfile" "$out"/shot-*.png
w() { cygpath -m "$1"; }
monport=$((20000 + RANDOM % 20000))
xres="${res%x*}"; yres="${res#*x}"
"$qemu" -machine q35 -accel whpx,kernel-irqchip=off -cpu max -smp 4 -m 6144 \
    -kernel "$(w "$ov/linux")" -initrd "$(w "$ov/initrd")" \
    -append "quiet rhgb console=ttyS0 systemd.log_target=console root=live:CDLABEL=$label rd.live.image $extra" \
    -cdrom "$(w "$iso")" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -device "virtio-vga,xres=$xres,yres=$yres" \
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
