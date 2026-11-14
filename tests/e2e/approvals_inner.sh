#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-205): a held call (an approval nobody has answered), the real
# panel client deciding it as the desktop device, and the desktop notice it sent. $1 = daemon, $2 = panel,
# $3 = scratch folder. The caller exported the daemon's NISSE_* variables.
set -euo pipefail
daemon="$1" panel="$2" work="$3"
fail() { echo "FAIL: $*" >&2; exit 1; }

"$daemon" &
daemon_pid=$!
trap 'kill $daemon_pid ${mon_pid:-} ${badge_mon_pid:-} ${panel_pid:-} 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && break
    sleep 0.2
done
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }

# No notification service runs here; the monitor still sees the call the panel makes to it.
dbus-monitor --session "type='method_call',interface='org.freedesktop.Notifications',member='Notify'" >"$work/notify.log" 2>&1 &
mon_pid=$!
# N-207: the taskbar badge is a signal on the session bus (Plasma listens for it).
dbus-monitor --session "type='signal',interface='com.canonical.Unity.LauncherEntry'" >"$work/badge.log" 2>&1 &
badge_mon_pid=$!
sleep 1

"$panel" --self-test-approvals >"$work/panel-approvals.out" 2>&1 &
panel_pid=$!
for _ in $(seq 1 50); do grep -qx listening "$work/panel-approvals.out" && break; sleep 0.2; done
grep -qx listening "$work/panel-approvals.out" || fail "panel client did not start: $(cat "$work/panel-approvals.out")"

id="$(call RequestApproval sssss "" e2e Bash "Bash: git push origin main (outbound)" '{"category":"outbound"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0])')"
[ -n "$id" ] || fail "RequestApproval returned no id"
# The held call: this blocks until somebody decides (the panel client does, as the desktop device).
held="$(call WaitApproval s "$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0])')"
wait "$panel_pid" || fail "panel client failed: $(cat "$work/panel-approvals.out")"
unset panel_pid
python3 - "$held" <<'PY' || fail "the held call was not released as approved by the desktop device"
import json, sys
a = json.loads(sys.argv[1])
assert a["state"] == "approved" and a["decided_by"] == "desktop", a
PY
grep -qx "approved: $id" "$work/panel-approvals.out" || fail "panel client did not report the approval"
grep -qx "error: " "$work/panel-approvals.out" || fail "panel client reported an error: $(cat "$work/panel-approvals.out")"
grep -q '"kind":"approval-approved"' "$NISSE_AUDIT_LOG" || fail "no approved record in the audit log: $(cat "$NISSE_AUDIT_LOG" 2>&1 | tail -5)"
grep -q '"actor":"desktop"' "$NISSE_AUDIT_LOG" || fail "the audit record does not name the desktop device"
sleep 0.5
grep -q 'nisse needs you' "$work/notify.log" || fail "no desktop notice was sent: $(cat "$work/notify.log")"
grep -q 'git push origin main' "$work/notify.log" || fail "the desktop notice does not name the call"
python3 - "$work/badge.log" <<'PY' || fail "the taskbar badge did not go 1 then 0: $(cat "$work/badge.log")"
import re, sys
text = open(sys.argv[1]).read()
assert "application://nisse-panel.desktop" in text, "not addressed to the panel launcher"
counts = [int(n) for n in re.findall(r'string "count"\s+variant\s+int64 (\d+)', text)]
assert counts == [1, 0], counts
PY
echo "approvals e2e ok"
