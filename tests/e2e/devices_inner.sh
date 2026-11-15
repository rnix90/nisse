#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run by panel_daemon.sh inside a private session bus (N-221): the real daemon, a loopback device (the `device_probe`
# example, which signs its calls like a phone would) and the desktop side (busctl, standing for the panel). An unpaired
# client is refused; a paired one approves a held call and triggers the kill switch; the audit log names the device; a
# revoked device is refused. $1 = daemon, $2 = panel (unused), $3 = scratch folder, $4 = device_probe.
set -euo pipefail
daemon="$1" work="$3" probe="$4"
fail() { echo "FAIL: $*" >&2; exit 1; }

export NISSE_STATE="$work/sessions-n221.json"
"$daemon" &
daemon_pid=$!
trap 'kill $daemon_pid 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 >/dev/null 2>&1 && break
    sleep 0.2
done
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
datum() { python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0])'; }

# an unpaired client (a key the daemon has never seen) is refused
if "$probe" call 9 00000000000000000000000000000000 GetKillSwitch '[]' >"$work/unpaired.out" 2>&1; then
    fail "an unpaired client was served: $(cat "$work/unpaired.out")"
fi
grep -q 'not paired' "$work/unpaired.out" || fail "the refusal did not say the device is not paired: $(cat "$work/unpaired.out")"

# the desktop starts a pairing and shows the code; the device completes it
code="$(call StartPairing ss "Test phone" full | datum | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["code"])')"
[ "${#code}" = 8 ] || fail "the pairing code is not eight digits: $code"
if "$probe" pair 1 00000000 >/dev/null 2>&1 && [ "$code" != "00000000" ]; then fail "a wrong code paired a device"; fi
id="$("$probe" pair 1 "$code")" || fail "the right code was refused"
[ "${#id}" = 32 ] || fail "the device id is not 32 characters: $id"
if "$probe" pair 2 "$code" >/dev/null 2>&1; then fail "the code worked twice"; fi
devices="$(call ListDevices | python3 -c 'import json,sys; rows=[json.loads(x) for x in json.load(sys.stdin)["data"][0]]; print(len(rows), rows[0]["name"], rows[0]["role"])')"
[ "$devices" = "1 Test phone full" ] || fail "the device list says: $devices"

# a held call (an approval) is approved from the device, and the record names it
approval="$(call RequestApproval sssss e2e-session guardrail Bash "Bash: git push (outbound)" '{}' | datum)"
result="$("$probe" call 1 "$id" Approve "[\"$approval\"]")" || fail "the paired device could not approve: $result"
python3 - "$result" <<'PY' || fail "the approval was not approved by the device"
import json, sys
r = json.loads(sys.argv[1])["ok"]
assert r["state"] == "approved" and r["decided_by"] == "Test phone", r
PY

# the kill switch from the device
"$probe" call 1 "$id" EngageKillSwitch '["from the loopback phone"]' >/dev/null || fail "the device could not engage the kill switch"
kill_by="$(call GetKillSwitch | datum | python3 -c 'import json,sys; j=json.loads(sys.stdin.read()); print(j["engaged"], j["by"])')"
[ "$kill_by" = "True Test phone" ] || fail "the kill switch says: $kill_by"

# the audit log names the device
grep -q "\"device_id\":\"$id\"" "$NISSE_AUDIT_LOG" || fail "the audit log does not name the device id"
grep -q '"kind":"device-call"' "$NISSE_AUDIT_LOG" || fail "no device-call record"
grep -q '"kind":"device-paired"' "$NISSE_AUDIT_LOG" || fail "no device-paired record"
grep -q "$code" "$NISSE_AUDIT_LOG" && fail "the one-time code was written to the audit log"

# a revoked device is refused at once
call RevokeDevice ss "$id" desktop >/dev/null
if "$probe" call 1 "$id" GetKillSwitch '[]' >"$work/revoked.out" 2>&1; then fail "a revoked device was served"; fi
grep -q 'revoked' "$work/revoked.out" || fail "the refusal did not say revoked: $(cat "$work/revoked.out")"
echo "devices e2e ok"
