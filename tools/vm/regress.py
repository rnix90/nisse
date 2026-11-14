# SPDX-License-Identifier: GPL-2.0-or-later
"""Screenshot regression harness (ledger N-113).

  python tools/vm/regress.py run --iso PATH      boot the ISO in QEMU, take the named screens, compare to the goldens
  python tools/vm/regress.py check               compare an earlier capture (out/regress/last) to the goldens
  python tools/vm/regress.py accept desktop ...  make the last capture the golden for these screens (or --all)

Goldens live in tests/golden/NAME.png. Exit codes: 0 all screens pass, 1 a screen failed or is missing, 2 bad usage.
The comparison itself is in imgdiff.py; the VM driver is livevm.py. Extended in N-519 and N-523.
"""
import argparse
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))

import imgdiff  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
GOLDEN = REPO / "tests" / "golden"
OUT = REPO / "out" / "regress" / "last"

# The clock and the tray change by themselves (time, network and volume icons), so they are left out of the comparison.
CLOCK = (0.78, 0.935, 0.965, 0.99)
PANEL_CLOCK = (0.78, 0.0, 0.965, 1.0)

# A terminal that shows the 16 palette colours and the font, and nothing that varies: no prompt, no time, no host name.
TERMINAL_SCRIPT = r"""#!/bin/bash
printf '\033[1;38;2;224;98;63mnisse terminal\033[0m  Fira Code 10  ->  != == >= <= => ==> -> <- ::\n\n'
for i in 0 1 2 3 4 5 6 7; do printf '\033[3%dm color%d \033[0m' $i $i; done; echo
for i in 0 1 2 3 4 5 6 7; do printf '\033[9%dm bright%d \033[0m' $i $i; done; echo
for i in 0 1 2 3 4 5 6 7; do printf '\033[4%dm  %d  \033[0m' $i $i; done; echo; echo
printf '\033[31merror:\033[0m something failed   \033[32mok:\033[0m done   \033[33mwarn:\033[0m careful   \033[34minfo:\033[0m note\n'
printf '\033[90m# a comment in bright black\033[0m\n'
exec sleep 600
"""


@dataclass(frozen=True)
class Screen:
    name: str
    masks: tuple = (CLOCK,)         # fractions of this screen that are ignored when comparing
    launch: str = None              # program started in the guest before the shot
    action: str = None              # or a named step ("launcher")
    wait: int = 8                   # seconds to let it draw
    files: tuple = ()               # (guest path, text) pairs put on the guest first
    crop_of: str = None             # this screen is cut from another screen's shot
    crop: tuple = None              # fractions (left, top, right, bottom) of that shot


SCREENS = [
    Screen("desktop", wait=3),
    Screen("panel", masks=(PANEL_CLOCK,), crop_of="desktop", crop=(0.0, 0.93, 1.0, 1.0)),
    Screen("launcher", action="launcher", wait=5),
    Screen("settings", launch="systemsettings kcm_colors", wait=14),
    Screen("terminal", launch="konsole -e bash /tmp/regress-terminal.sh", wait=10,
           files=(("/tmp/regress-terminal.sh", TERMINAL_SCRIPT),)),
]
BY_NAME = {s.name: s for s in SCREENS}


def names():
    return [s.name for s in SCREENS]


def screen(name):
    return BY_NAME[name]


def build_screens(raw):
    """From the screens taken in the VM (name -> Image) make every screen, cutting the derived ones such as the panel."""
    built = {}
    for s in SCREENS:
        if s.crop_of:
            if s.crop_of in raw:
                built[s.name] = imgdiff.crop_fraction(raw[s.crop_of], s.crop)
        elif s.name in raw:
            built[s.name] = raw[s.name]
    return built


@dataclass
class Row:
    name: str
    status: str   # pass, fail, no-golden, no-capture
    result: object = None


def evaluate(actual_dir, golden_dir, only=None, threshold=imgdiff.DEFAULT_THRESHOLD, tolerance=imgdiff.DEFAULT_TOLERANCE):
    """Compare each captured screen in actual_dir with its golden; a failing screen gets a diff image in actual_dir/diff."""
    actual_dir, golden_dir = Path(actual_dir), Path(golden_dir)
    rows = []
    for s in SCREENS:
        if only and s.name not in only:
            continue
        a, g = actual_dir / f"{s.name}.png", golden_dir / f"{s.name}.png"
        diff = actual_dir / "diff" / f"{s.name}.png"
        if not a.is_file():
            rows.append(Row(s.name, "no-capture"))
            continue
        if not g.is_file():
            rows.append(Row(s.name, "no-golden"))
            continue
        with Image.open(a) as ia, Image.open(g) as ig:
            masks = [imgdiff.box_from_fractions(m, ia.size) for m in s.masks]
            r = imgdiff.compare(ia, ig, threshold=threshold, tolerance=tolerance, masks=masks)
        if r.ok:
            diff.unlink(missing_ok=True)
        else:
            diff.parent.mkdir(parents=True, exist_ok=True)
            r.diff_image.save(diff)
        rows.append(Row(s.name, "pass" if r.ok else "fail", r))
    return rows


def accept(actual_dir, golden_dir, wanted):
    """Make the captured screens the goldens. Raises ValueError for an unknown name, FileNotFoundError for no capture."""
    unknown = [n for n in wanted if n not in BY_NAME]
    if unknown:
        raise ValueError(f"unknown screen(s): {', '.join(unknown)}; known: {', '.join(names())}")
    actual_dir, golden_dir = Path(actual_dir), Path(golden_dir)
    for n in wanted:
        if not (actual_dir / f"{n}.png").is_file():
            raise FileNotFoundError(f"no capture of {n} in {actual_dir}")
    golden_dir.mkdir(parents=True, exist_ok=True)
    for n in wanted:
        shutil.copyfile(actual_dir / f"{n}.png", golden_dir / f"{n}.png")


def capture(vm, out_dir, only=None):
    """Take the screens in a booted, prepared VM (livevm) and save the finished screens as out_dir/NAME.png."""
    import time as _t
    out_dir = Path(out_dir)  # note: vm.shot() writes where the VM was told to (a local folder), see main()
    out_dir.mkdir(parents=True, exist_ok=True)
    want = set(only) if only else set(names())
    want |= {s.crop_of for s in SCREENS if s.name in want and s.crop_of}
    close = "pkill -x konsole; pkill -x systemsettings; pkill -f plasma-welcome; pkill -x dolphin; true"
    toggle = ("dbus-send --session --dest=org.kde.plasmashell --type=method_call /PlasmaShell "
              "org.kde.PlasmaShell.activateLauncherMenu")
    raw = {}
    for s in SCREENS:
        if s.crop_of or s.name not in want:
            continue
        vm.sh(close, 20)
        _t.sleep(1)
        for path, text in s.files:
            vm.put(path, text.encode())
        if s.launch:
            vm.bg(s.launch)
        elif s.action == "launcher":
            vm.sh(toggle, 20)
        _t.sleep(s.wait)
        raw[s.name] = Image.open(vm.shot(f"raw_{s.name}.png")).convert("RGB")
        if s.action == "launcher":
            vm.sh(toggle, 20)
    vm.sh(close, 20)
    for name, img in build_screens(raw).items():
        img.save(out_dir / f"{name}.png")


def report(rows, out_dir):
    for r in rows:
        if r.status == "pass":
            print(f"PASS {r.name} ({r.result.fraction * 100:.2f}% changed)")
        elif r.status == "fail":
            why = "size changed" if r.result.size_mismatch else f"{r.result.fraction * 100:.2f}% changed"
            print(f"FAIL {r.name} ({why}; diff image: {Path(out_dir) / 'diff' / (r.name + '.png')})")
        elif r.status == "no-golden":
            print(f"NO-GOLDEN {r.name} (accept it: python tools/vm/regress.py accept {r.name})")
        else:
            print(f"NO-CAPTURE {r.name}")
    bad = [r for r in rows if r.status != "pass"]
    print(f"{len(rows) - len(bad)} of {len(rows)} screens pass")
    return 1 if bad or not rows else 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="regress.py", description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp, need_actual=True):
        sp.add_argument("--actual", type=Path, default=OUT, help="folder of captured screens (default out/regress/last)")
        sp.add_argument("--golden", type=Path, default=GOLDEN, help="folder of golden screens (default tests/golden)")

    def tuning(sp):
        sp.add_argument("--only", help="comma-separated screen names")
        sp.add_argument("--threshold", type=int, default=imgdiff.DEFAULT_THRESHOLD)
        sp.add_argument("--tolerance", type=float, default=imgdiff.DEFAULT_TOLERANCE)

    run = sub.add_parser("run", help="boot an ISO, capture the screens, compare")
    run.add_argument("--iso", type=Path, required=True)
    run.add_argument("--keep", action="store_true", help="leave the VM running afterwards")
    common(run)
    tuning(run)
    chk = sub.add_parser("check", help="compare an earlier capture to the goldens")
    common(chk)
    tuning(chk)
    acc = sub.add_parser("accept", help="make the last capture the golden for the named screens")
    acc.add_argument("screens", nargs="*")
    acc.add_argument("--all", action="store_true")
    common(acc)
    a = p.parse_args(argv)

    if a.cmd == "accept":
        wanted = names() if a.all else a.screens
        if not wanted:
            print("name the screens to accept, or use --all", file=sys.stderr)
            return 2
        try:
            accept(a.actual, a.golden, wanted)
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
        except FileNotFoundError as e:
            print(e, file=sys.stderr)
            return 1
        print(f"accepted: {', '.join(wanted)}")
        return 0

    only = [n for n in a.only.split(",")] if a.only else None
    if only and any(n not in BY_NAME for n in only):
        print(f"unknown screen in --only; known: {', '.join(names())}", file=sys.stderr)
        return 2
    if a.cmd == "run":
        import livevm
        # QEMU writes its screendumps itself and cannot write to the SMB share the repo may live on: use a local folder
        scratch = Path(tempfile.mkdtemp(prefix="nisse-regress-"))
        vm = livevm.Vm(a.iso, scratch)
        try:
            vm.login()
            vm.prepare_session()
            capture(vm, a.actual, only)
        finally:
            if not a.keep:
                vm.close()
                shutil.rmtree(scratch, ignore_errors=True)
    return report(evaluate(a.actual, a.golden, only, a.threshold, a.tolerance), a.actual)


if __name__ == "__main__":
    sys.exit(main())
