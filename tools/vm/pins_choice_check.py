# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508c: the taskbar pins choice end to end, in a live Plasma session, with the real engine, the real scripts and the real panel.

Boots an ISO with livevm, puts the two built packages in (nisse-choices with its new `multi` kind, nisse-lookandfeel with the manifest and
the first-login step) over the guest's network (the host is 10.0.2.2 to it), starts the panel from the new layout the way a new user's first
login does, then:

    1  the live session keeps the defaults: with nothing chosen there is no /etc/nisse/taskbar-pins, the first-login step changes nothing,
       and the panel pins exactly the layout's four
    2  the choice is made with the real engine (`nisse-choices set` and `apply`): /etc/nisse/taskbar-pins holds the list, readable by all
    3  the autostart entry is known to systemd's XDG autostart generator (the step runs at the start of a Plasma session)
    4  the first-login step sets the panel: the pins read back are exactly the chosen list (an unticked default gone, a ticked extra in), once
    5  a second run does nothing; a panel the user has changed since is left alone

Usage: python tools/vm/pins_choice_check.py ISO OUTDIR(no spaces in the path) LOOKANDFEEL_RPM CHOICES_RPM
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

PORT = 8772
APPLETSRC = "~/.config/plasma-org.kde.plasma.desktop-appletsrc"
READ = f"echo pins=$(sed -n 's/^launchers=//p' {APPLETSRC} | tr -d ' ' | head -1)"
DEFAULTS = ["applications:nisse-panel.desktop", "preferred://filemanager", "applications:org.kde.konsole.desktop", "applications:systemsettings.desktop"]
# Konsole unticked, Discover ticked: a default out, an extra in
CHOSEN = ["applications:nisse-panel.desktop", "preferred://filemanager", "applications:org.kde.discover.desktop", "applications:systemsettings.desktop"]
CUSTOM = ["applications:nisse-panel.desktop"]
SET_CUSTOM = ('var d=0;panelIds.forEach(function(id){panelById(id).widgets("org.kde.plasma.icontasks").forEach(function(w){'
              'w.currentConfigGroup=["General"];w.writeConfig("launchers",["applications:nisse-panel.desktop"]);w.reloadConfig();d++})});print(d)')


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def value(text, key):
    found = re.findall(rf"^{re.escape(key)}=(.*)$", text, re.M)
    return found[-1].strip() if found else None


def pins(vm):
    return (value(vm.run(READ, 30)[0], "pins") or "").split(",")


def main(iso, out, laf, choices):
    laf, choices = Path(laf).resolve(), Path(choices).resolve()
    if laf.parent != choices.parent:
        sys.exit("put both packages in one folder")
    server = serve(laf.parent)
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

        for i, rpm in enumerate((laf, choices)):
            text, _ = vm.run(f"curl -sf -o /tmp/p{i}.rpm http://10.0.2.2:{PORT}/{rpm.name} && echo fetched=$(wc -c < /tmp/p{i}.rpm)", 180)
            check(f"{rpm.name[:20]}: the package reaches the guest", value(text, "fetched") not in (None, "0"), str(value(text, "fetched")))
        text, _ = vm.run("sudo rpm -Uvh --nodeps --force /tmp/p0.rpm /tmp/p1.rpm 2>&1 | tail -3; rpm -q nisse-lookandfeel nisse-choices", 300)
        check("the packages install", "nisse-lookandfeel-0.2-10" in text and "nisse-choices-0.1-2" in text, text.strip()[-100:])

        # a new user's first start: no panel configuration, so plasmashell runs the new layout script
        vm.sh("systemctl --user stop plasma-plasmashell.service; sleep 3; rm -f " + APPLETSRC + " ~/.config/plasmashellrc ~/.local/state/nisse/taskbar-pins-applied; "
              "systemctl --user start plasma-plasmashell.service; true", 120)
        end = time.time() + 120
        start = []
        while time.time() < end and start in ([], [""]):
            time.sleep(8)
            start = pins(vm)
        time.sleep(25)
        check("the fresh panel pins the layout's four", start == DEFAULTS, ",".join(start))

        # 1  the live session keeps the defaults
        text, _ = vm.run("echo file=$(test -e /etc/nisse/taskbar-pins && echo yes || echo no)", 30)
        check("with nothing chosen there is no pins file", value(text, "file") == "no", str(value(text, "file")))
        vm.sh("/usr/libexec/nisse/nisse-apply-taskbar-pins; true", 120)
        time.sleep(20)
        now = pins(vm)
        text, _ = vm.run("echo marker=$(test -e ~/.local/state/nisse/taskbar-pins-applied && echo yes || echo no)", 30)
        check("the first-login step changes nothing without a pins file", now == DEFAULTS and value(text, "marker") == "no", f"{','.join(now)} marker={value(text, 'marker')}")

        # 2  the choice, made with the real engine
        text, _ = vm.run("sudo nisse-choices list --json --stage firstboot | grep -c taskbar-pins", 60)
        check("the engine lists the taskbar pins choice", (re.findall(r"^\d+$", text, re.M) or ["0"])[-1] != "0", text.strip()[-30:])
        text, _ = vm.run("sudo nisse-choices set taskbar-pins " + ",".join(CHOSEN) + " 2>&1 | tail -2; echo setrc=$?", 60)
        check("the engine takes the answer", value(text, "setrc") == "0", text.strip()[-80:])
        text, _ = vm.run("sudo nisse-choices apply --id taskbar-pins 2>&1 | tail -3; echo applyrc=$?", 120)
        check("the engine applies it", value(text, "applyrc") == "0" and "failed" not in text.lower(), text.strip()[-100:])
        text, _ = vm.run("echo lines=$(paste -sd, /etc/nisse/taskbar-pins) mode=$(stat -c %a /etc/nisse/taskbar-pins)", 30)
        check("/etc/nisse/taskbar-pins holds the list, readable by every user", value(text, "lines") is not None and
              (value(text, "lines") or "").split(" mode=")[0] == ",".join(CHOSEN) and (value(text, "lines") or "").endswith("mode=644"), str(value(text, "lines")))

        # 3  the autostart entry
        vm.sh("systemctl --user daemon-reload; true", 60)
        text, _ = vm.run("echo gen=$(ls /run/user/$(id -u)/systemd/generator.late/ 2>/dev/null | grep -c taskbar)", 30)
        check("systemd's XDG autostart generator knows the first-login step", (value(text, "gen") or "0") != "0", str(value(text, "gen")))

        # 4  the first-login step sets the panel
        vm.sh("/usr/libexec/nisse/nisse-apply-taskbar-pins; true", 120)
        time.sleep(15)
        vm.run("sync", 30)
        time.sleep(30)
        after = pins(vm)
        check("the pins are now exactly the chosen list (Konsole out, Discover in)", after == CHOSEN, ",".join(after))
        text, _ = vm.run("echo marker=$(test -e ~/.local/state/nisse/taskbar-pins-applied && echo yes || echo no)", 30)
        check("it is remembered for this user", value(text, "marker") == "yes", str(value(text, "marker")))
        vm.shot("pins-choice-after.png")

        # 5  once only, and a changed panel is left alone
        vm.sh("rm -f /tmp/mark; /usr/libexec/nisse/nisse-apply-taskbar-pins; true", 120)
        time.sleep(10)
        check("a second run changes nothing", pins(vm) == CHOSEN, ",".join(pins(vm)))
        vm.sh("busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s '" + SET_CUSTOM + "' >/dev/null 2>&1; "
              "rm -f ~/.local/state/nisse/taskbar-pins-applied; true", 90)
        time.sleep(15)
        vm.run("sync", 30)
        time.sleep(25)
        changed = pins(vm)
        vm.sh("/usr/libexec/nisse/nisse-apply-taskbar-pins; true", 120)
        time.sleep(25)
        kept = pins(vm)
        check("a panel the user changed is not touched", changed == CUSTOM and kept == CUSTOM, f"changed={','.join(changed)} kept={','.join(kept)}")
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "pins-choice-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
        server.shutdown()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
