#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Unattended install-to-disk harness (ledger N-303).

Installs the nisse ISO onto a fresh qcow2 disk in QEMU (on the Windows host, the same way the other VM tools run), with an
answer file, then boots the installed disk, logs in over the serial console and checks the result. Many later tasks need an
installed system (the layout in N-304, snapshots, rollback, GATE 3).

Mechanism (verified in the N-303 spike, 2026-11-16):

  * `anaconda --liveinst` (what `liveinst` runs) ignores any kickstart file: pyanaconda/startup_utils.py only reads one when
    `options.ksfile and not options.liveinst`, and liveinst itself prints "Kickstart is not supported on Live ISO installs".
  * So the harness runs `anaconda --cmdline --kickstart=FILE` as root in the live session, and the answer file uses the
    `liveimg` payload on the root image the ISO already carries (/run/initramfs/live/LiveOS/squashfs.img): the installed
    system is the live image's root, copied to the disk. The product profile (btrfs layout, N-304) applies the same way,
    because the profile is chosen from os-release, not from the payload.
  * Anaconda needs a D-Bus session bus (without one it dies with "Error spawning command line dbus-launch"), so it is run under
    `dbus-run-session`. liveuser has an empty password; `sudo -S` with an empty line gets root over the serial console.
  * The login the harness uses after the install has a random password made for each run (never stored in the repo).

    python tools/vm/install_disk.py ISO [--out DIR] [--size 40G] [--keep]
"""
import argparse
import re
import secrets
import string
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import livevm  # noqa: E402

QEMU_IMG = livevm.QEMU_DIR / "qemu-img.exe"
LIVE_IMAGE = "file:///run/initramfs/live/LiveOS/squashfs.img"
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
FAIL_MARKERS = ("The installation was stopped due to an error", "Traceback (most recent call last)",
                "An unknown error has occurred", "The exact error message is", "The installer will now terminate")
SUDO = r"printf '\n' | sudo -S -p ''"    # liveuser has an empty password; sudo -n refuses, sudo -S with an empty line works
LOG_FILES = ("/tmp/anaconda.out", "/tmp/anaconda.log", "/tmp/program.log", "/tmp/storage.log", "/tmp/packaging.log")


def new_password(n=20):
    """A throwaway password for the harness login: random per run, letters and digits only."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))


def kickstart(user, password):
    """The answer file. No `--type` on autopart: the scheme and subvolumes come from the product profile (N-301, N-304)."""
    if not USER_RE.match(user):
        raise ValueError(f"not a plain user name: {user!r}")
    if not re.fullmatch(r"[A-Za-z0-9]+", password):
        raise ValueError("the harness password must be letters and digits only")
    return "\n".join([
        "lang en_US.UTF-8",
        "keyboard us",
        "timezone UTC --utc",
        "rootpw --lock",
        f"user --name={user} --groups=wheel --password={password} --plaintext",
        f"liveimg --url={LIVE_IMAGE}",
        "zerombr",
        "clearpart --all --initlabel",
        "autopart",
        "xconfig --startxonboot",
        'bootloader --append="console=ttyS0"',
        "poweroff",
    ]) + "\n"


def anaconda_command(profile=None):
    """The command that runs the installer in the live session (as root, in the background, output to a file)."""
    profile = profile or None          # an empty value means "no forced profile": the real nisse behaviour
    if profile is not None and not re.fullmatch(r"[a-z][a-z0-9-]*", profile):
        raise ValueError(f"not a profile id: {profile!r}")
    extra = f" --profile {profile}" if profile else ""
    return ("setenforce 0; modprobe dm-mod; nohup dbus-run-session -- anaconda --cmdline --kickstart=/tmp/ks.cfg"
            f"{extra} > /tmp/anaconda.out 2>&1 &")


def install_failed(output):
    return any(m in output for m in FAIL_MARKERS)


@dataclass
class Check:
    name: str
    command: str         # {user} and {sudo} are filled in; {sudo} runs the command as root with the harness user's password
    expect: str          # a regular expression that must match the command's output
    why: str
    retry: int = 0       # seconds to keep trying (a service may still be starting when the login prompt appears)


LAYOUT = [("/", "root"), ("/home", "home"), ("/var/log", "var_log"), ("/var/cache", "var_cache")]

CHECKS = [
    Check("os-release", "grep -E '^(ID|NAME|VERSION_ID)=' /etc/os-release", r'(?m)^ID=nisse$', "the installed system is nisse"),
    Check("root-filesystem", "findmnt -n -o FSTYPE,SOURCE /", r"\S+\s+\S+", "/ is a real mounted filesystem (the layout checks follow)"),
    Check("bootloader", "{sudo} ls /boot/efi/EFI", r"(?i)fedora", "the boot loader was written to the EFI system partition"),
    Check("login-target", "systemctl get-default; for u in display-manager sddm plasmalogin; do echo $u=$(systemctl is-active $u); done; "
          "systemctl --failed --no-legend | head -8", r"(?m)^(display-manager|sddm|plasmalogin)=active$",
          "the graphical login is up", retry=180),
    Check("user", "id -nG {user}", r"wheel", "the answer file's user exists and is an administrator"),
    # the layout decided in N-302 and set by the nisse profile (N-304): one btrfs volume, a subvolume per mount point
    Check("compression", "findmnt -n -o OPTIONS /", r"compress=zstd:1", "the root filesystem is compressed with zstd:1"),
    *[Check(f"subvolume-{sub}", f"findmnt -n -o FSTYPE,SOURCE {mp}", rf"(?m)^btrfs\s+\S+\[/{sub}\]\s*$",
            f"{mp} is the btrfs subvolume {sub}") for mp, sub in LAYOUT],
]


def run_check(vm, check, user, password):
    """Run one check in the installed system; return (ok, last output). Retries for `check.retry` seconds."""
    sudo = f"echo {password} | sudo -S -p ''"
    end = time.time() + check.retry
    while True:
        output, code = vm.run(check.command.format(user=user, sudo=sudo), 60)
        output = asciify(output).replace(password, "***")
        ok = code == 0 and re.search(check.expect, output) is not None
        if ok or time.time() >= end:
            return ok, output.strip()
        time.sleep(10)


def make_disk(path, size):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    subprocess.run([str(QEMU_IMG), "create", "-f", "qcow2", str(path), size], check=True, capture_output=True)
    return path


def collect_logs(vm, out, say=print):
    """Save the installer's logs from the live session next to the run (called when an install fails)."""
    out = Path(out)
    for name in LOG_FILES:
        text, _ = vm.run(f"{SUDO} tail -n 120 {name} 2>&1", 60)   # the installer's logs are root's
        (out / f"fail-{Path(name).name}").write_text(asciify(text))
    say(f"installer logs saved in {out} (fail-*.log, fail-anaconda.out)")


def asciify(text):
    return text.encode("ascii", "replace").decode("ascii")


def install(iso, out, user, password, size="40G", timeout=3600, say=print, on_failure=None, profile=None):
    """Phase 1: boot the live ISO with an empty disk and run the installer. Returns (disk path, installer output tail)."""
    out = Path(out)
    disk = make_disk(out / "target.qcow2", size)
    vm = livevm.Vm(iso, out / "install", disks=[disk])
    tail = ""
    try:
        t0 = time.time()
        vm.login()
        say(f"live session up after {int(time.time() - t0)} s")
        vm.put("/tmp/ks.cfg", kickstart(user, password).encode())
        vm.run(SUDO + " bash -c '" + anaconda_command(profile) + "'; sleep 3", 60)
        say("installer started")
        last = ""
        while time.time() - t0 < timeout:
            time.sleep(60)
            if vm.proc.poll() is not None:        # the answer file says poweroff: the machine is gone, the install ended
                say(f"machine powered off after {int(time.time() - t0)} s")
                return disk, last
            try:
                text, _ = vm.run("tail -c 400 /tmp/anaconda.out; echo; pgrep -x anaconda >/dev/null; echo state=$?", 60)
            except (TimeoutError, OSError):
                if vm.proc.poll() is not None:
                    return disk, last
                continue
            text = asciify(text)
            last = text
            m = re.findall(r"Installing software \d+%|[A-Z][a-z]+ [a-z]+[^\n]*", text)
            say(f"t={int(time.time() - t0)} s  {m[-1] if m else ''}")
            if install_failed(text):
                collect_logs(vm, out, say)
                if on_failure:
                    on_failure(vm)
                raise RuntimeError("the installer failed:\n" + text[-800:])
            if "state=1" in text:
                say("installer exited")
                return disk, text
        raise TimeoutError("the install did not finish in time; last output:\n" + last[-500:])
    finally:
        tail = tail or ""
        vm.close()


def boot_and_check(out, user, password, boot_timeout=900, say=print):
    """Phase 2: boot the installed disk alone (the NVRAM file from phase 1 is kept), log in over serial, run CHECKS."""
    out = Path(out)
    disk = out / "target.qcow2"
    vm = livevm.Vm(None, out / "install", disks=[disk], fresh_vars=False)
    results = []
    try:
        vm.expect("login:", boot_timeout)
        say("installed system reached a login prompt")
        vm.send(f"{user}\n")
        vm.expect("assword", 60)
        vm.send(f"{password}\n")
        time.sleep(5)
        vm.run("export HOME=$HOME; cd ~", 30)
        for c in CHECKS:
            ok, output = run_check(vm, c, user, password)
            results.append((c.name, ok, output))
            say(("ok   " if ok else "FAIL ") + c.name + ": " + c.why)
            if not ok:
                say("     output: " + output[-600:].replace("\n", " | "))
        return results
    finally:
        vm.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("iso")
    ap.add_argument("--out", default="out/install")
    ap.add_argument("--size", default="40G")
    ap.add_argument("--user", default="tester")
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--profile", default=None, help="force an Anaconda profile id (a stand-in until N-304 ships nisse's own)")
    args = ap.parse_args(argv)
    password = new_password()
    Path(args.out).mkdir(parents=True, exist_ok=True)
    (Path(args.out) / "harness-login.txt").write_text(f"{args.user} {password}" + chr(10))   # out/ is git-ignored; a throwaway login for poking at the disk
    disk, _ = install(args.iso, args.out, args.user, password, args.size, args.timeout, profile=args.profile)
    results = boot_and_check(args.out, args.user, password)
    failed = [n for n, ok, _ in results if not ok]
    if failed:
        print("FAIL: " + ", ".join(failed))
        return 1
    print("PASS: the installed system booted to a login and passed every check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
