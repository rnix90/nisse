#!/bin/bash
# N-224: the real daemon + the real claude CLI, supervised, three approval outcomes. Run inside the build VM:
#   bash tools/build/vm.sh sync; bash tools/build/vm.sh ssh "cd ~/nisse/services && cargo build -q -p nisse-daemon"; bash tools/build/vm.sh ssh bash -s < tools/claude-probe/live_host.sh
# Needs the VM signed in (claude auth login). Each run is three real prompts.
set -u
R=/tmp/live224
rm -rf "$R"; mkdir -p "$R/cfg/nisse" "$R/state" "$R/work"
printf 'authority = "supervised"\napproval_expiry_secs = 25\nmain = "max"\n[[backends]]\nname = "max"\nkind = "max"\n' > "$R/cfg/nisse/backends.toml"
cat > "$R/inner.sh" <<'INNER'
export XDG_CONFIG_HOME=/tmp/live224/cfg XDG_STATE_HOME=/tmp/live224/state
cd /tmp/live224/work
BIN=/home/builder/nisse/services/target/debug/nisse-daemon
$BIN > /tmp/live224/daemon.log 2>&1 &
DPID=$!
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
for i in $(seq 1 30); do call NewSession >/tmp/live224/ns.txt 2>&1 && break; sleep 0.5; done
SID=$(python3 -c 'import json; print(json.load(open("/tmp/live224/ns.txt"))["data"][0])')
echo "session=$SID"
busctl --user monitor org.nisse.Daemon1 --json=short > /tmp/live224/monitor.jsonl 2>&1 &
MPID=$!
sleep 1
# strip busctl's s "..." wrapper and unescape \" for json
unwrap() { python3 -c 'import sys,json; d=json.load(sys.stdin)["data"][0]; print(json.dumps([json.loads(x) for x in d] if isinstance(d,list) else (json.loads(d) if d.startswith("{") else d)))'; }
pending_id() { call ListApprovals s pending 2>/dev/null | unwrap | python3 -c 'import sys,json; a=json.load(sys.stdin); print(a[0]["id"] if a else "")'; }
wait_pending() { for i in $(seq 1 120); do id=$(pending_id); [ -n "$id" ] && { echo "$id"; return 0; }; sleep 1; done; return 1; }
wait_done() { for i in $(seq 1 120); do grep -q "SessionDone" /tmp/live224/monitor.jsonl && [ "$(grep -c SessionDone /tmp/live224/monitor.jsonl)" -ge "$1" ] && return 0; sleep 1; done; return 1; }
show() { call GetApproval s "$1" 2>/dev/null | unwrap; }

echo "=== case 1: approve"
call SendMessage ss "$SID" "Use the Bash tool to run exactly this command: echo approved > /tmp/live224/a.txt   then reply only: done" >/dev/null
ID1=$(wait_pending) || { echo "NO PENDING APPROVAL for case 1"; }
echo "pending id: $ID1"
call ListApprovals s pending 2>/dev/null | unwrap
call Approve ss "$ID1" "desk-probe" 2>&1 | unwrap
wait_done 1 && echo "turn 1 done"
ls -la /tmp/live224/a.txt 2>&1; cat /tmp/live224/a.txt 2>&1

echo "=== case 2: deny"
call SendMessage ss "$SID" "Use the Bash tool to run exactly this command: echo denied > /tmp/live224/b.txt   then reply only: done, or denied if the tool did not run" >/dev/null
ID2=$(wait_pending) || { echo "NO PENDING APPROVAL for case 2"; }
echo "pending id: $ID2"
call Deny sss "$ID2" "desk-probe" "not today" 2>&1 | unwrap
wait_done 2 && echo "turn 2 done"
ls -la /tmp/live224/b.txt 2>&1

echo "=== case 3: expire (25 s)"
call SendMessage ss "$SID" "Use the Bash tool to run exactly this command: echo expired > /tmp/live224/c.txt   then reply only: done, or denied if the tool did not run" >/dev/null
ID3=$(wait_pending) || { echo "NO PENDING APPROVAL for case 3"; }
echo "pending id: $ID3 (not answering)"
wait_done 3 && echo "turn 3 done"
ls -la /tmp/live224/c.txt 2>&1
echo "--- approvals by state"
for s in approved denied expired pending; do echo "[$s]"; call ListApprovals s $s 2>/dev/null | unwrap | python3 -c 'import sys,json; [print(a["id"][:8], a["tool"], a["state"], a["decided_by"], a["reason"], a["summary"]) for a in json.load(sys.stdin)]'; done
echo "--- chunks (text)"
python3 - <<PY
import json
for l in open("/tmp/live224/monitor.jsonl"):
    try: m=json.loads(l)
    except Exception: continue
    if m.get("member")=="MessageChunk": print("chunk:", m["payload"]["data"][1][:200].replace("\n"," "))
    if m.get("member") in ("SessionError",): print("ERROR:", m["payload"]["data"])
    if m.get("member")=="ApprovalChanged": print("signal:", m["payload"]["data"])
PY
echo "--- audit kinds"
grep -o '"kind":"[a-z-]*"' /tmp/live224/state/nisse/audit.jsonl 2>/dev/null | sort | uniq -c
echo "--- daemon log"; tail -5 /tmp/live224/daemon.log
kill $MPID $DPID 2>/dev/null
INNER
dbus-run-session -- bash "$R/inner.sh"
