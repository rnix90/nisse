# SPDX-License-Identifier: GPL-2.0-or-later
"""N-415a focus experiment: does a layer-shell surface that is mapped ALREADY SLID OUT of sight get the keyboard when it is slid in and
activated, compared with one mapped on screen? Boots the ISO, runs tools/vm/sidebar_probe both ways and types into each.

Usage: python tools/vm/sidebar_focus_probe.py ISO OUTDIR(no spaces) PROBE_BINARY LAYERSHELL_TGZ
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

HERE = Path(__file__).parent
ENV = (
    "export LD_LIBRARY_PATH=$HOME/lsq/usr/lib64; export QT_PLUGIN_PATH=$HOME/lsq/usr/lib64/qt6/plugins; "
    "export QML_IMPORT_PATH=$HOME/lsq/usr/lib64/qt6/qml QML2_IMPORT_PATH=$HOME/lsq/usr/lib64/qt6/qml; "
    "export QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=wayland"
)


def typed(vm):
    out, _ = vm.sh("grep -c 'typed=' /tmp/probe.log", 20)
    for line in out.splitlines():
        if line.strip().isdigit():
            return int(line.strip())
    return 0


def scenario(vm, name, hidden):
    vm.sh("echo : > /tmp/sidebar.cmd", 20)
    flag = "export PROBE_START_HIDDEN=1; " if hidden else ""
    vm.bg(f"sh -c '{ENV}; {flag}/tmp/sidebar_probe /tmp/probe.qml > /tmp/probe.log 2>&1'")
    time.sleep(40)   # let the live session's own windows settle
    if hidden:
        vm.sh("echo show > /tmp/sidebar.cmd", 20)
        time.sleep(3)
    vm.sh("echo focus > /tmp/sidebar.cmd", 20)
    time.sleep(3)
    before = typed(vm)
    for ch in "abc":
        vm.monitor(f"sendkey {ch}")
    time.sleep(2)
    vm.shot(f"{name}.png")
    got = typed(vm) - before
    print(f"{name}: start hidden={hidden}: {got} typed events", flush=True)
    log, _ = vm.sh("grep -E 'active|focus|typed|docked' /tmp/probe.log | tail -12", 20)
    print(log, flush=True)
    vm.sh("kill $(pgrep -x sidebar_probe)", 20)
    time.sleep(2)
    return got


def main(iso, out, binary, tgz):
    vm = livevm.Vm(iso, out)
    try:
        vm.login()
        vm.prepare_session()
        vm.true_colors()
        vm.put("/tmp/sidebar_probe", Path(binary).read_bytes())
        vm.put("/tmp/layershell.tgz", Path(tgz).read_bytes())
        vm.put("/tmp/probe.qml", (HERE / "sidebar_probe" / "probe.qml").read_bytes())
        vm.sh("mkdir -p $HOME/lsq && tar xzf /tmp/layershell.tgz -C $HOME/lsq && chmod +x /tmp/sidebar_probe", 60)
        a = scenario(vm, "A-mapped-on-screen", False)
        b = scenario(vm, "B-mapped-slid-out", True)
        print(f"RESULT on screen: {a}, slid out: {b}")
    finally:
        vm.close()


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
