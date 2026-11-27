# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508: the mail suite is shipped but wired to nothing, shown in a live Plasma session with the real KDE autostart.

Boots an ISO with livevm (the old ISO has the whole suite, so the "before" is real), puts the built nisse-defaults package in (over
the guest's network, the host is 10.0.2.2 to it), then:

    1  before: after login Calendar Reminders (kalendarac) runs and has started Akonadi (its server and agents)
    2  the package installs: the system kalendaracrc says Autostart=false and the autostart condition KDE evaluates is now false
    3  the autostart unit systemd generated from the real /etc/xdg/autostart entry is started again, the way Plasma starts it at login
       (its ExecCondition is kde-systemd-start-condition): it is skipped, and no kalendarac and no Akonadi process is running afterwards
    4  GnuPG Log Viewer, which cannot be dropped, has NoDisplay=true in its desktop file (the file trigger ran), and Kleopatra's own entry
       is untouched

The package is the one just built (`tools/rpm/build-rpm.sh nisse-defaults` in the build VM, pulled to out/pim/).

Usage: python tools/vm/pim_check.py ISO OUTDIR(no spaces in the path) RPM
"""
import functools
import re
import http.server
import socketserver
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

PORT = 8769
UNIT = "app-org.kde.kalendarac@autostart.service"
COUNT = "echo n=$(pgrep -c -x kalendarac) a=$(pgrep -c -f '^/usr/bin/akonadi')"


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def counts(text):
    """(kalendarac processes, Akonadi processes) from the line `n=.. a=..` of COUNT."""
    line = [l for l in text.splitlines() if l.startswith("n=")][-1]
    n, a = line.split()
    return int(n[2:]), int(a[2:])


def rc(text):
    """The exit code printed as `rc=N` by the condition command, None when it is not there."""
    found = re.findall(r"^rc=(\d+)", text, re.M)
    return int(found[-1]) if found else None


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
        time.sleep(60)

        text, _ = vm.run(COUNT, 30)
        n, a = counts(text)
        check("before: Calendar Reminders runs after login and has started Akonadi", n >= 1 and a >= 3, f"kalendarac {n}, akonadi processes {a}")
        text, _ = vm.run("kde-systemd-start-condition --condition kalendaracrc:General:Autostart:true; echo rc=$?", 30)
        check("before: the autostart condition is true", rc(text) == 0, f"rc={rc(text)}")

        text, _ = vm.run(f"curl -sf -o /tmp/def.rpm http://10.0.2.2:{PORT}/{rpm.name} && echo fetched $(wc -c < /tmp/def.rpm)", 120)
        check("the package reaches the guest", "fetched" in text, text.strip()[-40:])
        text, _ = vm.run("sudo rpm -Uvh --force --nodeps /tmp/def.rpm 2>&1 | tail -3; rpm -q nisse-defaults", 120)
        check("the package installs in the live session", rpm.stem.replace(".noarch", "") in text, text.strip()[-80:])

        text, _ = vm.run("cat /etc/xdg/kalendaracrc | grep -v '^#'", 30)
        check("the system kalendaracrc says Autostart=false", "Autostart=false" in text, text.strip()[-40:])
        text, _ = vm.run("kde-systemd-start-condition --condition kalendaracrc:General:Autostart:true; echo rc=$?", 30)
        check("after: the autostart condition is false", rc(text) not in (None, 0), f"rc={rc(text)}")

        # start the real generated unit again, as Plasma does at login, with Akonadi stopped first
        vm.sh("akonadictl stop >/dev/null 2>&1; systemctl --user stop " + UNIT + " 2>&1; pkill -x kalendarac; true", 90)
        time.sleep(10)
        vm.sh("systemctl --user daemon-reload; systemctl --user start " + UNIT + " 2>&1; true", 60)
        time.sleep(30)
        text, _ = vm.run(COUNT, 30)
        n, a = counts(text)
        check("after: starting the autostart unit is skipped: no Calendar Reminders, no Akonadi", n == 0 and a == 0, f"kalendarac {n}, akonadi processes {a}")
        text, _ = vm.run(f"echo state=$(systemctl --user is-active {UNIT}) result=$(systemctl --user show --value -p Result {UNIT})", 30)
        line = [l for l in text.splitlines() if l.startswith("state=")][-1]
        check("the unit did not run: its ExecCondition said no", "state=active" not in line and "result=exec-condition" in line, line)

        text, _ = vm.run("grep -c '^NoDisplay=true' /usr/share/applications/org.kde.kwatchgnupg.desktop; "
                         "grep -c '^NoDisplay' /usr/share/applications/org.kde.kleopatra.desktop; "
                         "grep -c '^Exec=kwatchgnupg' /usr/share/applications/org.kde.kwatchgnupg.desktop", 30)
        rows = [l for l in text.splitlines() if l.strip().isdigit()]
        check("GnuPG Log Viewer's entry is hidden and still starts the same program; Kleopatra's entry is untouched",
              rows[-3:] == ["1", "0", "1"], str(rows[-3:]))
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "pim-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
        server.shutdown()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
