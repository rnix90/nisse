#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-215): the kill switch through the real daemon and the real panel
# client. $1 = daemon, $2 = panel, $3 = scratch folder. The caller exported the daemon's NISSE_* variables.
set -euo pipefail
daemon="$1" panel="$2" work="$3"
fail() { echo "FAIL: $*" >&2; exit 1; }

export NISSE_STATE="$work/sessions-n215.json"
"$daemon" &
daemon_pid=$!
trap 'kill $daemon_pid 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && break
    sleep 0.2
done

"$panel" --self-test-kill >"$work/panel-kill.out" 2>&1 || fail "panel client failed: $(cat "$work/panel-kill.out")"
out="$(cat "$work/panel-kill.out")"
echo "$out"
grep -qx 'before: released' <<<"$out" || fail "the switch did not start released"
grep -qx 'engage error: ' <<<"$out" || fail "the daemon refused to engage"
grep -qx 'after engage: engaged by desktop' <<<"$out" || fail "the status did not say the desktop engaged it"
grep -q '^refused: AI activity is paused' <<<"$out" || fail "a send while stopped was not refused with the reason"
grep -qx 'ran while stopped: no' <<<"$out" || fail "the AI ran while the switch was on"
grep -qx 'release error: ' <<<"$out" || fail "the daemon refused to release"
grep -qx 'after release: released' <<<"$out" || fail "the switch did not end released"
grep -qx 'reply: echo: ping' <<<"$out" || fail "a send after release did not run"
grep -q '"kind":"kill-switch"' "$NISSE_AUDIT_LOG" || fail "the kill switch was not audited"
echo "kill switch e2e ok"
