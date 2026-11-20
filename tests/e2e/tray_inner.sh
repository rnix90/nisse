#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-415b): the tray item of the REAL panel, read off the bus the way Plasma's
# system tray reads it, following the REAL daemon. $1 = daemon, $2 = panel, $3 = scratch folder. The caller exported the daemon's
# NISSE_* variables. There is no system tray on this bus; that the real Plasma tray shows the item is the live-session check
# (tools/vm/tray_check.py).
set -euo pipefail
daemon="$1" panel="$2" work="$3"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Its own folder: the daemon keeps the kill switch in a file beside the sessions file, and an earlier script may have left it on.
mkdir -p "$work/n415b"
export NISSE_STATE="$work/n415b/sessions.json"
daemon_pid=""
start_daemon() {
    "$daemon" &
    daemon_pid=$!
    for _ in $(seq 1 50); do
        busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    fail "the daemon did not come up"
}
panel_pid=""
demo_pid=""
trap 'kill $daemon_pid $panel_pid $demo_pid 2>/dev/null || true' EXIT
start_daemon

item_of() { echo "org.kde.StatusNotifierItem-$1-1"; }
prop() { busctl --user get-property "$1" /StatusNotifierItem org.kde.StatusNotifierItem "$2"; }
icon() { prop "$1" IconName | cut -d'"' -f2; }
wait_icon() { # service expected
    for _ in $(seq 1 60); do
        [ "$(icon "$1" 2>/dev/null || true)" = "$2" ] && return 0
        sleep 0.25
    done
    fail "the tray icon did not become $2 (it is '$(icon "$1" 2>&1 || true)')"
}

# 1. the real panel starts and shows its tray item, idle, with the daemon there
"$panel" >"$work/panel-tray.out" 2>&1 &
panel_pid=$!
svc="$(item_of "$panel_pid")"
for _ in $(seq 1 100); do
    busctl --user list 2>/dev/null | grep -q "$svc" && break
    sleep 0.2
done
busctl --user list | grep -q "$svc" || fail "the panel did not put a StatusNotifierItem on the bus ($(cat "$work/panel-tray.out"))"
wait_icon "$svc" nisse-tray-idle-symbolic
[ "$(prop "$svc" Title | cut -d'"' -f2)" = "nisse" ] || fail "the tray title is not 'nisse'"
[ "$(prop "$svc" Id | cut -d'"' -f2)" = "nisse-panel" ] || fail "the tray id is not nisse-panel"
prop "$svc" Status | grep -q '"Active"' || fail "an idle tray item must be Active"
prop "$svc" ToolTip | grep -q '"Ready"' || fail "the idle tooltip must say Ready"
echo "ok   the real panel shows an idle tray item with the daemon up"

# 2. the daemon's kill switch moves the icon: the real daemon, the real panel client, the real item
busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 EngageKillSwitch ss phone "e2e" >/dev/null
wait_icon "$svc" nisse-tray-paused-symbolic
prop "$svc" ToolTip | grep -q 'AI paused' || fail "the paused tooltip must say AI paused"
busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 ReleaseKillSwitch s phone >/dev/null
wait_icon "$svc" nisse-tray-idle-symbolic
echo "ok   the kill switch turns the icon to paused and back"

# 3. the right-click menu's Pause entry (id 3) really pauses the daemon, as the desktop device, and flips to Resume
label() { busctl --user call "$svc" /MenuBar com.canonical.dbusmenu GetProperty is 3 label | cut -d'"' -f2; }
[ "$(label)" = "Pause AI" ] || fail "the menu entry should say Pause AI, says '$(label)'"
busctl --user call "$svc" /MenuBar com.canonical.dbusmenu Event isvu 3 clicked s "" 0 >/dev/null
wait_icon "$svc" nisse-tray-paused-symbolic
busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 GetKillSwitch | grep -q 'engaged\\":true' || fail "the menu did not engage the daemon's kill switch"
grep -q '"kind":"kill-switch"' "$NISSE_AUDIT_LOG" || fail "the pause from the menu was not audited"
grep -q 'desktop' "$NISSE_AUDIT_LOG" || fail "the pause from the menu was not recorded as the desktop device"
[ "$(label)" = "Resume AI" ] || fail "while paused the menu entry should say Resume AI, says '$(label)'"
busctl --user call "$svc" /MenuBar com.canonical.dbusmenu Event isvu 3 clicked s "" 0 >/dev/null
wait_icon "$svc" nisse-tray-idle-symbolic
echo "ok   the menu pauses and resumes the real daemon"

# 4. the daemon goes away: offline wins; it comes back: idle again
kill "$daemon_pid"; wait "$daemon_pid" 2>/dev/null || true
wait_icon "$svc" nisse-tray-offline-symbolic
prop "$svc" ToolTip | grep -q 'Daemon not reachable' || fail "the offline tooltip must say the daemon is not reachable"
start_daemon
wait_icon "$svc" nisse-tray-idle-symbolic
echo "ok   offline while the daemon is away, idle when it is back"

# 5. a forced state, as the screenshots and the live check use: needs you with a count on the tooltip and the menu
"$panel" --demo-tray needs-you:2 >"$work/panel-demo.out" 2>&1 &
demo_pid=$!
dsvc="$(item_of "$demo_pid")"
for _ in $(seq 1 100); do
    busctl --user list 2>/dev/null | grep -q "$dsvc" && break
    sleep 0.2
done
wait_icon "$dsvc" nisse-tray-needs-you-symbolic
prop "$dsvc" Status | grep -q '"NeedsAttention"' || fail "needs you must be NeedsAttention"
prop "$dsvc" ToolTip | grep -q '2 approvals waiting' || fail "the tooltip must carry the approvals count"
busctl --user call "$dsvc" /MenuBar com.canonical.dbusmenu GetProperty is 2 label | grep -q 'Approvals (2)' || fail "the menu must carry the approvals count"
echo "ok   --demo-tray needs-you:2 shows the count on the tooltip and the menu"
echo "tray e2e ok"
