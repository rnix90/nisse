#!/bin/bash
# N-214 live run: the real nisse-daemon and the real `claude` CLI (signed in to the Max account): what the usage status
# reads, first from the CLI's /usage report (no model call), then after one real turn (the rate_limit_event and the
# result line of the stream). Run inside the Fedora build VM after `cargo build`.
set -u
R=/tmp/live214
rm -rf "$R"; mkdir -p "$R/cfg/nisse" "$R/state" "$R/work"
printf 'main = "max"\n[[backends]]\nname = "max"\nkind = "max"\n' > "$R/cfg/nisse/backends.toml"
cat > "$R/inner.sh" <<'INNER'
export XDG_CONFIG_HOME=/tmp/live214/cfg XDG_STATE_HOME=/tmp/live214/state
cd /tmp/live214/work
BIN=/home/builder/nisse/services/target/debug/nisse-daemon
$BIN > /tmp/live214/daemon.log 2>&1 &
DPID=$!
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
show() { python3 -c 'import json,sys; j=json.loads(json.load(sys.stdin)["data"][0]); print(json.dumps(j, indent=1))'; }
for i in $(seq 1 30); do call GetUsage >/tmp/live214/u0.txt 2>&1 && break; sleep 0.5; done
echo "=== before anything: GetUsage"; show < /tmp/live214/u0.txt
echo "=== RefreshUsage (claude -p /usage, no model call)"
call RefreshUsage | show
SID=$(call NewSession | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0])')
busctl --user monitor org.nisse.Daemon1 --json=short > /tmp/live214/monitor.jsonl 2>&1 &
MPID=$!
sleep 1
echo "=== one real turn"
call SendMessage ss "$SID" "Reply with the single word hi." >/dev/null
for i in $(seq 1 90); do grep -q SessionDone /tmp/live214/monitor.jsonl && break; sleep 1; done
echo "=== GetUsage after the turn"
call GetUsage | show
echo "=== UsageChanged signals seen: $(grep -c UsageChanged /tmp/live214/monitor.jsonl)"
kill $MPID $DPID 2>/dev/null
INNER
dbus-run-session -- bash "$R/inner.sh"
