#!/bin/bash
# N-215 live run: the real nisse-daemon and the real `claude` CLI. A real turn starts a long command (sleep 301); the
# kill switch is engaged; the command, the tool process and the CLI must all be gone, and a new send must be refused.
# Run inside the Fedora build VM after `cargo build`.
set -u
R=/tmp/live215
rm -rf "$R"; mkdir -p "$R/cfg/nisse" "$R/state" "$R/work"
printf 'main = "max"\n[[backends]]\nname = "max"\nkind = "max"\n' > "$R/cfg/nisse/backends.toml"
cat > "$R/inner.sh" <<'INNER'
export XDG_CONFIG_HOME=/tmp/live215/cfg XDG_STATE_HOME=/tmp/live215/state
cd /tmp/live215/work
BIN=/home/builder/nisse/services/target/debug/nisse-daemon
$BIN > /tmp/live215/daemon.log 2>&1 &
DPID=$!
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
# the real command (its program name is sleep), not the CLI whose prompt text mentions it
procs() { ps -eo pid,ppid,comm,args | awk '$3=="sleep" && $5=="301" {print "tool command:", $0} $3=="claude" {print "claude:", substr($0,1,110)}'; }
for i in $(seq 1 30); do call NewSession >/tmp/live215/ns.txt 2>&1 && break; sleep 0.5; done
SID=$(python3 -c 'import json; print(json.load(open("/tmp/live215/ns.txt"))["data"][0])')
busctl --user monitor org.nisse.Daemon1 --json=short > /tmp/live215/monitor.jsonl 2>&1 &
MPID=$!
sleep 1
call SendMessage ss "$SID" "Run this exact shell command with the Bash tool and wait for it to finish: sleep 301" >/dev/null
for i in $(seq 1 90); do ps -eo comm,args | awk '$1=="sleep" && $3=="301" {f=1} END {exit !f}' && break; sleep 1; done
echo "=== chunks so far:"; python3 - <<PY
import json
for l in open("/tmp/live215/monitor.jsonl"):
    try: m = json.loads(l)
    except Exception: continue
    if m.get("member") == "MessageChunk": print("chunk:", m["payload"]["data"][1][:160].replace(chr(10), " "))
    if m.get("member") == "SessionError": print("ERROR:", m["payload"]["data"][1])
PY
echo "=== running before the kill switch:"
procs
echo "=== engage"
call EngageKillSwitch ss phone-probe "stop the long command" | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["data"][0]))'
sleep 3
echo "=== processes after (expect none):"
procs
echo "=== (end of list)"
call SendMessage ss "$SID" "hello again" >/dev/null
sleep 2
echo "=== chunks and errors seen"
python3 - <<PY
import json
for l in open("/tmp/live215/monitor.jsonl"):
    try: m = json.loads(l)
    except Exception: continue
    if m.get("member") == "MessageChunk": print("chunk:", m["payload"]["data"][1][:160].replace(chr(10), " "))
    if m.get("member") == "SessionError": print("ERROR:", m["payload"]["data"][1])
    if m.get("member") == "SessionDone": print("DONE")
    if m.get("member") == "KillSwitchChanged": print("SIGNAL:", m["payload"]["data"][0][:120])
PY
call ReleaseKillSwitch s phone-probe >/dev/null
echo "=== released: $(call GetKillSwitch | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["data"][0]))')"
kill $MPID $DPID 2>/dev/null
INNER
dbus-run-session -- bash "$R/inner.sh"
