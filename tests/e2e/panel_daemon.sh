#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# End to end: the real daemon (fake agent) and the real panel on a private session bus. Run in the Fedora
# build VM after: (cd services && cargo build && cargo build --example device_probe) && (cd panel && cmake -S . -B build -G Ninja && cmake --build build)
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

daemon=services/target/debug/nisse-daemon
panel=panel/build/nisse-panel
probe=services/target/debug/examples/device_probe
[ -x "$daemon" ] || fail "build the daemon first: (cd services && cargo build)"
[ -x "$probe" ] || fail "build the loopback device first: (cd services && cargo build --example device_probe)"
[ -x "$panel" ] || fail "build the panel first: (cd panel && cmake -S . -B build -G Ninja && cmake --build build)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export NISSE_FAKE_RUNNER=1 NISSE_AUDIT_LOG="$work/audit.jsonl" NISSE_CONFIG="$work/none.toml" NISSE_STATE="$work/sessions.json" QT_QPA_PLATFORM=offscreen

# shellcheck disable=SC2016
dbus-run-session -- bash -c '
set -euo pipefail
"$0" &
daemon_pid=$!
trap "kill $daemon_pid 2>/dev/null || true" EXIT
for _ in $(seq 1 50); do
    busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && break
    sleep 0.2
done
id="$(busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 NewSession | cut -d\" -f2)"
[ -n "$id" ] || { echo "FAIL: NewSession returned nothing" >&2; exit 1; }
busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 SendMessage ss "$id" "direct ping" >/dev/null
sleep 1
grep -q "\"kind\":\"message\"" "$NISSE_AUDIT_LOG" || { echo "FAIL: no message record in the audit log" >&2; exit 1; }
out="$("$1" --self-test)"
echo "$out"
echo "$out" | grep -qx "authority: autonomous" || { echo "FAIL: panel did not report the autonomous authority" >&2; exit 1; }
echo "$out" | grep -qx "audit search: 1 match" || { echo "FAIL: panel could not find the message in the audit log through the daemon" >&2; exit 1; }
echo "$out" | grep -qx "usage: available" || { echo "FAIL: panel did not get the usage status from the daemon" >&2; exit 1; }
echo "$out" | grep -qx "backend: max" || { echo "FAIL: panel did not report the max backend" >&2; exit 1; }
echo "$out" | grep -qx "reply: echo: ping" || { echo "FAIL: panel did not get the fake agent reply" >&2; exit 1; }
' "$daemon" "$panel"

# N-205: a held call decided by the real panel client, with the desktop notice it sends.
dbus-run-session -- bash tests/e2e/approvals_inner.sh "$daemon" "$panel" "$work"

# N-206: three live sessions through the real daemon and the real panel client.
dbus-run-session -- bash tests/e2e/sessions_inner.sh "$daemon" "$panel" "$work"

# N-209: the remote access switch through the real daemon and panel client, with a fake claude.
dbus-run-session -- bash tests/e2e/remote_inner.sh "$daemon" "$panel" "$work"

# N-215: the kill switch through the real daemon and panel client.
dbus-run-session -- bash tests/e2e/kill_inner.sh "$daemon" "$panel" "$work"

# N-216: the settings panel's client edits and saves a config the daemon accepts and uses.
dbus-run-session -- bash tests/e2e/config_inner.sh "$daemon" "$panel" "$work"

# N-218: the daemon stopped and started, the network off for the first-boot fetch, and what the panel says about each.
dbus-run-session -- bash tests/e2e/connection_inner.sh "$daemon" "$panel" "$work"

# N-220: the event log through the real daemon and panel client, across a daemon restart.
dbus-run-session -- bash tests/e2e/events_inner.sh "$daemon" "$panel" "$work"

# N-221: device pairing through the real daemon with a loopback device that signs its calls.
dbus-run-session -- bash tests/e2e/devices_inner.sh "$daemon" "$panel" "$work" "$probe"

echo "PASS: panel and daemon end to end"
