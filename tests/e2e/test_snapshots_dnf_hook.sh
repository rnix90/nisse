#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-305: dnf5 really calls the nisse-snapshots hook, once before and once after a package transaction, in that order,
# with the real actions file installed. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-snapshots
# The VM's root is not btrfs, so the real hook skips; a probe hook, wired the same way, records what dnf did.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-snapshots-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || { echo "FAIL: nisse-snapshots RPM not found"; exit 1; }
pkg=tree
probe=/usr/libexec/nisse-probe-hook
probe_actions=/etc/dnf/libdnf5-plugins/actions.d/zz-nisse-probe.actions
log=/tmp/nisse-probe.log

cleanup() {
    sudo rm -f "$probe" "$probe_actions" "$log"
    sudo dnf remove -y "$pkg" nisse-snapshots >/dev/null 2>&1
}
trap cleanup EXIT
sudo dnf remove -y "$pkg" >/dev/null 2>&1
sudo rm -f "$log"

sudo dnf install -y "$rpmf" >/dev/null 2>&1 && ok "nisse-snapshots installs" || { bad "nisse-snapshots does not install"; exit 1; }
[ -f /etc/dnf/libdnf5-plugins/actions.d/nisse-snapshots.actions ] && ok "the actions file is in place" || bad "no actions file"

# The probe records the mode, whether the package file exists yet, and emits a plugin log line like the real hook.
sudo tee "$probe" >/dev/null <<'EOF'
#!/bin/sh
exists=no; [ -e /usr/bin/tree ] && exists=yes
echo "$1 package-present=$exists" >> /tmp/nisse-probe.log
echo "log.INFO=nisse-probe: $1"
exit 0
EOF
sudo chmod 0755 "$probe"
printf '%s\n' \
    "pre_transaction:::enabled=host-only:$probe pre" \
    "post_transaction:::enabled=host-only:$probe post" | sudo tee "$probe_actions" >/dev/null

out="$(sudo dnf install -y "$pkg" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "dnf install exits 0 with both actions files in place" || bad "dnf install failed: $(echo "$out" | tail -3)"
[ "$(cat "$log" 2>/dev/null)" = "$(printf 'pre package-present=no\npost package-present=yes')" ] \
    && ok "the hook ran once before (package absent) and once after (package present), in order" \
    || bad "hook log is: $(tr '\n' '|' < "$log" 2>/dev/null)"
grep -qiE 'error|fail' <<< "$(echo "$out" | grep -i -E 'action|nisse|plugin')" && bad "dnf complained about the actions: $(echo "$out" | grep -i -E 'action|nisse|plugin')" || ok "dnf reports no plugin or action error"

sudo rm -f "$log"
sudo dnf remove -y "$pkg" >/dev/null 2>&1
[ "$(cat "$log" 2>/dev/null)" = "$(printf 'pre package-present=yes\npost package-present=no')" ] \
    && ok "removals are bracketed too" || bad "remove hook log is: $(tr '\n' '|' < "$log" 2>/dev/null)"

echo
[ "$failures" = 0 ] && echo "PASS: dnf5 runs the snapshot hook around transactions" || { echo "$failures failed"; exit 1; }
