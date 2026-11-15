# SPDX-License-Identifier: GPL-2.0-or-later
"""GATE 2 (N-219) checks on a built nisse ISO, run in a live session under QEMU (see livevm.py).

    python tools/vm/gate2.py --iso D:/nisse-build-vm/out/nisse-live.iso --tools out/gate2/tools --out out/gate2

What it proves on the image itself (not on the build machine):
  * the AI core's packages and files are installed (daemon, panel, hooks, schema, pw-dump);
  * the image's own daemon (fake agent) answers sessions, approvals, the kill switch and device pairing, using the
    loopback device client and the protocol test binary copied in over the guest's network (tools folder);
  * the machine-wide audit hook writes a `source: terminal` record and the daemon's hook a `source: daemon` one;
  * the panel (the image's own nisse-panel) draws each page: chat, approvals, audit log, settings, as screenshots.
What it cannot prove: a real `claude` run (needs Bert's login). That stays a desk step.
Exit 0 when every check passed.
"""
import argparse
import functools
import http.server
import json
import re
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import livevm  # noqa: E402

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""), flush=True)


def serve(folder, port):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(folder))
    handler.log_message = lambda *a, **k: None
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


GUEST_SETUP = r"""
set -u
mkdir -p ~/g2 && cd ~/g2
for f in device_probe schema devices_inner.sh dbus gate2_seed.sh; do
  curl -fsS -o $f http://10.0.2.2:__PORT__/$f || echo "missing $f"
done
chmod +x device_probe schema dbus
ls -la ~/g2
"""

AUDIT_HOOK_CHECK = r"""
(
cd ~/g2
export NISSE_AUDIT_LOG=$HOME/g2/hook-audit.jsonl
rm -f "$NISSE_AUDIT_LOG"
# what claude sends a hook for one tool call, once as a terminal session (no NISSE_SESSION) ...
pre='{"session_id":"term-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
post='{"session_id":"term-1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"output":"x"}}'
echo "$pre" | env -u NISSE_SESSION /usr/bin/nisse-audit-hook --managed
echo "$post" | env -u NISSE_SESSION /usr/bin/nisse-audit-hook --managed
echo "TERMINAL=$(grep -c '"source":"terminal"' "$NISSE_AUDIT_LOG")"
# ... and once as a panel session (the daemon sets NISSE_SESSION and passes its own hook; the machine-wide one stands down)
rm -f "$NISSE_AUDIT_LOG"
export NISSE_SESSION=s-gate
echo "$post" | /usr/bin/nisse-audit-hook --managed
echo "$post" | /usr/bin/nisse-audit-hook
echo "DAEMON=$(grep -c '"source":"daemon"' "$NISSE_AUDIT_LOG") TERMINAL_IN_PANEL=$(grep -c '"source":"terminal"' "$NISSE_AUDIT_LOG")"
)
"""


def sh(vm, cmd, timeout=90):
    text, code = vm.sh(cmd, timeout)
    return text, code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso", required=True)
    ap.add_argument("--tools", type=Path, required=True, help="folder with device_probe, schema, dbus (test binaries) and devices_inner.sh")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    # QEMU writes the screenshots, and it cannot write to the T: share, so they go to a local folder first.
    shots = Path("D:/nisse-build-vm/out/gate2-shots")
    shots.mkdir(parents=True, exist_ok=True)
    port = 18765
    import shutil
    shutil.copyfile(Path(__file__).resolve().parent / "gate2_seed.sh", a.tools / "gate2_seed.sh")
    srv = serve(a.tools, port)
    vm = livevm.Vm(a.iso, shots)
    try:
        vm.login()
        vm.prepare_session()
        # ---- installed pieces
        text, code = sh(vm, "rpm -q nisse-daemon nisse-panel pipewire-utils; echo rc=$?")
        check("packages installed", "nisse-daemon-" in text and "nisse-panel-" in text and "pipewire-utils-" in text, text[-300:])
        text, code = sh(vm, "ls /usr/bin/nisse-daemon /usr/bin/nisse-panel /usr/bin/nisse-audit-hook /usr/bin/nisse-guard-hook /usr/bin/pw-dump "
                            "/usr/share/nisse/daemon-protocol.schema.json /etc/claude-code/managed-settings.json >/dev/null; echo rc=$?")
        check("AI core files present", "rc=0" in text, text[-300:])
        # ---- tools from the host
        text, _ = sh(vm, GUEST_SETUP.replace("__PORT__", str(port)), 240)
        check("test tools copied in", all(re.search(r"\d+ \w+ +\d+ [\d:]+ " + n + r"\s*$", text, re.M) for n in ("device_probe", "schema", "dbus", "devices_inner.sh", "gate2_seed.sh")), text[-400:])
        # ---- protocol tests in the image
        text, code = sh(vm, "cd ~/g2 && NISSE_SCHEMA=/usr/share/nisse/daemon-protocol.schema.json ./schema 2>&1 | tail -4", 120)
        check("protocol crate tests pass in the image", " 0 failed" in text and "test result: ok" in text, text[-400:])
        text, code = sh(vm, "cd ~/g2 && ./dbus device_calls 2>&1 | tail -4", 240)
        check("device pairing tests pass in the image", "test result: ok" in text and " 0 failed" in text, text[-400:])
        # ---- the image's daemon + loopback device
        text, code = sh(vm, "cd ~/g2 && export NISSE_FAKE_RUNNER=1 NISSE_AUDIT_LOG=$HOME/g2/audit.jsonl NISSE_STATE=$HOME/g2/sessions.json "
                            "NISSE_CONFIG=$HOME/g2/none.toml && rm -f audit.jsonl sessions.json && (nohup /usr/bin/nisse-daemon >daemon.log 2>&1 &) ; sleep 3; "
                            "busctl --user introspect org.nisse.Daemon1 /org/nisse/Daemon1 | grep -c DeviceCall", 60)
        check("the image's daemon is on the bus with DeviceCall", re.search(r"^1\s*$", text, re.M) is not None, text[-300:])
        text, code = sh(vm, "cd ~/g2 && bash devices_inner.sh /usr/bin/nisse-daemon /usr/bin/nisse-panel $HOME/g2 $HOME/g2/device_probe 2>&1 | tail -3", 180)
        check("device pairing end to end on the image", "devices e2e ok" in text, text[-400:])
        # the e2e left the kill switch on (its device engaged it): a restarted daemon on the same state must still have it on
        sh(vm, "pkill -x nisse-daemon; sleep 1; true", 30)
        text, _ = sh(vm, "cd ~/g2 && export NISSE_FAKE_RUNNER=1 NISSE_AUDIT_LOG=$HOME/g2/audit2.jsonl NISSE_STATE=$HOME/g2/sessions-n221.json "
                         "NISSE_CONFIG=$HOME/g2/none.toml && (nohup /usr/bin/nisse-daemon >daemon2.log 2>&1 &); sleep 3; "
                         "busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 GetKillSwitch", 60)
        check("the kill switch survives a daemon restart in the image", "engaged" in text and "true" in text, text[-300:])
        sh(vm, "pkill -x nisse-daemon; sleep 1; true", 30)
        # ---- audit hook: terminal and panel records
        text, code = sh(vm, AUDIT_HOOK_CHECK, 60)
        check("a terminal session leaves source: terminal records", "TERMINAL=2" in text, text[-300:])
        check("a panel session leaves exactly one source: daemon record per tool call and no terminal one",
              "DAEMON=1 TERMINAL_IN_PANEL=0" in text, text[-300:])
        # ---- the panel, page by page, with some content (a fresh state folder: kill switch off, nothing paired)
        sh(vm, "mkdir -p ~/g2/ui && cd ~/g2/ui && export NISSE_FAKE_RUNNER=1 NISSE_AUDIT_LOG=$HOME/g2/ui/audit.jsonl NISSE_STATE=$HOME/g2/ui/sessions.json "
               "NISSE_CONFIG=$HOME/g2/ui/none.toml && rm -f * && (nohup /usr/bin/nisse-daemon >daemon.log 2>&1 &); sleep 3; true", 60)
        text, _ = sh(vm, "bash ~/g2/gate2_seed.sh 2>&1 | tail -3", 120)
        check("a session, two held approvals and a paired device on the image", re.search(r"SEED sid=\S+ paired=1", text) is not None, text[-400:])
        # A session counts as restored (its transcript is replayed when the panel starts) once Claude Code has started it, and
        # the fake agent never does that; mark it the way a real first turn would, then restart the daemon on the same state.
        sh(vm, "sid=$(cat ~/g2/ui/sid); busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 SetKeepMode ss $sid always; "
               "pkill -x nisse-daemon; sleep 1; sed -i 's/\"started\":false/\"started\":true/' ~/g2/ui/sessions.json; "
               "(nohup /usr/bin/nisse-daemon >>~/g2/ui/daemon.log 2>&1 &); sleep 3; bash ~/g2/gate2_seed.sh approvals 2>&1 | tail -1", 90)
        pages = {"chat": 0, "approvals": 1, "audit": 2, "settings": 3}
        for name, n in pages.items():
            sh(vm, "pkill -x nisse-panel; sleep 1; true", 30)
            vm.bg(f"/usr/bin/nisse-panel --page {n}")
            time.sleep(10)
            path = vm.shot(f"panel_{name}.png")
            check(f"panel page '{name}' drawn", path.is_file() and path.stat().st_size > 20000, str(path))
        # the kill switch bar, from the daemon, on the chat page
        sh(vm, "pkill -x nisse-panel; sleep 1; busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 EngageKillSwitch ss desktop 'gate screenshot'; true", 30)
        vm.bg("/usr/bin/nisse-panel --page 0")
        time.sleep(10)
        path = vm.shot("panel_killswitch.png")
        check("panel shows the kill switch bar", path.is_file() and path.stat().st_size > 20000, str(path))
        sh(vm, "pkill -x nisse-panel; true", 30)
        import hashlib
        digests = {n: hashlib.sha256((shots / f"panel_{n}.png").read_bytes()).hexdigest() for n in ("chat", "approvals", "audit", "settings", "killswitch")
                   if (shots / f"panel_{n}.png").is_file()}
        check("each panel page looks different (--page works on the image)", len(set(digests.values())) == 5, str(sorted(digests)))
        text, _ = sh(vm, "echo LINES=$(grep -c . ~/g2/ui/audit.jsonl)", 30)
        mm = re.search(r"LINES=(\d+)", text)
        check("the audit log has records", bool(mm) and int(mm.group(1)) >= 3, text[-200:])
    finally:
        if not a.keep:
            vm.close()
        srv.shutdown()
    import shutil
    (a.out / "shots").mkdir(exist_ok=True)
    for f in shots.glob("panel_*.png"):
        shutil.copyfile(f, a.out / "shots" / f.name)
    bad = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(bad)} of {len(RESULTS)} checks pass")
    (a.out / "gate2-results.json").write_text(json.dumps(RESULTS, indent=1))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
