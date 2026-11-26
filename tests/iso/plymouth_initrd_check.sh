#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-501: an initramfs (the live ISO's, or one built on an installed system) shows the nisse boot screen: the nisse theme folder, the
# script plugin it needs and a Plymouth config that names the theme are inside it (Plymouth runs in the initramfs first).
#   tests/iso/plymouth_initrd_check.sh INITRD      exit 0 when it does, 1 with the reason when it does not
# Run where dracut's lsinitrd is installed (the Fedora build VM).
set -euo pipefail
initrd="${1:?usage: plymouth_initrd_check.sh INITRD}"
[ -f "$initrd" ] || { echo "FAIL: no such initramfs: $initrd" >&2; exit 1; }
list="$(mktemp)"; trap 'rm -f "$list"' EXIT
lsinitrd "$initrd" > "$list" 2>/dev/null || { echo "FAIL: lsinitrd cannot read $initrd" >&2; exit 1; }
for f in usr/lib64/plymouth/script.so usr/share/plymouth/themes/nisse/nisse.plymouth usr/share/plymouth/themes/nisse/nisse.script \
         usr/share/plymouth/themes/nisse/logo.png usr/share/plymouth/themes/nisse/bar-47.png; do
    grep -q " $f\$" "$list" || { echo "FAIL: the initramfs lacks $f: Plymouth would not find the nisse theme at boot" >&2; exit 1; }
done
theme="$(lsinitrd -f etc/plymouth/plymouthd.conf "$initrd" 2>/dev/null | sed -n 's/^Theme=//p')"
[ "$theme" = nisse ] || { echo "FAIL: the initramfs's Plymouth config names '${theme:-no theme}', not nisse" >&2; exit 1; }
echo "ok   the initramfs has the nisse theme, its script plugin and a config that names it"
