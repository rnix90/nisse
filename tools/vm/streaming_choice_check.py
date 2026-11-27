# SPDX-License-Identifier: GPL-2.0-or-later
"""N-507c: the trustworthy network and Sunshine choices end to end, in a live session: the real engine, the real NetworkManager and firewalld,
the real Sunshine started through its user service, and a client in a network namespace that the firewall treats as home or as public.

Boots an ISO with livevm, puts the packages in over the guest's network (the host is 10.0.2.2 to it), then:

    1  nothing is on by default: no Sunshine port listens, the user service is not enabled, the sunshine firewall service is in no zone
    2  "trustworthy network" yes: the connection in use is in the home zone (NetworkManager and the running interface); no puts it back
    3  Sunshine on: the firewall service is in the home zone permanently, the user service is enabled for login, the starter config is there,
       and a user's first login copies it
    4  Sunshine started through its user service listens (with capture = kms there is no approval dialog), and a client on a private-address
       network reaches the streaming port while its interface is in the home zone and does NOT reach it in the public zone; the settings page
       refuses that client (this PC only)
    5  Sunshine off: the service leaves the home zone, the user service is not enabled, the starter config is gone, nothing listens

Usage: python tools/vm/streaming_choice_check.py ISO OUTDIR(no spaces in the path) RPM_FOLDER
       (RPM_FOLDER holds nisse-streaming, nisse-choices, sunshine, libopusenc and miniupnpc packages)
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

PORT = 8774
UNIT = "app-dev.lizardbyte.app.Sunshine.service"
LISTEN = "echo listening=$(ss -Hltn 2>/dev/null | grep -Ec ':(47984|47989|47990|48010)[[:space:]]')"


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def value(text, key):
    found = re.findall(rf"^{re.escape(key)}=(.*)$", text, re.M)
    return found[-1].strip() if found else None


def main(iso, out, folder):
    folder = Path(folder).resolve()
    rpms = sorted(folder.glob("*.rpm"))
    server = serve(folder)
    vm = livevm.Vm(iso, out)
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

    def soft(cmd, timeout=60):
        """Runs a command whose effect is checked separately: the serial console can lose the end marker when the system logs to it
        (a new network interface does), which says nothing about the command."""
        try:
            return vm.run(cmd, timeout)[0]
        except TimeoutError:
            time.sleep(5)
            return ""

    def got(cmd, key, timeout=60):
        for attempt in range(2):
            try:
                text, _ = vm.run(cmd, timeout)
                return value(text, key)
            except TimeoutError:
                time.sleep(5)
        return None

    try:
        vm.login()
        vm.prepare_session()
        time.sleep(20)
        for i, rpm in enumerate(rpms):
            vm.run(f"curl -sf -o /tmp/p{i}.rpm http://10.0.2.2:{PORT}/{rpm.name}", 180)
        files = " ".join(f"/tmp/p{i}.rpm" for i in range(len(rpms)))
        text, _ = vm.run(f"sudo rpm -Uvh --nodeps --force {files} 2>&1 | tail -2; rpm -q nisse-streaming sunshine nisse-choices", 300)
        check("the packages install", "nisse-streaming" in text and "sunshine-2026" in text and "nisse-choices-0.1-2" in text, text.strip()[-90:])
        vm.run("sudo firewall-cmd --reload 2>&1 | tail -1", 90)

        # 1  nothing on by default
        check("nothing listens by default", got(LISTEN, "listening") == "0", str(got(LISTEN, "listening")))
        zones = got("echo z=$(sudo firewall-cmd --list-all-zones 2>/dev/null | grep -c 'services:.*sunshine')", "z")
        check("the sunshine firewall service is in no zone by default", zones == "0", str(zones))
        lst = got("echo n=$(sudo nisse-choices list --json --stage firstboot | grep -o '\"id\": *\"[a-z-]*\"' | grep -c -E 'trusted-network|sunshine')", "n")
        check("the engine lists the four choices", lst == "4", str(lst))

        # 2  the trustworthy network
        conn = got("echo c=$(nmcli -t -f UUID,TYPE,DEVICE connection show --active | grep -E '802-3-ethernet|802-11-wireless' | head -1)", "c") or ""
        uuid, _, dev = (conn.split(":") + ["", "", ""])[:3]
        check("a real network connection is in use (the VM's wired one)", bool(uuid and dev), conn)
        if uuid and dev:
            vm.run("sudo nisse-choices set trusted-network true 2>&1 | tail -1; sudo nisse-choices apply --id trusted-network 2>&1 | tail -2", 120)
            z1 = got(f"echo z=$(nmcli -g connection.zone connection show {uuid})", "z")
            z2 = got(f"echo z=$(sudo firewall-cmd --get-zone-of-interface={dev})", "z")
            check("yes: NetworkManager keeps the connection in the home zone", z1 == "home", str(z1))
            check("yes: and the interface is in home right now", z2 == "home", str(z2))
            vm.run("sudo nisse-choices set trusted-network false 2>&1 | tail -1; sudo nisse-choices apply --id trusted-network 2>&1 | tail -2", 120)
            z1 = got(f"echo z=$(nmcli -g connection.zone connection show {uuid})", "z")
            z2 = got(f"echo z=$(sudo firewall-cmd --get-zone-of-interface={dev})", "z")
            check("no: the connection is back in the default zone", (z1 or "") == "" and z2 == "public", f"nm='{z1}' now={z2}")

        # 3  Sunshine on
        vm.run("sudo nisse-choices set sunshine true 2>&1 | tail -1; sudo nisse-choices apply --id sunshine 2>&1 | tail -2", 180)
        perm = got("echo s=$(sudo firewall-cmd --permanent --zone=home --list-services)", "s") or ""
        check("on: the sunshine service is in the home zone, permanently", "sunshine" in perm.split(), perm)
        pub = got("echo s=$(sudo firewall-cmd --permanent --zone=public --list-services)", "s") or ""
        check("and not in the public zone", "sunshine" not in pub.split(), pub)
        en = got(f"echo e=$(ls /etc/systemd/user/graphical-session.target.wants/ 2>/dev/null | grep -c Sunshine)", "e")
        check("the user service is enabled for login (starts at login is the default)", en == "1", str(en))
        cf = got("echo c=$(grep -c -E '^(capture = kms|origin_web_ui_allowed = pc)$' /etc/nisse/sunshine.conf)", "c")
        check("the starter config says capture = kms and this PC only", cf == "2", str(cf))
        vm.sh("rm -rf ~/.config/sunshine; /usr/libexec/nisse/nisse-apply-sunshine-config; true", 60)
        seeded = got("echo s=$(grep -c 'capture = kms' ~/.config/sunshine/sunshine.conf)", "s")
        check("a user's first login copies the starter config", seeded == "1", str(seeded))

        # 4  started through its user service; reachable from home, not from public
        vm.sh(f"systemctl --user start {UNIT}; true", 90)
        time.sleep(50)
        check("started through its user service, Sunshine listens", (got(LISTEN, "listening") or "0") not in ("0", ""), str(got(LISTEN, "listening")))
        local = got("echo w=$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' https://127.0.0.1:47990/)", "w")
        check("the settings page answers on this PC", local in ("200", "301", "302", "307", "308", "401"), str(local))
        # a client on a private-address network: a namespace joined to this machine by a veth pair (the script is put in a file: a long
        # command line over the serial console is unreliable)
        commands = [
            "ip netns del peer 2>/dev/null",
            "ip netns add peer",
            "ip link add vh0 type veth peer name vp0",
            "ip link set vp0 netns peer",
            "ip addr add 192.168.77.1/24 dev vh0",
            "ip link set vh0 up",
            "ip netns exec peer ip addr add 192.168.77.2/24 dev vp0",
            "ip netns exec peer ip link set vp0 up",
            "ip netns exec peer ip link set lo up",
        ]
        script = chr(10).join(commands) + chr(10)
        vm.put("/tmp/netns.sh", script.encode())
        soft("sudo sh /tmp/netns.sh", 90)
        ns = got("echo n=$(sudo ip netns exec peer ip -4 addr show vp0 | grep -c 192.168.77.2)", "n")
        check("a private-address client network is set up", ns == "1", str(ns))
        reach = "sudo ip netns exec peer curl -s --max-time 6 -o /dev/null -w '%{http_code}' http://192.168.77.1:47989/serverinfo"
        soft("sudo firewall-cmd --zone=home --change-interface=vh0 2>&1 | tail -1", 60)
        home = got(f"echo r=$({reach})", "r")
        check("a client on a private network whose interface is in the home zone reaches the streaming port", home == "200", str(home))
        ui_home = got("echo r=$(sudo ip netns exec peer curl -sk --max-time 6 -o /dev/null -w '%{http_code}' https://192.168.77.1:47990/)", "r")
        check("and the settings page refuses it (this PC only)", ui_home not in ("200", "301", "302", "307", "308"), str(ui_home))
        soft("sudo firewall-cmd --zone=public --change-interface=vh0 2>&1 | tail -1", 60)
        pubr = got(f"echo r=$({reach})", "r")
        check("the same client in the public zone does not reach it", pubr in ("000", ""), str(pubr))

        # 5  off
        vm.sh(f"systemctl --user stop {UNIT}; true", 60)
        soft("sudo ip netns del peer", 60)
        soft("sudo nisse-choices set sunshine false 2>&1 | tail -1", 120)
        soft("sudo nisse-choices apply --id sunshine 2>&1 | tail -2", 180)
        perm = got("echo s=$(sudo firewall-cmd --permanent --zone=home --list-services)", "s") or ""
        check("off: the service leaves the home zone", "sunshine" not in perm.split(), perm)
        en = got("echo e=$(ls /etc/systemd/user/graphical-session.target.wants/ 2>/dev/null | grep -c Sunshine)", "e")
        check("off: the user service is no longer enabled", en == "0", str(en))
        gone = got("echo g=$(test -e /etc/nisse/sunshine.conf && echo no || echo yes)", "g")
        check("off: the starter config is gone", gone == "yes", str(gone))
        time.sleep(5)
        check("off: nothing listens", got(LISTEN, "listening") == "0", str(got(LISTEN, "listening")))
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "streaming-choice-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
        server.shutdown()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
