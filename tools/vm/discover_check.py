# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508b: what Discover offers, with and without its PackageKit backend, shown in a live Plasma session.

Boots an ISO with livevm (the old ISO has Discover with all its backends, so the "before" is real), then:

    1  before: Discover lists its backends (`plasma-discover --listbackends`): the PackageKit one is among them
    2  the PackageKit backend package (plasma-discover-packagekit, which holds the backend and the notifier's PackageKit part) is removed
       the way the image build would leave it out; nothing else is removed
    3  after: the PackageKit backend is gone, the Flatpak backend is still listed, and Discover still starts and draws its window
       (screenshot of the Updates page, which shows what is left to update)

Usage: python tools/vm/discover_check.py ISO OUTDIR(no spaces in the path)
"""
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import livevm  # noqa: E402

LIST = "echo backends=$(plasma-discover --listbackends 2>/dev/null | paste -sd, -)"


def value(text, key):
    """The text after `key=` on the last line that starts with it, None when absent."""
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

        before, _ = vm.sh(LIST, 90)
        b = (value(before, "backends") or "").lower()
        check("before: Discover lists a PackageKit backend", "packagekit" in b, b[:200])
        check("before: and the Flatpak backend", "flatpak" in b, b[:150])

        text, _ = vm.run("sudo rpm -e --nodeps plasma-discover-packagekit 2>&1 | tail -2; echo left=$(rpm -q plasma-discover-packagekit 2>&1 | cut -c1-60)", 120)
        check("the PackageKit backend package is removed", "not installed" in (value(text, "left") or ""), str(value(text, "left")))

        after, _ = vm.sh(LIST, 90)
        a = (value(after, "backends") or "").lower()
        check("after: no PackageKit backend", a != "" and "packagekit" not in a, a[:150])
        check("after: the Flatpak backend is still listed", "flatpak" in a, a[:150])

        vm.bg("plasma-discover --mode update")
        time.sleep(40)
        text, _ = vm.run("echo running=$(pgrep -c -x plasma-discover)", 30)
        check("Discover starts without it", (value(text, "running") or "0") != "0", str(value(text, "running")))
        vm.shot("discover-updates-after.png")
    finally:
        failed = [r for r in results if not r[1]]
        (Path(out) / "discover-check.txt").write_text(
            "\n".join(("PASS " if ok else "FAIL ") + n + (f"  [{d}]" if d else "") for n, ok, d in results), encoding="utf-8")
        vm.close()
    print(f"{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
