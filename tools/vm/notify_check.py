# SPDX-License-Identifier: GPL-2.0-or-later
"""GATE 3 (N-313): the image's own panel and notifications in the live Plasma session, with screenshots for the review sheet.

Boots an ISO with livevm and checks, with nothing started by hand (the panel is the one the image autostarts):

    1  Plasma's notification service says it supports `actions` (the countdown notice of the update watchdog, N-310, has a Keep button)
    2  a notice with an action button and `--wait` is shown, reaches the service, and ends when its time runs out without an answer
    3  the sidebar opens through the panel's own service (org.nisse.Panel Show) and a screenshot is taken of it in place

A real click on the button, and the sounds, are hand checks (docs/gate3-hand-checks.md): synthetic clicks do not land here.

Usage: python tools/vm/notify_check.py ISO OUTDIR(no spaces in the path)
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

BUS = "busctl --user"
NOTIFY = "org.freedesktop.Notifications"


def awake(vm):
    vm.sh("loginctl unlock-sessions; busctl --user call org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver "
          "SimulateUserActivity 2>&1; true", 20)


def main(iso, out):
    vm = livevm.Vm(iso, out)
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

    try:
        vm.login()
        vm.prepare_session()
        vm.true_colors()
        time.sleep(90)   # the login autostart of the panel runs after the session is up
        awake(vm)

        text, _ = vm.sh(f"{BUS} call {NOTIFY} /org/freedesktop/Notifications {NOTIFY} GetCapabilities 2>&1", 30)
        check("the notification service lists `actions` (the Keep button of the watchdog's notice needs it)", '"actions"' in text, text.strip()[-90:])
        check("and `body` and `persistence`", '"body"' in text and '"persistence"' in text, "")

        # a notice like the watchdog's: critical, an action, --wait; it ends by itself when its time is up
        vm.bg("sh -c 'notify-send --app-name=nisse --urgency=critical --expire-time=25000 \"--action=cancel=Keep the update\" --wait -- "
              "\"nisse is undoing the last update\" \"The health check failed after the update. Unless you press Keep the update, nisse goes "
              "back to how the system was before it in 60 seconds and restarts. Your files are not changed.\" > /tmp/notice.out 2>&1; "
              "echo done > /tmp/notice.done'")
        time.sleep(6)
        awake(vm)
        vm.shot("60-countdown-notice.png")
        shown, _ = vm.sh(f"{BUS} --no-pager monitor {NOTIFY} --timeout=1 2>&1 | head -3; true", 20)
        running, _ = vm.sh("pgrep -x notify-send | head -1", 20)
        # the console echoes the command around the answer: look for a line that is only the process id
        pid = next((ln.strip() for ln in running.splitlines() if ln.strip().isdigit()), "")
        check("the notice was delivered and notify-send waits for the answer", pid != "", pid)
        end = time.time() + 120
        done = False
        while time.time() < end:
            o, _ = vm.sh("test -f /tmp/notice.done && echo yes || echo no", 20)
            if "yes" in o:
                done = True
                break
            time.sleep(5)
        answer, _ = vm.sh("cat /tmp/notice.out 2>&1", 20)
        check("with no click it ends by itself, answering nothing", done and "cancel" not in answer, answer.strip()[-60:])

        vm.sh(f"{BUS} call org.nisse.Panel /org/nisse/Panel org.nisse.Panel Show 2>&1", 20)
        time.sleep(4)
        awake(vm)
        opened, _ = vm.sh(f"{BUS} call org.nisse.Panel /org/nisse/Panel org.nisse.Panel IsOpen 2>&1", 20)
        check("the sidebar opens through the panel's own service", "b true" in opened, opened.strip()[-30:])
        vm.shot("61-sidebar-open.png")
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "notify-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
