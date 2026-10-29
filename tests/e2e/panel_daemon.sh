#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# End to end: the real daemon (fake agent) and the real panel on a private session bus. Run in the Fedora
# build VM after: (cd services && cargo build) && (cd panel && cmake -S . -B build -G Ninja && cmake --build build)
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

daemon=services/target/debug/nisse-daemon
panel=panel/build/nisse-panel
[ -x "$daemon" ] || fail "build the daemon first: (cd services && cargo build)"
[ -x "$panel" ] || fail "build the panel first: (cd panel && cmake -S . -B build -G Ninja && cmake --build build)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export NISSE_FAKE_RUNNER=1 NISSE_AUDIT_LOG="$work/audit.jsonl" NISSE_CONFIG="$work/none.toml" QT_QPA_PLATFORM=offscreen

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
echo "$out" | grep -qx "backend: max" || { echo "FAIL: panel did not report the max backend" >&2; exit 1; }
echo "$out" | grep -qx "reply: echo: ping" || { echo "FAIL: panel did not get the fake agent reply" >&2; exit 1; }
' "$daemon" "$panel"

echo "PASS: panel and daemon end to end"
