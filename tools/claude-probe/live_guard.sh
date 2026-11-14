#!/bin/bash
# N-204: the real daemon + the real claude CLI + the real guardrail hook (autonomous and supervised). Run in the build VM:
#   sync the repo, cargo build -p nisse-daemon -p nisse-guard there, then: bash tools/build/vm.sh ssh bash -s < tools/claude-probe/live_guard.sh
# Needs the VM signed in (claude auth login). About 4 real prompts and a 60 second hold.
set -u
R=/tmp/live204
rm -rf "$R"; mkdir -p "$R/cfg/nisse" "$R/state" "$R/work"
printf 'main = "max"\n[[backends]]\nname = "max"\nkind = "max"\n' > "$R/cfg/nisse/backends.toml"
printf '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/home/builder/nisse/services/target/debug/nisse-guard-hook","timeout":900}]}]}}' > "$R/settings.json"
cat > "$R/inner.sh" <<'INNER'
export XDG_CONFIG_HOME=/tmp/live204/cfg XDG_STATE_HOME=/tmp/live204/state NISSE_CLAUDE_SETTINGS=/tmp/live204/settings.json NISSE_CLI_HUNG_SECS=20
cd /tmp/live204/work
BIN=/home/builder/nisse/services/target/debug/nisse-daemon
$BIN > /tmp/live204/daemon.log 2>&1 &
DPID=$!
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
for i in $(seq 1 30); do call NewSession >/tmp/live204/ns.txt 2>&1 && break; sleep 0.5; done
SID=$(python3 -c 'import json; print(json.load(open("/tmp/live204/ns.txt"))["data"][0])')
echo "session=$SID"
busctl --user monitor org.nisse.Daemon1 --json=short > /tmp/live204/monitor.jsonl 2>&1 &
MPID=$!
sleep 1
# strip busctl's s "..." wrapper and unescape \" for json
unwrap() { python3 -c 'import sys,json; d=json.load(sys.stdin)["data"][0]; print(json.dumps([json.loads(x) for x in d] if isinstance(d,list) else (json.loads(d) if d.startswith("{") else d)))'; }
pending_id() { call ListApprovals s pending 2>/dev/null | unwrap | python3 -c 'import sys,json; a=json.load(sys.stdin); print(a[0]["id"] if a else "")'; }
wait_pending() { for i in $(seq 1 120); do id=$(pending_id); [ -n "$id" ] && { echo "$id"; return 0; }; sleep 1; done; return 1; }
wait_done() { for i in $(seq 1 120); do grep -q "SessionDone" /tmp/live204/monitor.jsonl && [ "$(grep -c SessionDone /tmp/live204/monitor.jsonl)" -ge "$1" ] && return 0; sleep 1; done; return 1; }
show() { call GetApproval s "$1" 2>/dev/null | unwrap; }

GUARDED() { echo "Use the Bash tool to run exactly this command: echo $1 > /tmp/live204/$1.txt; curl -s -m 2 -d x http://127.0.0.1:9/ ; true   then reply only: done, or blocked if it did not run"; }
echo "=== case A: autonomous, guarded call held 60 s (longer than the 20 s hung limit), then approved"
call SendMessage ss "$SID" "$(GUARDED a)" >/dev/null
IDA=$(wait_pending) || echo "NO PENDING for A"
echo "pending: $IDA"; call ListApprovals s pending 2>/dev/null | unwrap | python3 -c 'import sys,json; [print("  asked_by=%s tool=%s category=%s summary=%s" % (a["asked_by"],a["tool"],a["detail"].get("category"),a["summary"])) for a in json.load(sys.stdin)]'
sleep 60
echo "after 60 s: still pending? $(pending_id | grep -c .)  SessionError so far: $(grep -c SessionError /tmp/live204/monitor.jsonl)  SessionDone so far: $(grep -c SessionDone /tmp/live204/monitor.jsonl)"
call Approve ss "$IDA" "desk-probe" >/dev/null
wait_done 1 && echo "turn A done"; ls -la /tmp/live204/a.txt 2>&1 | cut -c1-80

echo "=== case B: autonomous, guarded call denied"
call SendMessage ss "$SID" "$(GUARDED b)" >/dev/null
IDB=$(wait_pending) || echo "NO PENDING for B"
call Deny sss "$IDB" "desk-probe" "not today" >/dev/null
wait_done 2 && echo "turn B done"; ls -la /tmp/live204/b.txt 2>&1 | cut -c1-80

echo "=== case C: autonomous, free call"
call SendMessage ss "$SID" "Use the Bash tool to run exactly this command: echo free > /tmp/live204/c.txt   then reply only: done" >/dev/null
wait_done 3 && echo "turn C done"; ls -la /tmp/live204/c.txt 2>&1 | cut -c1-80
echo "approvals so far (expect 2): $(call ListApprovals s '' 2>/dev/null | unwrap | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"

echo "=== case D: supervised, guarded call: how many approvals?"
printf 'authority = "supervised"
main = "max"
[[backends]]
name = "max"
kind = "max"
' > "$XDG_CONFIG_HOME/nisse/backends.toml"
call SendMessage ss "$SID" "$(GUARDED d)" >/dev/null
for i in $(seq 1 90); do
  id=$(pending_id)
  if [ -n "$id" ]; then call ListApprovals s pending 2>/dev/null | unwrap | python3 -c 'import sys,json; [print("  approving asked_by=%s tool=%s" % (a["asked_by"],a["tool"])) for a in json.load(sys.stdin)]'; call Approve ss "$id" "desk-probe" >/dev/null; fi
  [ "$(grep -c SessionDone /tmp/live204/monitor.jsonl)" -ge 4 ] && break
  sleep 1
done
echo "turn D done: $(grep -c SessionDone /tmp/live204/monitor.jsonl) done signals"; ls -la /tmp/live204/d.txt 2>&1 | cut -c1-80
echo "--- approvals by state"
for s in approved denied expired pending; do echo "[$s]"; call ListApprovals s $s 2>/dev/null | unwrap | python3 -c 'import sys,json; [print(a["id"][:8], a["tool"], a["state"], a["decided_by"], a["reason"], a["summary"]) for a in json.load(sys.stdin)]'; done
echo "--- chunks (text)"
python3 - <<PY
import json
for l in open("/tmp/live204/monitor.jsonl"):
    try: m=json.loads(l)
    except Exception: continue
    if m.get("member")=="MessageChunk": print("chunk:", m["payload"]["data"][1][:200].replace("\n"," "))
    if m.get("member") in ("SessionError",): print("ERROR:", m["payload"]["data"])
    if m.get("member")=="ApprovalChanged": print("signal:", m["payload"]["data"])
PY
echo "--- audit kinds"
grep -o '"kind":"[a-z-]*"' /tmp/live204/state/nisse/audit.jsonl 2>/dev/null | sort | uniq -c
echo "--- daemon log"; tail -5 /tmp/live204/daemon.log
kill $MPID $DPID 2>/dev/null
INNER
dbus-run-session -- bash "$R/inner.sh"
