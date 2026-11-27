# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508a: the default taskbar pins nisse panel, Files, Terminal and System Settings, and no browser, shown in a live Plasma session.

Boots an ISO with livevm (the old ISO's taskbar still pins the browser, so the "before" is real), puts the built nisse-lookandfeel
package in (over the guest's network, the host is 10.0.2.2 to it), then starts the panel the way a new user's first login does:
plasmashell with no panel configuration of its own runs the layout script of the current look.

    1  before: the live panel's pinned launchers include the browser, and a screenshot is taken
    2  the package installs and both looks' layout scripts no longer name a browser
    3  with the panel's configuration removed and plasmashell restarted, the pins read back from the new configuration are exactly
       nisse panel, the file manager, Konsole and System Settings, in that order
    4  a screenshot of the new taskbar is taken (looked at by hand: four icons, none a browser)

The package is the one just built (`tools/rpm/build-rpm.sh nisse-lookandfeel` in the build VM, pulled to out/pins/).

Usage: python tools/vm/pins_check.py ISO OUTDIR(no spaces in the path) RPM
"""
import functools
import http.server
import socketserver
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

PORT = 8770
APPLETSRC = "~/.config/plasma-org.kde.plasma.desktop-appletsrc"
WANT = ["applications:nisse-panel.desktop", "preferred://filemanager", "applications:org.kde.konsole.desktop",
        "applications:systemsettings.desktop"]
READ_PINS = f"echo pins=$(sed -n 's/^launchers=//p' {APPLETSRC} | tr -d ' ' | head -1)"


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def pins(text):
    """The pinned launchers from the line `pins=a,b,c` printed by READ_PINS (an empty list when there is none)."""
    found = [line for line in text.splitlines() if line.startswith("pins=")]
    if not found or not found[-1][5:]:
        return []
    return found[-1][5:].split(",")


def main(iso, out, rpm):
    rpm = Path(rpm).resolve()
    server = serve(rpm.parent)
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

        before = pins(vm.run(READ_PINS, 30)[0])
        check("before: the live panel pins the browser", any("browser" in p for p in before), ",".join(before))
        vm.shot("01-taskbar-before.png")

        text, _ = vm.run(f"curl -sf -o /tmp/laf.rpm http://10.0.2.2:{PORT}/{rpm.name} && echo fetched $(wc -c < /tmp/laf.rpm)", 120)
        check("the package reaches the guest", "fetched" in text, text.strip()[-40:])
        text, _ = vm.run("sudo rpm -Uvh --force --nodeps /tmp/laf.rpm 2>&1 | tail -3; rpm -q nisse-lookandfeel", 180)
        check("the package installs in the live session", rpm.stem.replace(".noarch", "") in text, text.strip()[-80:])
        text, _ = vm.run("echo n=$(cat /usr/share/plasma/look-and-feel/org.nisse.desktop*/contents/layouts/*.js | grep -c 'preferred://browser')", 30)
        found = [line for line in text.splitlines() if line.startswith("n=")]
        check("neither look's layout script pins a browser", bool(found) and found[-1] == "n=0", found[-1] if found else text.strip()[-40:])

        # a new user's first start: no panel configuration, so plasmashell runs the current look's layout script
        vm.sh("systemctl --user stop plasma-plasmashell.service; sleep 3; rm -f " + APPLETSRC + " ~/.config/plasmashellrc; "
              "systemctl --user start plasma-plasmashell.service; true", 120)
        end = time.time() + 120
        after = []
        while time.time() < end and not after:
            time.sleep(8)
            after = pins(vm.run(READ_PINS, 30)[0])
        time.sleep(25)  # the panel finishes drawing
        check("after: the panel built from the layout script pins exactly nisse panel, Files, Terminal, System Settings",
              after == WANT, ",".join(after))
        check("after: no pinned launcher is a browser", not any(w in p for p in after for w in ("browser", "firefox", "chromium")), ",".join(after))
        vm.shot("02-taskbar-after.png")
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "pins-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
        server.shutdown()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
