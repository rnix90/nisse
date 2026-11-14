#!/bin/bash
# N-209 live run: the real nisse-daemon starts the real `claude remote-control` (signed in to an account) when the
# remote access switch is turned on, with the machine's settings and the authority's permission mode, keeps it up, and
# stops it when the switch is turned off. Run inside the Fedora build VM after `cargo build` and a `claude auth login`.
# Nothing is sent from a phone: this only shows that the real CLI accepts the flags and stays up.
set -u
R=/tmp/live209
rm -rf "$R"; mkdir -p "$R/cfg/nisse" "$R/state" "$R/home"
printf 'main = "max"\n[[backends]]\nname = "max"\nkind = "max"\n' > "$R/cfg/nisse/backends.toml"
cat > "$R/inner.sh" <<'INNER'
export XDG_CONFIG_HOME=/tmp/live209/cfg XDG_STATE_HOME=/tmp/live209/state
# a copy of the real login, in a scratch home, so ~/.claude.json of the VM user is not touched
cp -r /home/builder/.claude /tmp/live209/home/.claude 2>/dev/null
cp /home/builder/.claude.json /tmp/live209/home/.claude.json 2>/dev/null
export HOME=/tmp/live209/home PATH=/home/builder/.local/bin:$PATH
BIN=/home/builder/nisse/services/target/debug/nisse-daemon
$BIN > /tmp/live209/daemon.log 2>&1 &
DPID=$!
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
for i in $(seq 1 30); do call GetRemoteAccess >/tmp/live209/s0.txt 2>&1 && break; sleep 0.5; done
echo "start: $(cat /tmp/live209/s0.txt)"
call SetRemoteAccess b true >/dev/null
for i in $(seq 1 40); do
  sleep 1
  S=$(call GetRemoteAccess | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["data"][0]))')
  case "$S" in *'"running": true'*|*'"running":true'*) break;; esac
done
echo "after on: $S"
sleep 20
echo "after 20 s more: $(call GetRemoteAccess | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["data"][0]))')"
echo "--- the server as the daemon started it"
ps -eo pid,args | grep "[r]emote-control" | cut -c1-240
echo "--- trust entry"
python3 -c 'import json; j=json.load(open("/tmp/live209/home/.claude.json")); print({k: v.get("hasTrustDialogAccepted") for k, v in j.get("projects", {}).items() if k=="/tmp/live209/home"})'
call SetRemoteAccess b false >/dev/null
sleep 3
echo "after off: $(call GetRemoteAccess | python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["data"][0]))')"
echo "--- any remote-control left?"
ps -eo pid,args | grep "[r]emote-control" | cut -c1-120
echo "--- daemon log"; tail -5 /tmp/live209/daemon.log
kill $DPID 2>/dev/null
INNER
dbus-run-session -- bash "$R/inner.sh"
