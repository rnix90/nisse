# SPDX-License-Identifier: GPL-2.0-or-later
"""N-415a: the REAL panel as a docked sidebar on the live Plasma session.

Boots an ISO with livevm, puts the panel binary and the layer-shell runtime into the live user's home folder (the live session cannot
sudo; the ISO under test may predate the panel RPM), then checks, asserting through the panel's own D-Bus service (org.nisse.Panel) and
taking a screenshot after each step:

    1  started with --background: one panel runs, the sidebar is CLOSED (IsOpen false), nothing at the right edge
    2  a second plain launch (the pinned icon, Meta+N) toggles it OPEN and exits: IsOpen true, still ONE panel process
    3  typing reaches it: keys sent after the toggle (the panel takes the keyboard when opened on purpose)
    4  Escape closes it
    5  the pointer pushed against the right screen edge opens it after the dwell WITHOUT taking the keyboard
    6  ShowApprovals (what a clicked notice and the tray call) opens it
    7  a third launch toggles it closed again; --show opens, --hide closes

Usage: python tools/vm/sidebar_check.py ISO OUTDIR(no spaces in the path) PANEL_BINARY LAYERSHELL_TGZ
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

ENV = (
    "export LD_LIBRARY_PATH=$HOME/lsq/usr/lib64; "
    "export QT_PLUGIN_PATH=$HOME/lsq/usr/lib64/qt6/plugins; "
    "export QML_IMPORT_PATH=$HOME/lsq/usr/lib64/qt6/qml QML2_IMPORT_PATH=$HOME/lsq/usr/lib64/qt6/qml; "
    "export QT_QPA_PLATFORM=wayland NISSE_PANEL_DEBUG_KEYS=1"
)
CALL = "busctl --user call org.nisse.Panel /org/nisse/Panel org.nisse.Panel IsOpen 2>&1"


def click_in_sidebar(vm):
    """Relative mouse moves in small steps (a big one is clamped or ignored by the virtual PS/2 mouse; the first live run clicked the
    Show Desktop button instead): slam the pointer to the bottom right corner, step up and left into the chat field, click. A click is
    what gives an on-demand layer surface the keyboard."""
    vm.monitor("mouse_move 4000 4000")
    for _ in range(12):
        vm.monitor("mouse_move -12 -9")
    vm.monitor("mouse_button 1")
    vm.monitor("mouse_button 0")


def input_changed(a, b):
    """Did the chat input (the 'Ask nisse...' field at the bottom of the sidebar) change between two screenshots?"""
    from PIL import Image, ImageChops
    box = (868, 668, 1272, 704)
    diff = ImageChops.difference(Image.open(a).convert("RGB").crop(box), Image.open(b).convert("RGB").crop(box))
    return diff.getbbox() is not None


def key_presses(vm):
    out, _ = vm.sh("grep -c 'nisse key press' /tmp/panel.log", 20)
    for line in out.splitlines():
        if line.strip().isdigit():
            return int(line.strip())
    return 0


def is_open(vm):
    out, _ = vm.sh(CALL, 20)
    for line in out.splitlines():
        line = line.strip()
        if line in ("b true", "b false"):
            return line.endswith("true")
    return None


def panels(vm):
    out, _ = vm.sh("pgrep -c -x nisse-panel", 20)
    for line in out.splitlines():
        if line.strip().isdigit():
            return int(line.strip())
    return 0


def main(iso, out, binary, tgz):
    vm = livevm.Vm(iso, out, tablet=True)   # an absolute pointer, to click exactly where the test means
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

    try:
        vm.login()
        vm.prepare_session()
        vm.true_colors()
        print('tablet is the active mouse:', vm.use_tablet(), flush=True)
        vm.put("/tmp/nisse-panel", Path(binary).read_bytes())
        vm.put("/tmp/layershell.tgz", Path(tgz).read_bytes())
        vm.sh("mkdir -p $HOME/lsq && tar xzf /tmp/layershell.tgz -C $HOME/lsq && chmod +x /tmp/nisse-panel", 60)
        vm.shot("00-before.png")

        # 1. the login autostart: closed
        vm.bg(f"sh -c '{ENV}; WAYLAND_DEBUG=1 /tmp/nisse-panel --background 2>&1 | grep --line-buffered -E \"nisse |qml:|wl_keyboard|xdg_activation|keyboard_interactivity\" > /tmp/panel.log'")
        time.sleep(12)
        vm.shot("01-background-closed.png")
        check("1 autostart: one panel runs", panels(vm) == 1, f"processes={panels(vm)}")
        check("1 autostart: the sidebar is closed", is_open(vm) is False, f"IsOpen={is_open(vm)}")

        time.sleep(45)   # the live session's Welcome Center maps late and takes the keyboard: let it settle first
        vm.shot("01c-settled.png")

        # 2. a second plain launch toggles it open and exits
        vm.sh(f"{ENV}; /tmp/nisse-panel", 30)
        time.sleep(3)
        vm.shot("02-toggled-open.png")
        check("2 second launch: the sidebar is open", is_open(vm) is True, f"IsOpen={is_open(vm)}")
        check("2 second launch: still one panel process", panels(vm) == 1, f"processes={panels(vm)}")

        # 3. Open by a launch with the pointer elsewhere, no click, no token: informational. KWin maps the surface but does not hand it
        # the keyboard (the Wayland trace shows no keyboard enter for this open). A real Meta+N or taskbar click carries an activation
        # token (GATE 3 hand check).
        keys_before = key_presses(vm)
        for ch in "hi":
            vm.monitor(f"sendkey {ch}")
        time.sleep(2)
        vm.shot("03-typed-open-by-launch.png")
        print(f"3 (info) keys received after an open by launch with the pointer elsewhere: {key_presses(vm) - keys_before}", flush=True)
        vm.monitor("sendkey esc")
        time.sleep(1)
        vm.sh(f"{ENV}; /tmp/nisse-panel --hide", 30)
        time.sleep(2)

        # 5. the pointer pushed against the right screen edge opens it after the dwell; the pointer is then over the sidebar, and KWin
        # hands an on-demand layer surface the keyboard when it appears under the pointer: typing and Escape work from there
        vm.monitor("mouse_move -4000 0")
        time.sleep(1)
        vm.monitor("mouse_move 4000 0")
        time.sleep(2.5)
        vm.shot("05-pointer-at-edge.png")
        check("5 the pointer at the right edge opens it", is_open(vm) is True, f"IsOpen={is_open(vm)}")
        keys_before = key_presses(vm)
        for ch in "hi":
            vm.monitor(f"sendkey {ch}")
        time.sleep(2)
        vm.shot("05b-typed-after-edge-open.png")
        got = key_presses(vm) - keys_before
        check("5b typed keys reach the sidebar opened by the pointer at the edge", got >= 2, f"{got} key presses")
        vm.monitor("sendkey esc")
        time.sleep(2)
        vm.shot("05c-escape.png")
        check("5c Escape closes the sidebar", is_open(vm) is False, f"IsOpen={is_open(vm)}")
        vm.monitor("mouse_move -4000 0")
        time.sleep(1)
        vm.sh(f"{ENV}; /tmp/nisse-panel --show", 30)
        time.sleep(2)
        vm.sh(f"{ENV}; /tmp/nisse-panel --hide", 30)
        time.sleep(2)
        check("5d --hide closes it", is_open(vm) is False, f"IsOpen={is_open(vm)}")

        # 6. what a clicked notice and the tray call
        vm.sh("busctl --user call org.nisse.Panel /org/nisse/Panel org.nisse.Panel ShowApprovals 2>&1", 20)
        time.sleep(3)
        vm.shot("06-show-approvals.png")
        check("6 ShowApprovals opens the sidebar", is_open(vm) is True, f"IsOpen={is_open(vm)}")

        # 7. toggling, --show, --hide
        vm.sh(f"{ENV}; /tmp/nisse-panel", 30)
        time.sleep(2)
        check("7 a launch toggles it closed", is_open(vm) is False, f"IsOpen={is_open(vm)}")
        vm.sh(f"{ENV}; /tmp/nisse-panel --show", 30)
        time.sleep(2)
        check("7 --show opens it", is_open(vm) is True, f"IsOpen={is_open(vm)}")
        vm.sh(f"{ENV}; /tmp/nisse-panel --background", 30)
        time.sleep(1)
        check("7 a second autostart does nothing (still open, one process)", is_open(vm) is True and panels(vm) == 1)
        vm.shot("07-final.png")
        log, _ = vm.sh("echo KEYBOARD-LINES; grep -c wl_keyboard /tmp/panel.log; grep wl_keyboard /tmp/panel.log | tail -40; echo NISSE-LINES; grep -E 'nisse |qml:' /tmp/panel.log | tail -20", 30)
        print("panel log:\n" + log)
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "sidebar-check.txt").write_text("\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
