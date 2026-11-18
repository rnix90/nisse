#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-305 spike: how snapper counts pre/post pairs, whether an absolute SPACE_LIMIT works, what quota costs.
# Run in the Fedora build VM (needs sudo, btrfs-progs, snapper). Uses a throwaway loop btrfs.
set -u
sudo umount /mnt/snt 2>/dev/null; sudo mkdir -p /mnt/snt
truncate -s 2G /tmp/snt.img
sudo mkfs.btrfs -q -f /tmp/snt.img
sudo mount -o loop /tmp/snt.img /mnt/snt
sudo snapper -c snt create-config /mnt/snt 2>&1
# snapperd caches configs, so edit through set-config (a sed on the file is ignored until snapperd restarts)
sudo snapper -c snt set-config TIMELINE_CREATE=no NUMBER_LIMIT=5 NUMBER_LIMIT_IMPORTANT=5 NUMBER_MIN_AGE=0 SPACE_LIMIT=5G EMPTY_PRE_POST_CLEANUP=no
sudo snapper -c snt get-config | grep -E "SPACE_LIMIT|NUMBER|QGROUP"
for i in 1 2 3 4 5 6 7 8; do
  p=$(sudo snapper -c snt create -t pre -p -c number -d "pre $i")
  echo x$i | sudo tee /mnt/snt/f$i >/dev/null
  sudo snapper -c snt create -t post --pre-number "$p" -p -c number -d "post $i" >/dev/null
done
echo "--- before cleanup"; sudo snapper -c snt list | tail -n +3 | wc -l
sudo snapper -c snt cleanup number 2>&1; echo "cleanup rc=$?"
echo "--- after cleanup"; sudo snapper -c snt list --columns number,type,pre-number,cleanup,description
echo "--- space limit w/o quota:"; echo "--- (no separate space algorithm: SPACE_LIMIT acts inside number/timeline cleanup)"
echo "--- setup-quota:"; sudo snapper -c snt setup-quota 2>&1 | head; sudo snapper -c snt get-config | grep QGROUP
sudo snapper -c snt cleanup number 2>&1; echo "cleanup with quota rc=$?"; sudo snapper -c snt list --columns number,type,used-space | tail -4
sudo snapper -c snt delete-config 2>&1; sudo rm -f /etc/snapper/configs/snt; sudo umount /mnt/snt; rm -f /tmp/snt.img

# Part 2: does an absolute SPACE_LIMIT trim snapshots (needs the quota group)? Each pair rewrites a 12 MiB file, so each
# snapshot pins about 12 MiB of its own; with SPACE_LIMIT=30M and NUMBER_LIMIT high, only the count the limit allows may stay.
sudo umount /mnt/snt 2>/dev/null; truncate -s 2G /tmp/snt.img; sudo mkfs.btrfs -q -f /tmp/snt.img; sudo mount -o loop /tmp/snt.img /mnt/snt
sudo snapper -c snt create-config /mnt/snt; sudo snapper -c snt setup-quota
sudo snapper -c snt set-config TIMELINE_CREATE=no NUMBER_LIMIT=100 NUMBER_LIMIT_IMPORTANT=100 NUMBER_MIN_AGE=0 SPACE_LIMIT=30M FREE_LIMIT=0.01 EMPTY_PRE_POST_CLEANUP=no
for i in 1 2 3 4 5 6 7 8; do
  p=$(sudo snapper -c snt create -t pre -p -c number -d "pre $i")
  sudo dd if=/dev/urandom of=/mnt/snt/big bs=1M count=12 status=none
  sudo snapper -c snt create -t post --pre-number "$p" -p -c number -d "post $i" >/dev/null
done
sync; sleep 2
echo "--- part 2 before:"; sudo snapper -c snt list --columns number,type,used-space | tail -n +3 | wc -l
sudo snapper -c snt cleanup number; echo "cleanup rc=$?"
echo "--- part 2 after:"; sudo snapper -c snt list --columns number,type,used-space
sudo snapper -c snt delete-config 2>&1; sudo rm -f /etc/snapper/configs/snt; sudo umount /mnt/snt; rm -f /tmp/snt.img
