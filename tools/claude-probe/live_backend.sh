#!/bin/bash
# N-211 live run: the real nisse-daemon and the real `claude` CLI, with a session pointed at a stub that implements the
# Anthropic /v1/messages endpoint (what Ollama serves). Shows that the request really arrives at the stub, with which
# model names, and that the stub's answer comes back as the reply. Run inside the Fedora build VM after `cargo build`.
set -u
R=/tmp/live211
rm -rf "$R"; mkdir -p "$R/cfg/nisse" "$R/state" "$R/work"
cat > "$R/stub.py" <<'STUB'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = open("/tmp/live211/stub.log", "a", buffering=1)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _read(self):
        n = int(self.headers.get("content-length") or 0)
        return self.rfile.read(n) if n else b""

    def do_HEAD(self):
        LOG.write("HEAD %s\n" % self.path)
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        LOG.write("GET %s\n" % self.path)
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
        body = self._read()
        try:
            j = json.loads(body or b"{}")
        except Exception:
            j = {}
        LOG.write("POST %s model=%s stream=%s auth=%s tools=%d\n" % (
            self.path, j.get("model"), j.get("stream"),
            (self.headers.get("authorization") or self.headers.get("x-api-key") or "-")[:14], len(j.get("tools") or [])))
        if self.path.startswith("/v1/messages/count_tokens"):
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"input_tokens": 10}).encode())
            return
        text = "pong from the stub"
        if j.get("stream"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            ev = [
                ("message_start", {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "model": j.get("model"), "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 1}}}),
                ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 5}}),
                ("message_stop", {"type": "message_stop"}),
            ]
            for name, data in ev:
                self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode())
                self.wfile.flush()
        else:
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"id": "msg_1", "type": "message", "role": "assistant", "model": j.get("model"), "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "usage": {"input_tokens": 10, "output_tokens": 5}}).encode())


ThreadingHTTPServer(("127.0.0.1", 18434), H).serve_forever()
STUB
printf 'main = "max"\n[[backends]]\nname = "max"\nkind = "max"\n[[backends]]\nname = "stub"\nkind = "ollama"\nbase_url = "http://127.0.0.1:18434"\nmodel = "gpt-oss:20b"\n' > "$R/cfg/nisse/backends.toml"
cat > "$R/inner.sh" <<'INNER'
export XDG_CONFIG_HOME=/tmp/live211/cfg XDG_STATE_HOME=/tmp/live211/state
cd /tmp/live211/work
python3 /tmp/live211/stub.py &
SPID=$!
sleep 1
BIN=/home/builder/nisse/services/target/debug/nisse-daemon
$BIN > /tmp/live211/daemon.log 2>&1 &
DPID=$!
call() { busctl --user --json=short call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 "$@"; }
for i in $(seq 1 30); do call NewSession >/tmp/live211/ns.txt 2>&1 && break; sleep 0.5; done
SID=$(python3 -c 'import json; print(json.load(open("/tmp/live211/ns.txt"))["data"][0])')
busctl --user monitor org.nisse.Daemon1 --json=short > /tmp/live211/monitor.jsonl 2>&1 &
MPID=$!
sleep 1
call SetSessionBackend ss "$SID" stub >/dev/null && echo "session pointed at the stub"
call SendMessage ss "$SID" "Reply with the single word pong." >/dev/null
for i in $(seq 1 90); do grep -q SessionDone /tmp/live211/monitor.jsonl && break; sleep 1; done
echo "--- what reached the stub"
cat /tmp/live211/stub.log
echo "--- chunks and errors"
python3 - <<PY
import json
for l in open("/tmp/live211/monitor.jsonl"):
    try: m = json.loads(l)
    except Exception: continue
    if m.get("member") == "MessageChunk": print("chunk:", m["payload"]["data"][1][:200].replace("\n", " "))
    if m.get("member") == "SessionError": print("ERROR:", m["payload"]["data"])
PY
kill $MPID $DPID $SPID 2>/dev/null
INNER
dbus-run-session -- bash "$R/inner.sh"
