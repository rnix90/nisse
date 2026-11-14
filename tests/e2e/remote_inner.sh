#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-209): the remote access switch through the real daemon and the
# real panel client, with a fake `claude` that records how it was started. $1 = daemon, $2 = panel, $3 = scratch folder.
set -euo pipefail
daemon="$1" panel="$2" work="$3"
fail() { echo "FAIL: $*" >&2; exit 1; }

fake="$work/remote-bin"
mkdir -p "$fake" "$work/remote-home"
cat >"$fake/claude" <<'FAKE'
#!/bin/sh
echo "$@" >"$FAKE_OUT/args"
echo "$HOME" >"$FAKE_OUT/home"
read line
echo "$line" >"$FAKE_OUT/stdin"
echo $$ >"$FAKE_OUT/pid"
exec sleep 600
FAKE
chmod +x "$fake/claude"
export FAKE_OUT="$fake" NISSE_CLAUDE_BIN="$fake/claude" HOME="$work/remote-home"
export NISSE_STATE="$work/sessions-n209.json"

"$daemon" &
daemon_pid=$!
trap 'kill $daemon_pid 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && break
    sleep 0.2
done

"$panel" --self-test-remote >"$work/panel-remote.out" 2>&1 || fail "panel client failed: $(cat "$work/panel-remote.out")"
out="$(cat "$work/panel-remote.out")"
echo "$out"
grep -qx 'before: off' <<<"$out" || fail "the switch did not start off"
grep -qx 'set on error: ' <<<"$out" || fail "the daemon refused the switch"
grep -qx 'running: yes' <<<"$out" || fail "the daemon never said the server was running"
grep -qx 'set off error: ' <<<"$out" || fail "the daemon refused to switch it off"
grep -qx 'after: off' <<<"$out" || fail "the switch did not end off"
grep -q '^remote-control --name nisse-' "$fake/args" || fail "the server was started as: $(cat "$fake/args")"
grep -q -- '--permission-mode bypassPermissions' "$fake/args" || fail "no permission mode: $(cat "$fake/args")"
[ "$(cat "$fake/stdin")" = "y" ] || fail "the one-time consent question was not answered"
[ "$(cat "$fake/home")" = "$work/remote-home" ] || fail "the server did not run with the user home"
python3 - "$work/remote-home/.claude.json" "$work/remote-home" <<'PY' || fail "the working folder was not trusted"
import json, sys
j = json.load(open(sys.argv[1]))
assert j["projects"][sys.argv[2]]["hasTrustDialogAccepted"] is True
PY
pid="$(cat "$fake/pid")"
for _ in $(seq 1 30); do [ -e "/proc/$pid" ] || break; sleep 0.1; done
[ ! -e "/proc/$pid" ] || fail "the server is still running after the switch was turned off"
grep -q '"kind":"remote-access"' "$NISSE_AUDIT_LOG" || fail "the switch was not audited"
echo "remote e2e ok"
