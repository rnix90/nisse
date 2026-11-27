#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-508b spike: does a PackageKit transaction (what Discover's packagekit backend starts) run libdnf5's actions plugin, the way a dnf5
# transaction does? nisse-snapshots takes its snapshot pair through that plugin (packaging/rpm/nisse-snapshots/nisse-snapshots.actions), so a
# transaction that skips it is an unsnapshotted update path. Run in the Fedora build VM:
#   bash tools/spike/pk_actions_probe.sh
# It adds a marker hook to the actions plugin, installs one tiny package with plain dnf (the control) and one with pkcon (PackageKit), and
# prints which of them left marker lines. It removes the hook and the packages again.
set -u
marker=/tmp/pk-actions-marker
hook=/etc/dnf/libdnf5-plugins/actions.d/zz-pk-probe.actions
probe=/usr/local/bin/pk-probe.sh
sudo rm -f "$marker"
printf '#!/bin/sh\necho "$1 $(date +%%s)" >> %s\n' "$marker" | sudo tee "$probe" >/dev/null
sudo chmod 755 "$probe"
printf 'pre_transaction:::enabled=host-only:%s pre\npost_transaction:::enabled=host-only:%s post\n' "$probe" "$probe" | sudo tee "$hook" >/dev/null
sudo dnf install -y -q --disablerepo='updates*' PackageKit PackageKit-command-line libdnf5-plugin-actions >/dev/null 2>&1
echo "backend: $(grep -h -E '^DefaultBackend' /etc/PackageKit/PackageKit.conf 2>/dev/null || echo unknown)"
echo "plugin: $(rpm -q libdnf5-plugin-actions PackageKit)"

echo "--- control: dnf install"
sudo dnf install -y -q --disablerepo='updates*' cowsay >/dev/null 2>&1; echo "dnf rc=$?"
echo "marker after dnf:"; cat "$marker" 2>/dev/null || echo "(none)"
sudo rm -f "$marker"
sudo dnf remove -y -q cowsay >/dev/null 2>&1
sudo rm -f "$marker"

echo "--- PackageKit: pkcon install"
sudo systemctl restart packagekit.service 2>/dev/null
sudo pkcon -y -p install figlet 2>&1 | tail -4; echo "pkcon rc=$?"
echo "marker after pkcon:"; cat "$marker" 2>/dev/null || echo "(none)"
echo "figlet installed: $(rpm -q figlet 2>&1)"

sudo pkcon -y remove figlet >/dev/null 2>&1
sudo dnf remove -y -q figlet >/dev/null 2>&1
sudo rm -f "$hook" "$probe" "$marker"
