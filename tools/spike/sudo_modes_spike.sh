#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306a spike: how sudo behaves for the two nisse modes. Run in the Fedora build VM (needs sudo and useradd).
#  1. Fedora's main sudoers asks wheel users for a password; does a later drop-in with NOPASSWD override it?
#  2. with no terminal, which askpass routes does sudo use: SUDO_ASKPASS alone, -A, or a Path in /etc/sudo.conf?
#  3. after one answer, are later no-terminal calls remembered (timestamp_type=global)?
#  4. a wrong answer and a cancelled popup both fail cleanly.
set -u
u=nisseprobe
work="$(mktemp -d)"
cleanup() {
    [ -f "$work/sudo.conf.orig" ] && sudo cp "$work/sudo.conf.orig" /etc/sudo.conf
    sudo rm -f /etc/sudoers.d/10-nisse-spike
    sudo userdel -r "$u" >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT
sudo useradd -m -G wheel "$u" && echo "$u:probe-pass-1" | sudo chpasswd || { echo "cannot make the test user"; exit 1; }
chmod 777 "$work"   # the probe user's stub askpass logs into it (a sticky /tmp would refuse the write)
printf '#!/bin/sh\necho asked >> "$(dirname "$0")/asked"\necho probe-pass-1\n' > "$work/askpass"
printf '#!/bin/sh\necho asked >> "$(dirname "$0")/asked"\necho wrong\n' > "$work/askpass-bad"
printf '#!/bin/sh\necho asked >> "$(dirname "$0")/asked"\nexit 1\n' > "$work/askpass-cancel"
chmod 755 "$work"/askpass*
asked() { wc -l < "$work/asked" 2>/dev/null || echo 0; }
forget() { sudo -u "$u" sudo -k 2>/dev/null; rm -f "$work/asked"; }
as() { sudo -u "$u" env -i PATH=/usr/bin:/usr/sbin HOME="/home/$u" "$@" < /dev/null; }   # no terminal: stdin is /dev/null
rc() { "$@" >/dev/null 2>&1; echo "rc=$?"; }

echo "--- main sudoers:"; sudo grep -n '^%wheel\|^@includedir\|^#includedir' /etc/sudoers
echo "--- 1. no drop-in:               sudo -n true  $(rc as sudo -n true)   (expect rc=1: password required)"
echo '%wheel ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/10-nisse-spike >/dev/null; sudo chmod 0440 /etc/sudoers.d/10-nisse-spike
sudo visudo -cf /etc/sudoers.d/10-nisse-spike | tail -1
echo "--- 2. full-mode drop-in:        sudo -n true  $(rc as sudo -n true)   (expect rc=0)"

printf '%s\n' 'Defaults:%wheel timestamp_type=global' '%wheel ALL=(root) NOPASSWD: /usr/bin/id' | sudo tee /etc/sudoers.d/10-nisse-spike >/dev/null
sudo visudo -cf /etc/sudoers.d/10-nisse-spike | tail -1
echo "--- 3. limited-mode drop-in (only /usr/bin/id passwordless):"
echo "    listed command, -n:          $(rc as sudo -n id -u)   (expect rc=0)"
echo "    other command, -n:           $(rc as sudo -n true)   (expect rc=1)"
forget
echo "    SUDO_ASKPASS alone, no -A:   $(rc as env SUDO_ASKPASS="$work/askpass" sudo true)   asked=$(asked)   (rc=1 and asked=0 means sudo ignores it with no terminal)"
forget
echo "    -A with SUDO_ASKPASS:        $(rc as env SUDO_ASKPASS="$work/askpass" sudo -A true)   asked=$(asked)   (expect rc=0, asked=1)"
echo "    -A again at once:            $(rc as env SUDO_ASKPASS="$work/askpass" sudo -A true)   asked=$(asked)   (asked stays 1 if remembered)"
echo "    plain sudo -n true after:    $(rc as sudo -n true)   (rc=0 if the answer is remembered for any no-terminal caller)"
forget
sudo cp /etc/sudo.conf "$work/sudo.conf.orig"
printf '\n# BEGIN nisse spike\nPath askpass %s\n# END nisse spike\n' "$work/askpass" | sudo tee -a /etc/sudo.conf >/dev/null
echo "    sudo.conf Path askpass, no -A: $(rc as sudo true)   asked=$(asked)   (rc=1 and asked=0 means sudo.conf alone is not enough)"
echo "    sudo.conf Path askpass, -A:    $(rc as sudo -A true)   asked=$(asked)   (expect rc=0, asked=1)"
sudo cp "$work/sudo.conf.orig" /etc/sudo.conf; rm -f "$work/sudo.conf.orig"

echo "--- 4. failures through askpass (-A):"
forget
echo "    wrong password:              $(rc as env SUDO_ASKPASS="$work/askpass-bad" sudo -A true)   asked=$(asked)   (expect rc=1)"
forget
echo "    cancelled popup:             $(rc as env SUDO_ASKPASS="$work/askpass-cancel" sudo -A true)   asked=$(asked)   (expect rc=1)"
forget
echo "    -A with -n:                  $(rc as env SUDO_ASKPASS="$work/askpass" sudo -A -n true)   asked=$(asked)   (which wins?)"
