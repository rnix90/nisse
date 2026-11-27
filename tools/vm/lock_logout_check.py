# SPDX-License-Identifier: GPL-2.0-or-later
"""N-504: the lock screen and the logout screens of nisse, photographed in a live Plasma session.

Boots an ISO with livevm, puts the built nisse-lookandfeel package in (over the guest's network, the host is 10.0.2.2 to it), then:

    1  the screen is locked and photographed untouched (the wallpaper sharp, Plasma's clock and date), then after a key press
    2  the logout screen is opened in its three forms and photographed: with every option (the question and the round buttons), with
       the shut down countdown, and with the log out countdown

Each photo is judged by tools/vm/login_check.py (the lock screen like the login screen; the logout screen by its own rules). The package
is the one just built (`tools/rpm/build-rpm.sh nisse-lookandfeel` in the build VM, pulled to out/lock-e2e/).

Usage: python tools/vm/lock_logout_check.py ISO OUTDIR(no spaces in the path) RPM
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
import login_check  # noqa: E402

PORT = 8767
BUS = "busctl --user"
SAVER = "org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver"
PROMPT = "org.kde.LogoutPrompt /LogoutPrompt org.kde.LogoutPrompt"


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main(iso, out, rpm):
    rpm = Path(rpm).resolve()
    server = serve(rpm.parent)
    vm = livevm.Vm(iso, out)
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

    def judged(name, shot, judge):
        res = judge(login_check.Image.open(Path(out) / shot))
        check(name, res.ok, "; ".join(res.problems))

    try:
        vm.login()
        vm.prepare_session()
        vm.true_colors()
        time.sleep(60)

        text, _ = vm.run(f"curl -sf -o /tmp/laf.rpm http://10.0.2.2:{PORT}/{rpm.name} && echo fetched $(wc -c < /tmp/laf.rpm)", 120)
        check("the package reaches the guest", "fetched" in text, text.strip()[-40:])
        text, _ = vm.run("sudo rpm -Uvh --force --nodeps /tmp/laf.rpm 2>&1 | tail -3; rpm -q nisse-lookandfeel", 120)
        check("the package installs in the live session", rpm.stem.replace(".noarch", "") in text, text.strip()[-80:])
        text, _ = vm.run("grep -c wallpapers/nisse /etc/xdg/kscreenlockerrc; ls /usr/share/plasma/look-and-feel/org.nisse.desktop/contents/logout", 30)
        check("the lock default and the logout files are on the disk", "Logout.qml" in text and "timer.js" in text, text.strip()[-60:])

        # the live user has no password, and a key press would simply unlock the screen: give it one so the password box shows
        vm.run("echo 'liveuser:nisse' | sudo chpasswd", 30)

        # the lock screen, untouched and then awake
        vm.sh(f"{BUS} call {SAVER} Lock 2>&1; true", 30)
        time.sleep(14)
        vm.shot("10-lock-idle.png")
        judged("the idle lock screen shows the nisse wallpaper", "10-lock-idle.png", lambda img: login_check.check_login(img, awake=False))
        vm.monitor("sendkey shift")
        time.sleep(4)
        vm.shot("11-lock-awake.png")
        judged("the awake lock screen is still the nisse one", "11-lock-awake.png", lambda img: login_check.check_login(img, awake=True))
        for key in ("n", "i", "s", "s", "e", "ret"):      # type the password: the screen really unlocks
            vm.monitor(f"sendkey {key}")
        time.sleep(5)

        # the logout screen in its forms: every option, the shut down countdown, the log out countdown
        for shot, call, all_options, name in (("20-logout-all.png", "promptAll", True, "the logout screen with every option"),
                                              ("21-logout-shutdown.png", "promptShutDown", False, "the shut down countdown"),
                                              ("22-logout-logout.png", "promptLogout", False, "the log out countdown")):
            vm.sh(f"{BUS} call {PROMPT} {call} 2>&1; true", 30)
            time.sleep(9)
            vm.shot(shot)
            judged(name + " is nisse's", shot, lambda img, a=all_options: login_check.check_logout(img, all_options=a))
            vm.monitor("sendkey esc")
            time.sleep(4)
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "lock-logout-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
        server.shutdown()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
