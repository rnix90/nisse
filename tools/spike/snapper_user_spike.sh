#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306 spike: can an ordinary user in the wheel group take and delete snapper snapshots with no sudo, through snapperd,
# once the config says ALLOW_GROUPS=wheel? Run in the Fedora build VM as a wheel user (needs sudo for the setup only).
set -u
img="$(mktemp -u /tmp/nisse-snapu-XXXXXX.img)"; mnt="$(mktemp -d /tmp/nisse-snapu-mnt-XXXXXX)"; cfg=nisseuser
cleanup() { sudo snapper --no-dbus -c "$cfg" delete-config >/dev/null 2>&1; sudo rm -f "/etc/snapper/configs/$cfg"; sudo umount "$mnt" 2>/dev/null; rm -rf "$img" "$mnt"; }
trap cleanup EXIT
truncate -s 512M "$img"; sudo mkfs.btrfs -q -f "$img"; sudo mount -o loop "$img" "$mnt"
sudo snapper --no-dbus -c "$cfg" create-config "$mnt"
echo "--- as the user, before ALLOW_GROUPS (expected: refused)"
snapper -c "$cfg" create -t pre -p -c number -d "user try 1" 2>&1 | head -2
sudo snapper --no-dbus -c "$cfg" set-config ALLOW_GROUPS=wheel SYNC_ACL=yes
sudo systemctl restart snapperd 2>/dev/null     # snapperd caches configs
echo "--- as the user, after ALLOW_GROUPS=wheel"
n="$(snapper -c "$cfg" create -t pre -p -c number -d "user try 2" -u nisse=ai-batch 2>&1)"; echo "create -> $n"
m="$(snapper -c "$cfg" create -t post --pre-number "$n" -p -c number -d "user post" 2>&1)"; echo "post -> $m"
snapper -c "$cfg" --csvout list --columns number,type,pre-number,cleanup,userdata 2>&1 | head -6
snapper -c "$cfg" delete "$n" "$m" 2>&1 | head -2; echo "delete rc=$?"
id -nG
