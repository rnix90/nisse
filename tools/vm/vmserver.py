#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Keep an installed nisse disk running in QEMU and drive it from separate commands (ledger N-307).

The install harness (install_disk.py) boots a disk, checks it and stops. Boot and rollback work needs a machine that stays up
across many steps and can be rebooted, power-cycled and watched at the boot menu. This tool starts one on a disposable qcow2
overlay (the installed disk is never written) and answers one-line JSON requests on a local port.

    python tools/vm/vmserver.py serve --disk out/install/run/target.qcow2 --vars out/install/run/install/OVMF_VARS.fd --work DIR
    python tools/vm/vmserver.py call PORT run "uname -r"
    python tools/vm/vmserver.py call PORT put /tmp/file local-file   (copy a file into the guest, through the serial console)
    python tools/vm/vmserver.py call PORT send "text"          (raw bytes to the serial console; \\n is a newline)
    python tools/vm/vmserver.py call PORT key up               (a key through the QEMU monitor: up, down, ret, e, esc ...)
    python tools/vm/vmserver.py call PORT expect "login:" 300  (wait for text on the serial console)
    python tools/vm/vmserver.py call PORT shot name.png        (a screenshot of the machine's screen)
    python tools/vm/vmserver.py call PORT serial               (what the serial console has printed since the last look)
    python tools/vm/vmserver.py call PORT powercycle           (stop the machine and start it again on the same disk, like pulling the plug)
    python tools/vm/vmserver.py call PORT quit

The disk's login is in harness-login.txt beside it. The serial console is the same one the harness uses.
"""
import argparse
import json
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import livevm  # noqa: E402

QEMU_IMG = livevm.QEMU_DIR / "qemu-img.exe"
DRIVE_REMOTE = 4   # GetDriveType: a network drive


def _windows_drive_type(root):
    import ctypes
    return ctypes.windll.kernel32.GetDriveTypeW(root)


def is_network_path(path, drive_type=None):
    """True when PATH is on a network drive: a UNC path, or a drive letter that is mapped to a share (the T: drive the repo is on).

    The overlay of a running machine is written all the time; on a share the machine crawls (systemd gave up starting, ledger
    N-310), so the work folder must be a local disk."""
    p = str(path)
    if p.startswith("\\\\") or p.startswith("//"):
        return True
    if len(p) >= 2 and p[1] == ":":
        try:
            return (drive_type or _windows_drive_type)(p[:2] + "\\") == DRIVE_REMOTE
        except (AttributeError, OSError):   # not Windows: there is no drive to ask about
            return False
    return False


def make_overlay(base, overlay):
    overlay = Path(overlay)
    if overlay.exists():
        overlay.unlink()
    subprocess.run([str(QEMU_IMG), "create", "-f", "qcow2", "-F", "qcow2", "-b", str(Path(base).resolve()), str(overlay)],
                   check=True, capture_output=True)
    return overlay


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Machine:
    """The running QEMU. A guest reboot and QEMU's own system_reset both leave this WHPX setup hung at a blank screen, so
    a reboot of any kind is a power-cycle: stop the process and start a new one on the same disk and firmware variables
    (what the boot entries and the grub environment live on), which is also what a hung machine and its owner would do."""

    def __init__(self, work, overlay, mem):
        self.work, self.overlay, self.mem = work, overlay, mem
        self.vm = None
        self.start()

    def start(self):
        self.vm = livevm.Vm(None, self.work, mem=self.mem, disks=[self.overlay], fresh_vars=False)

    def powercycle(self):
        self.vm.close()
        time.sleep(2)
        self.start()


def handler_for(machine, work):
    lock = threading.Lock()

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            line = self.rfile.readline()
            if not line:
                return
            req = json.loads(line)
            try:
                with lock:
                    reply = self.dispatch(req)
            except Exception as e:   # a failed step is reported to the caller, the machine keeps running
                reply = {"ok": False, "error": f"{type(e).__name__}: {e}"}
            self.wfile.write((json.dumps(reply) + "\n").encode())

        def dispatch(self, req):
            op, args = req["op"], req.get("args", [])
            vm = machine.vm
            if op == "run":
                out, code = vm.run(args[0], int(args[1]) if len(args) > 1 else 120)
                return {"ok": True, "code": code, "out": out}
            if op == "put":
                vm.put(args[0], Path(args[1]).read_bytes())
                return {"ok": True}
            if op == "send":
                vm.send(args[0].replace("\\n", "\n"))
                return {"ok": True}
            if op == "key":
                vm.monitor("sendkey " + args[0])
                return {"ok": True}
            if op == "expect":
                seen = vm.expect(args[0], int(args[1]) if len(args) > 1 else 300)
                return {"ok": True, "out": seen[-2000:]}
            if op == "shot":
                return {"ok": True, "path": str(vm.shot(args[0]))}
            if op == "serial":
                with vm.lock:
                    text, vm.buf = vm.buf, ""
                return {"ok": True, "out": livevm.clean(text)}
            if op == "powercycle":
                machine.powercycle()
                return {"ok": True}
            if op == "quit":
                threading.Thread(target=lambda: (time.sleep(0.5), vm.close(), __import__("os")._exit(0))).start()
                return {"ok": True}
            return {"ok": False, "error": f"unknown op {op}"}

    return Handler


def serve(args):
    if is_network_path(args.work):
        sys.exit(f"vmserver: the work folder {args.work} is on a network drive. The machine writes its overlay all the time and "
                 "crawls there (systemd gives up starting); use a local folder, for example one under the temp directory.")
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    overlay = work / "overlay.qcow2"
    vars_copy = work / "OVMF_VARS.fd"
    if not (args.resume and overlay.exists() and vars_copy.exists()):   # --resume keeps the last session's changes
        overlay = make_overlay(args.disk, overlay)
        vars_copy.write_bytes(Path(args.vars).read_bytes())
    machine = Machine(work, overlay, args.mem)
    srv = Server(("127.0.0.1", args.port), handler_for(machine, work))
    print(f"vm up; commands on port {args.port}", flush=True)
    srv.serve_forever()


def call(port, op, args):
    with socket.create_connection(("127.0.0.1", int(port)), timeout=3600) as s:
        s.sendall((json.dumps({"op": op, "args": args}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    reply = json.loads(data)
    if not reply.get("ok"):
        print("ERROR:", reply.get("error"))
        return 1
    if "out" in reply:
        print(reply["out"].encode("ascii", "replace").decode("ascii"))
    if "path" in reply:
        print(reply["path"])
    return reply.get("code", 0)


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--disk", required=True)
    s.add_argument("--vars", required=True)
    s.add_argument("--work", required=True)
    s.add_argument("--port", type=int, default=24680)
    s.add_argument("--mem", type=int, default=4096)
    s.add_argument("--resume", action="store_true", help="keep the overlay and firmware variables of the last session")
    c = sub.add_parser("call")
    c.add_argument("port")
    c.add_argument("op")
    c.add_argument("args", nargs="*")
    a = ap.parse_args(argv)
    if a.cmd == "serve":
        serve(a)
        return 0
    return call(a.port, a.op, a.args)


if __name__ == "__main__":
    sys.exit(main())
