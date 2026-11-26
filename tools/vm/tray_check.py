# SPDX-License-Identifier: GPL-2.0-or-later
"""N-415b: the REAL panel's tray item in the live Plasma session, read by Plasma's own system tray.

Boots an ISO with livevm, puts the panel binary and the layer-shell runtime into the live user's home folder (the ISO under test may
predate the panel RPM), then for each of the six states starts the panel with --demo-tray STATE and checks, through the live session
bus, that Plasma's StatusNotifierWatcher took the item and that it carries the right icon, status and tooltip; a screenshot of each
state is taken for the review sheet. Then, with no forced state, the panel follows the real daemon (idle with it up, offline without),
and the item's own calls (a click, the menu entries) drive the sidebar through org.nisse.Panel.

Not covered here (hand checks at GATE 3): clicking and right-clicking the real tray icon with the mouse; the harness's synthetic clicks
do not land (docs/sidebar-spike.md).

Usage: python tools/vm/tray_check.py ISO OUTDIR(no spaces in the path) PANEL_BINARY LAYERSHELL_TGZ
       python tools/vm/tray_check.py ISO OUTDIR - -     (installed mode: the image's own autostarted panel; for the rebuilt ISO)
"""
import gzip
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

ENV = (
    "export LD_LIBRARY_PATH=$HOME/lsq/usr/lib64; "
    "export QT_PLUGIN_PATH=$HOME/lsq/usr/lib64/qt6/plugins; "
    "export QML_IMPORT_PATH=$HOME/lsq/usr/lib64/qt6/qml QML2_IMPORT_PATH=$HOME/lsq/usr/lib64/qt6/qml; "
    "export QT_QPA_PLATFORM=wayland"
)
ITEM = "org.kde.StatusNotifierItem"
WATCHER = "org.kde.StatusNotifierWatcher"
STATES = [  # (state to force, the icon, the Status, a piece of the tooltip)
    ("idle", "nisse-tray-idle-symbolic", "Active", "Ready"),
    ("busy", "nisse-tray-busy-symbolic", "Active", "Working"),
    ("needs-you:2", "nisse-tray-needs-you-symbolic", "NeedsAttention", "2 Approvals Waiting"),
    ("unread", "nisse-tray-unread-symbolic", "Active", "1 Conversation Finished"),
    ("paused", "nisse-tray-paused-symbolic", "Active", "AI Paused"),
    ("offline", "nisse-tray-offline-symbolic", "Active", "Daemon Not Reachable"),
]


def first_quoted(text):
    parts = text.split('"')
    return parts[1] if len(parts) > 2 else ""


def pid_of_panel(vm):
    out, _ = vm.sh("pgrep -x nisse-panel | head -1", 20)
    for line in out.splitlines():
        if line.strip().isdigit():
            return int(line.strip())
    return 0


def prop(vm, svc, name):
    out, _ = vm.sh(f"busctl --user get-property {svc} /StatusNotifierItem {ITEM} {name} 2>&1", 20)
    return out


def registered(vm):
    out, _ = vm.sh(f"busctl --user get-property {WATCHER} /StatusNotifierWatcher {WATCHER} RegisteredStatusNotifierItems 2>&1", 20)
    return out


def wait_for_item(vm, timeout=60):
    """The panel's service name once Plasma's watcher lists it, or None."""
    end = time.time() + timeout
    while time.time() < end:
        pid = pid_of_panel(vm)
        if pid:
            svc = f"org.kde.StatusNotifierItem-{pid}-1"
            if svc in registered(vm):
                return svc
        time.sleep(2)
    return None


def awake(vm):
    """The file transfer takes longer than the idle lock: unlock the session and report activity before a screenshot."""
    vm.sh("loginctl unlock-sessions; busctl --user call org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver "
          "SimulateUserActivity 2>&1; busctl --user call org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver "
          "SetActive b false 2>&1", 30)
    time.sleep(2)


def on_bus(vm, name):
    """Is `name` a name on the user bus (a running or activatable service shows once it is running)?"""
    out, _ = vm.sh(f"busctl --user --no-pager list 2>&1 | grep -c {name}", 30)
    nums = [ln.strip() for ln in out.splitlines() if ln.strip().isdigit()]
    return bool(nums) and int(nums[0]) > 0


def stop_panel(vm):
    vm.sh("kill $(pgrep -x nisse-panel) 2>/dev/null; sleep 2", 30)


def start_panel(vm, extra):
    stop_panel(vm)
    vm.bg(f"sh -c '{ENV}; /tmp/nisse-panel --background {extra} > /tmp/panel.log 2>&1'")


def panel_open(vm):
    out, _ = vm.sh("busctl --user call org.nisse.Panel /org/nisse/Panel org.nisse.Panel IsOpen 2>&1", 20)
    for line in out.splitlines():
        if line.strip() in ("b true", "b false"):
            return line.strip().endswith("true")
    return None


def forced_mode(vm, check, binary, tgz):
    """Runs the panel binary given on the command line with each state forced, then with the real daemon, then drives it."""
    # Files go over the serial console in small chunks (about a minute per 100 KB), so the binary travels gzipped; strip it first
    # (strip -o out in) to make it smaller still.
    t0 = time.time()
    vm.put("/tmp/nisse-panel.gz", gzip.compress(Path(binary).read_bytes(), 9))
    vm.put("/tmp/layershell.tgz", Path(tgz).read_bytes())
    vm.sh("gunzip -f /tmp/nisse-panel.gz && mkdir -p $HOME/lsq && tar xzf /tmp/layershell.tgz -C $HOME/lsq && chmod +x /tmp/nisse-panel", 60)
    print(f"files in the guest after {int(time.time() - t0)} s", flush=True)
    time.sleep(45)  # the session's Welcome Center and the tray settle first
    vm.shot("00-before.png")
    out_icons, _ = vm.sh("ls /usr/share/icons/hicolor/scalable/status/ | grep -c nisse-tray", 20)
    icons = [ln.strip() for ln in out_icons.splitlines() if ln.strip().isdigit()]
    check("the image has the six tray icons", icons[:1] == ["6"], str(icons))
    awake(vm)
    check("the system tray's watcher is on the bus", on_bus(vm, WATCHER))

    # 1. each forced state: taken by Plasma's watcher, right icon, status and tooltip
    for n, (state, icon, status, tip) in enumerate(STATES):
        start_panel(vm, f"--demo-tray {state}")
        svc = wait_for_item(vm)
        check(f"{state}: Plasma's watcher lists the item", svc is not None)
        if svc is None:
            continue
        time.sleep(4)  # let the tray draw it
        awake(vm)
        vm.shot(f"1{n}-{state.split(':')[0]}.png")
        check(f"{state}: icon {icon}", first_quoted(prop(vm, svc, "IconName")) == icon, prop(vm, svc, "IconName").strip())
        check(f"{state}: status {status}", first_quoted(prop(vm, svc, "Status")) == status)
        check(f"{state}: tooltip says '{tip}'", tip in prop(vm, svc, "ToolTip"), prop(vm, svc, "ToolTip").strip())

    # 2. no forced state: the panel follows the real daemon
    start_panel(vm, "")
    svc = wait_for_item(vm)
    check("real daemon mode: the item is listed", svc is not None)
    if svc:
        time.sleep(6)
        daemon_up = on_bus(vm, "org.nisse.Daemon1")
        want = "nisse-tray-idle-symbolic" if daemon_up else "nisse-tray-offline-symbolic"
        got = first_quoted(prop(vm, svc, "IconName"))
        check(f"real daemon mode: daemon {'up' if daemon_up else 'down'} -> {want}", got == want, got)
        awake(vm)
        vm.shot("20-real-daemon.png")
        if daemon_up:
            vm.sh("busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 EngageKillSwitch ss desktop check 2>&1", 30)
            time.sleep(3)
            check("real daemon mode: the kill switch turns it to paused", first_quoted(prop(vm, svc, "IconName")) == "nisse-tray-paused-symbolic")
            awake(vm)
            vm.shot("21-real-daemon-paused.png")
            vm.sh("busctl --user call org.nisse.Daemon1 /org/nisse/Daemon1 org.nisse.Daemon1 ReleaseKillSwitch s desktop 2>&1", 30)

        # 3. the item's own calls drive the sidebar (what a click and the menu do, minus the mouse)
        was = panel_open(vm)
        vm.sh(f"busctl --user call {svc} /StatusNotifierItem {ITEM} Activate ii 0 0 2>&1", 30)
        time.sleep(2)
        awake(vm)
        vm.shot("30-after-activate.png")
        now = panel_open(vm)
        check("a click on the item (Activate) toggles the sidebar", was is not None and now is not None and now != was, f"{was} -> {now}")
        vm.sh(f"busctl --user call {svc} /MenuBar com.canonical.dbusmenu Event isvu 1 clicked s '' 0 2>&1", 30)
        time.sleep(2)
        check("the Open entry toggles it back", panel_open(vm) == was, f"{panel_open(vm)}")

    # 4. the Approvals menu entry opens the sidebar on the approvals page (a forced state with something waiting)
    start_panel(vm, "--demo-tray needs-you:2")
    svc = wait_for_item(vm)
    if svc:
        time.sleep(3)
        vm.sh("busctl --user call org.nisse.Panel /org/nisse/Panel org.nisse.Panel Hide 2>&1", 20)
        time.sleep(2)
        vm.sh(f"busctl --user call {svc} /MenuBar com.canonical.dbusmenu Event isvu 2 clicked s '' 0 2>&1", 30)
        time.sleep(3)
        awake(vm)
        vm.shot("40-approvals-from-tray.png")
        check("the Approvals menu entry opens the sidebar", panel_open(vm) is True)
    else:
        check("the Approvals menu entry opens the sidebar", False, "no item")


def installed_mode(vm, check):
    """For the rebuilt ISO (queued at GATE 3): nothing is started by hand. The panel installed by the image starts at login
    (the XDG autostart) and Plasma's watcher must list its tray item."""
    time.sleep(90)  # the login autostart runs after the session is up
    awake(vm)
    svc = wait_for_item(vm, 120)
    check("installed: the autostarted panel's tray item is listed by Plasma's watcher", svc is not None)
    if svc is None:
        return
    icon = first_quoted(prop(vm, svc, "IconName"))
    check("installed: it shows one of the nisse tray icons", icon.startswith("nisse-tray-") and icon.endswith("-symbolic"), icon)
    exe, _ = vm.sh("readlink /proc/$(pgrep -x nisse-panel | head -1)/exe", 20)
    check("installed: the panel is the packaged /usr/bin/nisse-panel", "/usr/bin/nisse-panel" in exe, exe.strip()[-80:])
    awake(vm)
    vm.shot("50-installed.png")


def main(iso, out, binary, tgz):
    vm = livevm.Vm(iso, out)
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

    try:
        vm.login()
        vm.prepare_session()
        vm.true_colors()
        if binary == "-":
            installed_mode(vm, check)
        else:
            forced_mode(vm, check, binary, tgz)
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "tray-check.txt").write_text("\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
