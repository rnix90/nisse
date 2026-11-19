# SPDX-License-Identifier: GPL-2.0-or-later
"""N-415a spike: can the panel be a docked sidebar (a wlr-layer-shell surface) on the live Plasma session?

Boots an ISO with livevm, installs the probe (tools/vm/sidebar_probe, built in the build VM against the RELEASE layer-shell-qt that
matches the image's Plasma) into the live user's home folder, docks it on the right edge and steps through the questions the
ledger lists, taking a screenshot after each and reading what the probe logged:

    shown      is it on screen, full height, on the right edge, over a running terminal?
    taskbar    does the taskbar show a button for it? what does KWin list for it?
    typing     does the text field take typed keys (focus on demand)? (keys sent through the QEMU monitor)
    slide      does animating the margin slide it out of and back into view?
    reserve    does an exclusive zone push other windows (and a normal window)?

Usage: python tools/vm/sidebar_spike.py ISO OUTDIR PROBE_BINARY LAYERSHELL_TGZ
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

HERE = Path(__file__).parent
ENV = (
    "export LD_LIBRARY_PATH=$HOME/lsq/usr/lib64; "
    "export QT_PLUGIN_PATH=$HOME/lsq/usr/lib64/qt6/plugins; "
    "export QML_IMPORT_PATH=$HOME/lsq/usr/lib64/qt6/qml QML2_IMPORT_PATH=$HOME/lsq/usr/lib64/qt6/qml; "
    "export QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=wayland"
)


def cmd(vm, name):
    vm.sh(f"echo {name} > /tmp/sidebar.cmd", 20)
    time.sleep(1.5)


def type_text(vm, text):
    for ch in text:
        vm.monitor(f"sendkey {ch}")


def click_in_sidebar(vm):
    """Relative mouse moves: slam to the right edge (the pointer clamps there), step in 200 px, click."""
    vm.monitor("mouse_move 4000 0")
    vm.monitor("mouse_move -200 0")
    vm.monitor("mouse_button 1")
    vm.monitor("mouse_button 0")


def main(iso, out, binary, tgz):
    vm = livevm.Vm(iso, out)
    notes = []
    try:
        vm.login()
        vm.prepare_session()
        vm.true_colors()
        vm.put("/tmp/sidebar_probe", Path(binary).read_bytes())
        vm.put("/tmp/layershell.tgz", Path(tgz).read_bytes())
        vm.put("/tmp/probe.qml", (HERE / "sidebar_probe" / "probe.qml").read_bytes())
        vm.sh("mkdir -p $HOME/lsq && tar xzf /tmp/layershell.tgz -C $HOME/lsq && chmod +x /tmp/sidebar_probe && echo : > /tmp/sidebar.cmd", 60)
        vm.sh("rpm -q plasma-workspace kwin layer-shell-qt 2>&1 | head -3", 30)
        vm.bg("konsole")
        time.sleep(8)
        vm.shot("00-before.png")

        vm.bg(f"sh -c '{ENV}; /tmp/sidebar_probe /tmp/probe.qml > /tmp/probe.log 2>&1'")
        time.sleep(10)
        vm.shot("01-shown.png")
        log, _ = vm.sh("cat /tmp/probe.log", 20)
        notes.append("after start:\n" + log)

        info, _ = vm.sh("qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation 2>&1 | grep -i -B2 -A12 'sidebar-probe\\|nisse sidebar' | head -40", 60)
        notes.append("kwin support information about the probe:\n" + info)
        vm.shot("02-taskbar.png")

        cmd(vm, "focus")
        type_text(vm, "hello")
        time.sleep(2)
        vm.shot("03-typed-after-focus-request.png")
        log, _ = vm.sh("grep -E 'typed=|focus|active' /tmp/probe.log | tail -8", 20)
        notes.append("typing after a focus request (no click):\n" + log)

        click_in_sidebar(vm)
        time.sleep(1)
        type_text(vm, "xyz")
        time.sleep(2)
        vm.shot("04-typed-after-click.png")
        log, _ = vm.sh("grep -E 'typed=|focus|active' /tmp/probe.log | tail -8", 20)
        notes.append("typing after a click:\n" + log)

        cmd(vm, "hide")
        time.sleep(0.3)
        vm.shot("05-sliding-out-midway.png")
        time.sleep(2)
        vm.shot("06-hidden.png")
        cmd(vm, "show")
        time.sleep(2)
        vm.shot("07-shown-again.png")

        cmd(vm, "reserve")
        time.sleep(2)
        vm.shot("08-reserved.png")
        cmd(vm, "unreserve")
        log, _ = vm.sh("cat /tmp/probe.log", 20)
        notes.append("full probe log:\n" + log)
    finally:
        (Path(out) / "spike-notes.txt").write_text("\n\n".join(notes), encoding="utf-8")
        vm.close()
    print("\n\n".join(notes))


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
