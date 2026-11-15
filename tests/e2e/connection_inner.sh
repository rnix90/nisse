#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-218): the daemon is stopped and started again, and the network is
# "off" for the first-boot fetch, while the panel's client reports what it would tell the person. $1 = daemon,
# $2 = panel, $3 = scratch folder.
set -euo pipefail
daemon="$1" panel="$2" work="$3"
fail() { echo "FAIL: $*" >&2; exit 1; }

export NISSE_STATE="$work/sessions-n218.json" XDG_STATE_HOME="$work/xdg" NISSE_PANEL_SETUP_POLL_MS=300
mkdir -p "$XDG_STATE_HOME"
start_daemon() {
    "$daemon" &
    daemon_pid=$!
    for _ in $(seq 1 50); do
        busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    fail "the daemon did not come up"
}
stop_daemon() { kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true; }
waitfor() { # file pattern seconds
    for _ in $(seq 1 $(( $3 * 10 ))); do grep -q -- "$2" "$1" && return 0; sleep 0.1; done
    fail "waited for '$2' in: $(cat "$1")"
}
trap 'stop_daemon; kill ${panel_pid:-} ${panel2_pid:-} 2>/dev/null || true' EXIT

# the network is off: the real first-boot script says so, with no Claude Code anywhere on its path
fetch() {
    HOME="$work/fetch-home" PATH=/usr/bin:/bin NISSE_CLAUDE_INSTALLER=false NISSE_PROBE_URL="${1:-http://127.0.0.1:9/}" sh packaging/rpm/nisse-firstboot/nisse-fetch-claude >/dev/null 2>&1 || true
}
mkdir -p "$work/fetch-home"

start_daemon
"$panel" --self-test-connection >"$work/conn1.out" 2>&1 &
panel_pid=$!
waitfor "$work/conn1.out" '^start: connected' 5

# 1. no network: Claude Code cannot be fetched, and the panel says so while everything else carries on
fetch
[ "$(cat "$XDG_STATE_HOME/nisse/claude-fetch.status")" = "waiting-for-network" ] || fail "the fetch script did not report the network as down"
waitfor "$work/conn1.out" '^setup: Claude Code is not installed yet: waiting for a network connection' 5
# the network is back: the fetch installs (a fake installer) and the sentence goes away by itself
mkdir -p "$work/fetch-home/.local/bin"
printf '#!/bin/sh\n' >"$work/fetch-home/.local/bin/claude"; chmod +x "$work/fetch-home/.local/bin/claude"
fetch "file://$work/fetch-home/.local/bin/claude"
waitfor "$work/conn1.out" '^setup: (none)' 5

# 2. the daemon goes away and comes back
stop_daemon
waitfor "$work/conn1.out" '^state: restarting | The nisse daemon is restarting' 8
start_daemon
waitfor "$work/conn1.out" '^state: connected' 10
waitfor "$work/conn1.out" '^reconnected' 5
kill "$panel_pid" 2>/dev/null || true; wait "$panel_pid" 2>/dev/null || true
unset panel_pid

# 3. a panel that starts before the daemon waits, says so, and connects when it appears
stop_daemon
"$panel" --self-test-connection >"$work/conn2.out" 2>&1 &
panel2_pid=$!
waitfor "$work/conn2.out" '^start: waiting | Waiting for connection to the nisse daemon' 5
sleep 1
start_daemon
waitfor "$work/conn2.out" '^state: connected' 10
grep -q '^reconnected' "$work/conn2.out" && fail "a first connection is not a reconnection"
echo "connection e2e ok"
