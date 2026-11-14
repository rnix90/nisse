#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-206): three live sessions through the real daemon (fake agent)
# and the real panel client; a rename, a close, and what a second client sees. $1 = daemon, $2 = panel, $3 = scratch
# folder. The caller exported the daemon's NISSE_* variables.
set -euo pipefail
daemon="$1" panel="$2" work="$3"
fail() { echo "FAIL: $*" >&2; exit 1; }

# a fresh session list, so the sessions of the earlier checks do not show
export NISSE_STATE="$work/sessions-n206.json"
"$daemon" &
daemon_pid=$!
trap 'kill $daemon_pid 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && break
    sleep 0.2
done

"$panel" --self-test-sessions >"$work/panel-sessions.out" 2>&1 || fail "panel client failed: $(cat "$work/panel-sessions.out")"
out="$(cat "$work/panel-sessions.out")"
echo "$out"
grep -qx 'listed: 3' <<<"$out" || fail "the daemon did not list the three sessions"
grep -qx 'rename error: ' <<<"$out" || fail "rename was refused"
grep -qE '^second: [0-9a-f-]{36}\|Taxes$' <<<"$out" || fail "the rename did not show in the daemon's list"
for i in 0 1 2; do
    grep -qx "reply $i: echo: ping$i" <<<"$out" || fail "session $i did not get its own reply"
done
grep -qx 'close error: ' <<<"$out" || fail "close was refused"
grep -qx 'after close: 2' <<<"$out" || fail "the closed session is still listed"
grep -qx 'unknown close error empty: 0' <<<"$out" || fail "closing an unknown session was accepted"
changes="$(sed -n 's/^changes: //p' <<<"$out")"
[ "${changes:-0}" -ge 5 ] || fail "the client saw too few SessionsChanged signals: $changes"

# A second client (here busctl) sees the same two sessions and the name.
second="$(busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 ListSessions |
    python3 -c 'import json,sys; rows=[json.loads(x) for x in json.load(sys.stdin)["data"][0]]; print(len(rows), rows[1]["title"])')"
[ "$second" = "2 Taxes" ] || fail "a second client sees: $second"
grep -q '"kind":"session-closed"' "$NISSE_AUDIT_LOG" || fail "the close was not audited"
echo "sessions e2e ok"
