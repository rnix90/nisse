#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-220): a turn through the real daemon and panel client; the events
# the panel saw live and the events the daemon replays; and after a daemon restart the same events and the numbers going on.
# $1 = daemon, $2 = panel, $3 = scratch folder.
set -euo pipefail
daemon="$1" panel="$2" work="$3"
fail() { echo "FAIL: $*" >&2; exit 1; }

export NISSE_STATE="$work/sessions-n220.json"
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
trap 'stop_daemon' EXIT
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
types() { # session after -> comma list of event types
    call EventsSince stu "$1" "$2" 0 | python3 -c 'import json,sys; p=json.loads(json.load(sys.stdin)["data"][0]); print(",".join(e["type"] for e in p["events"]))'
}

start_daemon
"$panel" --self-test-events >"$work/panel-events.out" 2>&1 || fail "panel client failed: $(cat "$work/panel-events.out")"
out="$(cat "$work/panel-events.out")"
echo "$out"
session="$(sed -n 's/^session: //p' <<<"$out")"
grep -qx 'live: 1 chunk, 1 done' <<<"$out" || fail "the panel did not see exactly one chunk and one done live (a repeat from the older signals?)"
grep -qx 'last seq: 3' <<<"$out" || fail "the panel did not follow the events to number 3"
grep -qx 'all events: user_message,chunk,done' <<<"$out" || fail "the daemon's replay is not message, chunk, done"
grep -qx 'after 1: chunk,done' <<<"$out" || fail "events since 1 are not what came after 1"
grep -qx 'after 3: ' <<<"$out" || fail "events since the last one are not empty"

# the daemon restarts: the events are still there, and a new message continues the numbers
stop_daemon
start_daemon
[ "$(types "$session" 0)" = "user_message,chunk,done" ] || fail "the events did not survive the restart: $(types "$session" 0)"
call SendMessage ss "$session" "pong" >/dev/null
for _ in $(seq 1 50); do
    [ "$(types "$session" 3)" = "user_message,chunk,done" ] && break
    sleep 0.2
done
[ "$(types "$session" 3)" = "user_message,chunk,done" ] || fail "the new turn was not numbered after the old one: $(types "$session" 3)"
seqs="$(call EventsSince stu "$session" 0 0 | python3 -c 'import json,sys; p=json.loads(json.load(sys.stdin)["data"][0]); print(",".join(str(e["seq"]) for e in p["events"]))')"
[ "$seqs" = "1,2,3,4,5,6" ] || fail "the numbers are not 1 to 6: $seqs"
echo "events e2e ok"
