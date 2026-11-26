#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-501: try the Plymouth theme without rebuilding the ISO (a rebuild is 33 minutes). Takes the live ISO's own kernel and initramfs,
# appends a second cpio archive that adds the theme folder from this repository, Plymouth's script plugin and a plymouthd.conf
# that names the theme, and leaves linux and initrd for tools/vm/plymouth_boot.sh to boot. The kernel unpacks the archives one
# after the other, so the files of the second one win. This proves the theme and the script on the real Plymouth of the real
# image; the finished ISO is checked by tests/iso/test_iso_contents.sh and a normal boot.
# Run in the Fedora build VM (needs xorriso, cpio, plymouth-plugin-script):
#   tools/vm/plymouth_overlay.sh out/nisse-live.iso OUTDIR [--probe | --plain]
# --plain adds nothing: it only takes the ISO's own kernel and initramfs out (for photographing a rebuilt ISO that has the theme).
# --probe adds a service to the initramfs that, a few seconds into boot, shows a message and then asks for a password, so the
# message line and the password prompt of the theme can be photographed too (the password goes nowhere).
set -euo pipefail
iso="${1:?usage: plymouth_overlay.sh ISO OUTDIR [--probe]}"; out="${2:?}"; probe="${3:-}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
theme="$repo/assets/art/plymouth/nisse"
[ -f /usr/lib64/plymouth/script.so ] || { echo "install plymouth-plugin-script first" >&2; exit 2; }
mkdir -p "$out"; w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
xorriso -osirrox on -indev "$iso" -extract /boot/x86_64/loader/linux "$out/linux" -extract /boot/x86_64/loader/initrd "$w/initrd.orig" >/dev/null 2>&1
label="$(xorriso -indev "$iso" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: *//p')"
echo "$label" > "$out/label"
if [ "$probe" = "--plain" ]; then
    # no overlay: the ISO's own kernel and initramfs, for photographing what a rebuilt ISO really shows
    cp "$w/initrd.orig" "$out/initrd"; ls -la "$out"; echo "label: $label (plain)"; exit 0
fi

o="$w/overlay"
mkdir -p "$o/usr/share/plymouth/themes" "$o/usr/lib64/plymouth" "$o/etc/plymouth"
cp -a "$theme" "$o/usr/share/plymouth/themes/nisse"
# the words' font: in a real initramfs the nisse-plymouth dracut module does this (it replaces the link to the system font)
mkdir -p "$o/usr/share/fonts"
cp -a "$theme/Nunito-Regular.ttf" "$o/usr/share/fonts/Plymouth.ttf"
cp -a /usr/lib64/plymouth/script.so "$o/usr/lib64/plymouth/script.so"
printf '[Daemon]\nTheme=nisse\nShowDelay=0\nDeviceTimeout=8\n' > "$o/etc/plymouth/plymouthd.conf"
# the plugin's libraries the initramfs does not have yet. They go under usr/lib64: /lib64 is a symlink there, and an archive entry
# that made it a real folder would replace the link and leave the system without its loader (the kernel then panics, no init)
lsinitrd "$w/initrd.orig" 2>/dev/null | awk '{print $NF}' | sed 's|.*/||' | sort -u > "$w/have.lst"
for lib in $(ldd /usr/lib64/plymouth/script.so | awk '/=> \//{print $3}'); do
    base="$(basename "$lib")"
    if grep -qxF "$base" "$w/have.lst"; then continue; fi
    echo "adding $base (not in the initramfs)"
    cp -aL "$lib" "$o/usr/lib64/$base"
done
if [ "$probe" = "--probe" ]; then
    mkdir -p "$o/usr/lib/systemd/system/initrd-switch-root.target.wants" "$o/usr/libexec"
    cat > "$o/usr/libexec/nisse-plymouth-probe" <<'EOF'
#!/bin/sh
# holds the initramfs open for about 30 seconds so the screen can be photographed, and sends Plymouth's own log to the serial port
sleep 10
echo "=== plymouth debug log ===" > /dev/ttyS0
cat /run/plymouth-debug.log > /dev/ttyS0 2>&1
echo "=== end ===" > /dev/ttyS0
plymouth display-message --text="Checking the disk"
sleep 10
plymouth ask-for-password --prompt="Enter the password for your disk:" --number-of-tries=1 > /dev/null 2>&1 &
sleep 12
EOF
    chmod 0755 "$o/usr/libexec/nisse-plymouth-probe"
    cat > "$o/usr/lib/systemd/system/nisse-plymouth-probe.service" <<'EOF'
[Unit]
Description=nisse Plymouth probe (development only)
DefaultDependencies=no
After=plymouth-start.service
Before=initrd-switch-root.service
[Service]
Type=oneshot
ExecStart=/usr/libexec/nisse-plymouth-probe
[Install]
WantedBy=initrd-switch-root.target
EOF
    ln -sf ../nisse-plymouth-probe.service "$o/usr/lib/systemd/system/initrd-switch-root.target.wants/nisse-plymouth-probe.service"
fi
(cd "$o" && find . | cpio -o -H newc --quiet --owner=0:0) > "$w/overlay.cpio"
# the kernel wants the next archive on a 4-byte boundary (it skips zeros up to it); without the padding it stops with "invalid magic"
size="$(stat -c %s "$w/initrd.orig")"; pad=$(( (4 - size % 4) % 4 ))
{ cat "$w/initrd.orig"; head -c "$pad" /dev/zero; cat "$w/overlay.cpio"; } > "$out/initrd"
ls -la "$out"
echo "label: $label"
