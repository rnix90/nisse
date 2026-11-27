# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508c spike: can the taskbar's pinned launchers be set from outside, on a running panel, by Plasma's own scripting over D-Bus?

Plasma layout scripts (the one the nisse look ships) cannot read a file (no readFile in Plasma 6's scripting), so an install-time choice of
pins cannot be read by the layout script. The other way is `org.kde.PlasmaShell.evaluateScript` on the running shell. In a live session this
sets the Task Manager's `launchers` to four entries (Kate in, the terminal out), reads the setting back and takes screenshots before and after.

Usage: python tools/vm/pins_script_probe.py ISO OUTDIR(no spaces in the path)
"""
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

APPLETSRC = "~/.config/plasma-org.kde.plasma.desktop-appletsrc"
READ = f"echo pins=$(sed -n 's/^launchers=//p' {APPLETSRC} | tr -d ' ' | head -1)"
NEW = ["applications:nisse-panel.desktop", "preferred://filemanager", "applications:org.kde.kate.desktop", "applications:systemsettings.desktop"]
SCRIPT = ('var done=[];panelIds.forEach(function(id){var p=panelById(id);p.widgets("org.kde.plasma.icontasks").forEach(function(w){'
          'w.currentConfigGroup=["General"];w.writeConfig("launchers",' + str(NEW).replace("'", '"') + ');w.reloadConfig();done.push(id)})});done.join(",")')
CALL = "echo ret=$(busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s '" + SCRIPT + "' 2>&1 | cut -c1-120)"


def value(text, key):
    found = re.findall(rf"^{re.escape(key)}=(.*)$", text, re.M)
    return found[-1].strip() if found else None


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
        time.sleep(20)
        before = (value(vm.run(READ, 30)[0], "pins") or "").split(",")
        check("before: the live panel has its pins", len(before) >= 4, ",".join(before))
        vm.shot("pins-script-before.png")

        text, _ = vm.sh(CALL, 60)
        ret = value(text, "ret") or ""
        check("evaluateScript answers", ret != "" and "rror" not in ret, ret)
        time.sleep(15)
        vm.run("sync", 30)
        time.sleep(30)  # the shell writes its configuration a little later
        after = (value(vm.run(READ, 30)[0], "pins") or "").split(",")
        check("after: the pins are exactly the new list", after == NEW, ",".join(after))
        vm.shot("pins-script-after.png")
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "pins-script-probe.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
