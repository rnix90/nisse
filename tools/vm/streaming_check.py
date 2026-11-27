# SPDX-License-Identifier: GPL-2.0-or-later
"""N-507a: Sunshine is installed but off and its ports are closed; Moonlight starts. Shown in a live Plasma session.

Boots an ISO with livevm, puts the two built packages in over the guest's network (the host is 10.0.2.2 to it), then:

    1  the firewall default is the public zone, and the nisse firewalld service for Sunshine knows its ports but no zone has it
    2  Sunshine's user service is not enabled and not active, and nothing listens on any Sunshine port
    3  Sunshine runs when started by hand and finds the display (in a VM without a GPU it opens no port: see the note in the code);
       stopped again, the ports are closed
    4  Moonlight starts in the Plasma session and shows a window (screenshot taken)

The packages are the ones just built (`tools/rpm/mock-build.sh moonlight-qt` and `... sunshine` in the build VM, pulled to a folder).

Usage: python tools/vm/streaming_check.py ISO OUTDIR(no spaces in the path) SUNSHINE_RPM MOONLIGHT_RPM
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

PORT = 8771
PORTS = "47984|47989|47990|48010|47998|47999|48000"
LISTENING = f"echo listening=$(ss -Hltnu 2>/dev/null | grep -Ec ':({PORTS})[[:space:]]')"
UNIT = "app-dev.lizardbyte.app.Sunshine.service"


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def value(text, key):
    """The text after `key=` on the last line that starts with it (the markers the commands print), None when absent."""
    found = re.findall(rf"^{re.escape(key)}=(.*)$", text, re.M)
    return found[-1].strip() if found else None


def main(iso, out, sunshine, moonlight):
    sunshine, moonlight = Path(sunshine).resolve(), Path(moonlight).resolve()
    if sunshine.parent != moonlight.parent:
        sys.exit("put both packages in one folder")
    # the two built packages and any library package beside them (the live ISO predates them, so what the image would pull in through
    # dependency solving, libopusenc and miniupnpc, is fetched from the release repository by hand and put beside them)
    extras = sorted(p for p in sunshine.parent.glob("*.rpm") if p not in (sunshine, moonlight))
    server = serve(sunshine.parent)
    vm = livevm.Vm(iso, out)
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

    try:
        vm.login()
        vm.prepare_session()
        vm.true_colors()
        time.sleep(20)

        pkgs = [sunshine, moonlight] + extras
        for i, rpm in enumerate(pkgs):
            text, _ = vm.run(f"curl -sf -o /tmp/p{i}.rpm http://10.0.2.2:{PORT}/{rpm.name} && echo fetched=$(wc -c < /tmp/p{i}.rpm)", 180)
            check(f"{rpm.name[:14]}: the package reaches the guest", value(text, "fetched") not in (None, "0"), str(value(text, "fetched")))
        # rpm without dependency solving (the guest's dnf cannot finish its repository sync here); the solving is proved by the image test
        # (tests/build/test_image_apps.sh), and here ldd shows that every library the two programs need is on the machine
        files = " ".join(f"/tmp/p{i}.rpm" for i in range(len(pkgs)))
        text, _ = vm.run(f"sudo rpm -Uvh --nodeps --force {files} 2>&1 | tail -3; rpm -q sunshine moonlight-qt", 300)
        check("the packages install", "sunshine-2026.914" in text and "moonlight-qt-6.2.0" in text, text.strip()[-90:])
        text, _ = vm.run("echo missing=$(ldd /usr/bin/sunshine /usr/bin/moonlight 2>&1 | grep 'not found' | awk '{print $1}' | paste -sd, -)", 60)
        check("every library the two programs need is on the machine", value(text, "missing") == "", str(value(text, "missing")))

        # 1  firewall: the default zone, the service known, no zone has it
        vm.run("sudo firewall-cmd --reload 2>&1 | tail -1", 90)
        text, _ = vm.run("echo zone=$(sudo firewall-cmd --get-default-zone); "
                         "echo svc=$(sudo firewall-cmd --info-service=sunshine 2>&1 | tr -s ' \\n' ' ' | cut -c1-160); "
                         "echo inzones=$(sudo firewall-cmd --list-all-zones 2>/dev/null | grep -c 'services:.*sunshine')", 90)
        check("the default firewall zone is public", value(text, "zone") == "public", str(value(text, "zone")))
        svc = value(text, "svc") or ""
        check("firewalld knows the sunshine service and its ports", "47989/tcp" in svc and "47998-48000/udp" in svc, svc[:100])
        check("no firewall zone has the sunshine service", value(text, "inzones") == "0", str(value(text, "inzones")))

        # 2  off and closed
        text, _ = vm.sh(f"echo enabled=$(systemctl --user is-enabled {UNIT} 2>&1 | head -1); echo active=$(systemctl --user is-active {UNIT} 2>&1 | head -1)", 40)
        check("Sunshine's user service is not enabled", value(text, "enabled") in ("disabled", "indirect", "static"), str(value(text, "enabled")))
        check("Sunshine's user service is not running", value(text, "active") == "inactive", str(value(text, "active")))
        text, _ = vm.run(LISTENING, 30)
        check("nothing listens on a Sunshine port", value(text, "listening") == "0", str(value(text, "listening")))

        # 3  it runs when asked. In a VM without a GPU it stays in its startup probe after listing the monitors (nothing is logged after the KMS
        #    monitor list and no port opens in 75 s: not diagnosed, see docs/default-apps.md), so what is checked is that it starts, finds the
        #    display and, being only started by hand, has not been switched on by the package. Whether it opens its ports and a client can pair
        #    needs a machine with a GPU encoder (a hand check, N-507c).
        vm.run(". /tmp/env.sh; nohup sunshine > /tmp/sun.log 2>&1 &", 20)
        time.sleep(30)
        log, _ = vm.run("tail -n 28 /tmp/sun.log | cut -c1-150; echo alive=$(pgrep -c -x sunshine)", 30)
        print("--- sunshine log:", log.strip(), sep=chr(10), flush=True)
        check("started by hand, Sunshine runs and finds the display", value(log, "alive") == "1" and "Found display" in log,
              f"alive={value(log, 'alive')}")
        vm.run("pkill -x sunshine; sleep 4; true", 30)
        text, _ = vm.run(LISTENING, 30)
        check("stopped again, the ports are closed", value(text, "listening") == "0", str(value(text, "listening")))

        # 4  Moonlight
        vm.run(". /tmp/env.sh; nohup moonlight > /tmp/moon.log 2>&1 &", 20)
        time.sleep(20)
        text, _ = vm.run("echo running=$(pgrep -c -x moonlight)", 30)
        log, _ = vm.run("tail -n 5 /tmp/moon.log | cut -c1-140", 30)
        print("--- moonlight log:", log.strip(), sep=chr(10), flush=True)
        check("Moonlight starts in the Plasma session", (value(text, "running") or "0") != "0", str(value(text, "running")))
        vm.shot("moonlight-window.png")
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "streaming-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
        server.shutdown()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
