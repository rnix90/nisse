# SPDX-License-Identifier: GPL-2.0-or-later
"""N-507c spike: why does a started Sunshine open no port in a VM without a GPU? Runs it with debug logging and reports what it says, what
its threads wait on and which ports it opens, with and without a named capture method.

Usage: python tools/vm/sunshine_probe.py ISO OUTDIR(no spaces in the path) RPM_FOLDER
       (RPM_FOLDER holds sunshine, libopusenc, miniupnpc and SDL2_ttf packages, as tools/vm/streaming_check.py uses)
"""
import functools
import http.server
import re
import socketserver
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

PORT = 8773
LISTEN = "echo listening=$(ss -Hltnu 2>/dev/null | grep -Ec ':(47984|47989|47990|48010|47998|47999|48000)[[:space:]]')"


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def value(text, key):
    found = re.findall(rf"^{re.escape(key)}=(.*)$", text, re.M)
    return found[-1].strip() if found else None


def report(vm, title, log):
    text, _ = vm.run(f"tail -n 45 {log} | cut -c1-170", 30)
    print(f"--- {title}: last log lines\n{text.strip()}", flush=True)
    text, _ = vm.run("echo pid=$(pgrep -x sunshine | head -1)", 30)
    pid = value(text, "pid") or ""
    if pid:
        text, _ = vm.run(f"echo threads=$(ls /proc/{pid}/task | wc -l) wchan=$(cat /proc/{pid}/wchan)", 30)
        print("    " + (text.strip().splitlines()[-1] if text.strip() else ""), flush=True)
        text, _ = vm.run(f"for t in /proc/{pid}/task/*; do echo $(cat $t/comm):$(cat $t/wchan); done | sort | uniq -c | head -12", 30)
        print("    thread waits:\n" + text.strip(), flush=True)
    text, _ = vm.run(LISTEN, 30)
    print(f"    ports open: {value(text, 'listening')}", flush=True)


def main(iso, out, folder):
    folder = Path(folder).resolve()
    rpms = sorted(p for p in folder.glob("*.rpm") if not p.name.startswith("moonlight"))
    server = serve(folder)
    vm = livevm.Vm(iso, out)
    try:
        vm.login()
        vm.prepare_session()
        time.sleep(20)
        for i, rpm in enumerate(rpms):
            vm.run(f"curl -sf -o /tmp/p{i}.rpm http://10.0.2.2:{PORT}/{rpm.name}", 180)
        files = " ".join(f"/tmp/p{i}.rpm" for i in range(len(rpms)))
        text, _ = vm.run(f"sudo rpm -Uvh --nodeps --force {files} 2>&1 | tail -2; rpm -q sunshine", 300)
        print("install:", text.strip()[-80:], flush=True)
        for title, extra in (("default capture", ""), ("capture=kms", "capture=kms"), ("capture=wlr", "capture=wlr")):
            vm.run("pkill -x sunshine; sleep 3; true", 30)
            vm.run(f". /tmp/env.sh; rm -rf ~/.config/sunshine; nohup sunshine min_log_level=debug {extra} > /tmp/sun.log 2>&1 &", 20)
            time.sleep(60)
            report(vm, title, "/tmp/sun.log")
    finally:
        vm.close()
        server.shutdown()
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
