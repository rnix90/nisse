# SPDX-License-Identifier: GPL-2.0-or-later
"""N-207 spike: what does Plasma 6's task manager draw for a count badge, and can it be red or green?

Boots an ISO with livevm, starts Konsole (pinned in the nisse panel layout), sends the Unity launcher-entry update
(the mechanism Plasma's task manager listens to for apps that are not KDE-integrated) with a count, with and without
the urgent flag, takes screenshots, and prints the badge code and colors found in the installed Plasma.

Usage: python tools/vm/badge_spike.py ISO OUTDIR
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

DESKTOP = "application://org.kde.konsole.desktop"


def update(vm, props):
    vm.sh(
        "busctl --user emit /com/canonical/unity/launcherentry/1 com.canonical.Unity.LauncherEntry Update "
        f"'sa{{sv}}' '{DESKTOP}' {len(props)} {props_text(props)}",
        30,
    )


def props_text(props):
    out = []
    for key, (kind, value) in props.items():
        out.append(f"{key} {kind} {value}")
    return " ".join(out)


def icon_mode(iso, out, binary):
    """Second half of the spike: an app that paints its own window icon with a badge (tools/vm/icon_probe.cpp)."""
    vm = livevm.Vm(iso, out)
    try:
        vm.login()
        vm.prepare_session()
        vm.put("/tmp/icon_probe", Path(binary).read_bytes())
        vm.sh("chmod +x /tmp/icon_probe", 30)
        vm.bg("/tmp/icon_probe nisse-panel 3 red")
        time.sleep(8)
        vm.shot("10-pinned-red3.png")
        vm.bg("/tmp/icon_probe probe-unpinned 5 green")
        time.sleep(8)
        vm.shot("11-plus-unpinned-green5.png")
    finally:
        vm.close()


def real_badge(iso, out, binary):
    """The panel's own LauncherBadge code (tools/vm/badge_probe.cpp) against a live Plasma: pinned panel launcher."""
    vm = livevm.Vm(iso, out)
    try:
        vm.login()
        vm.prepare_session()
        vm.put("/tmp/badge_probe", Path(binary).read_bytes())
        vm.sh("chmod +x /tmp/badge_probe", 30)
        vm.bg("/tmp/badge_probe 3")
        time.sleep(8)
        vm.shot("20-real-badge-3.png")
        vm.sh("pkill -x badge_probe; true", 20)
        time.sleep(4)
        vm.shot("21-real-badge-cleared.png")
    finally:
        vm.close()


def main():
    iso, out = sys.argv[1], Path(sys.argv[2])
    if len(sys.argv) > 3 and sys.argv[3] == "--real":
        return real_badge(iso, out, sys.argv[4])
    if len(sys.argv) > 3 and sys.argv[3] == "--icon":
        return icon_mode(iso, out, sys.argv[4])
    vm = livevm.Vm(iso, out)
    try:
        vm.login()
        vm.prepare_session()
        text, _ = vm.sh("find /usr -path '*taskmanager*' -iname '*Badge*' 2>/dev/null | head; "
                        "find /usr -path '*taskmanager*' -iname '*.qml' 2>/dev/null | head -40", 60)
        print(text.encode('ascii', 'replace').decode())
        vm.bg("konsole")
        time.sleep(8)
        vm.shot("00-konsole-no-badge.png")
        update(vm, {"count": ("x", 3), "count-visible": ("b", "true")})
        time.sleep(4)
        vm.shot("01-count3.png")
        update(vm, {"count": ("x", 3), "count-visible": ("b", "true"), "urgent": ("b", "true")})
        time.sleep(4)
        vm.shot("02-count3-urgent.png")
        update(vm, {"count": ("x", 12), "count-visible": ("b", "true")})
        time.sleep(4)
        vm.shot("03-count12.png")
        text, _ = vm.sh("f=$(find /usr -path '*taskmanager*' -iname 'Badge*.qml' | head -1); echo FILE=$f; "
                        "[ -n \"$f\" ] && grep -n -i 'color\\|font\\|family' \"$f\" | head -40", 30)
        print(text.encode('ascii', 'replace').decode())
    finally:
        vm.close()


if __name__ == "__main__":
    main()
