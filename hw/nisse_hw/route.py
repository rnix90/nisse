# SPDX-License-Identifier: GPL-2.0-or-later
"""Turn a hardware profile into dnf commands and run them, remembering progress."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

from nisse_hw.detect import DMI_ROOT, PCI_ROOT, Profile, detect, read_dmi, read_pci_ids

STATE_DIR = Path("/var/lib/nisse")
INSTALLED_PROFILES = Path("/usr/share/nisse/hw/profiles.toml")
EFIVARS = Path("/sys/firmware/efi/efivars")
SECURE_BOOT_VAR = "SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
EX_TEMPFAIL = 75
# Failed command runs allowed per boot before the state becomes "failed". At the unit's 5 minute restart interval this
# is about an hour of retrying; a new boot (or `nisse-hwroute --retry`) starts a fresh budget.
MAX_ATTEMPTS = 12
BOOT_ID_FILE = Path("/proc/sys/kernel/random/boot_id")


@dataclass(frozen=True)
class Plan:
    profile: Profile
    commands: tuple[tuple[str, ...], ...]
    notes: tuple[str, ...]
    # True for kernels the stock shim will not boot (no MOK enrollment yet): wait until Secure Boot is off.
    needs_secure_boot_off: bool = False


def _default_release() -> str:
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("VERSION_ID="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return "44"


def secure_boot_enabled(efivars: Path = EFIVARS) -> bool:
    """True if UEFI Secure Boot is on. No EFI, or an unreadable variable, counts as off."""
    try:
        data = (efivars / SECURE_BOOT_VAR).read_bytes()
    except OSError:
        return False
    return len(data) > 4 and data[-1] == 1


def plan(profile: Profile, profiles_toml: Path, release: str | None = None) -> Plan:
    """Commands for `profile` from the TOML file, with {release} filled in."""
    release = release or _default_release()
    entry = tomllib.loads(Path(profiles_toml).read_text()).get(profile.value, {})
    commands = tuple(tuple(arg.format(release=release) for arg in cmd) for cmd in entry.get("commands", []))
    return Plan(profile, commands, tuple(entry.get("notes", [])), bool(entry.get("needs_secure_boot_off", False)))


def _one_line(text: object) -> str:
    return " ".join(str(text).split())


def _giving_up(failures: int, last_error: str) -> str:
    return (f"nisse-hwroute: giving up after {failures} failed attempts: {last_error} "
            "(reboot, or run: nisse-hwroute --retry && systemctl start nisse-hwroute)")


def _boot_id() -> str | None:
    try:
        return BOOT_ID_FILE.read_text().strip() or None
    except OSError:
        return None


def _write_state(state_dir: Path, profile: Profile, status: str, attempts: int, failures: int = 0,
                 last_error: str = "", boot_id: str | None = None) -> None:
    state: dict = {"profile": profile.value, "status": status, "attempts": attempts}
    if status != "done":
        state["failures"] = failures
        if boot_id:
            state["boot_id"] = boot_id
        if last_error:
            state["last_error"] = last_error
    (state_dir / "hw-profile.json").write_text(json.dumps(state))


def _read_state(state_dir: Path) -> dict:
    try:
        state = json.loads((state_dir / "hw-profile.json").read_text())
    except (OSError, ValueError):
        return {}
    return state if isinstance(state, dict) else {}


def execute(p: Plan, runner: Callable[[Sequence[str]], int], state_dir: Path, secure_boot: bool = False,
            boot_id: str | None = None) -> int:
    """Run the plan. Returns 0 when done, 75 (EX_TEMPFAIL) when a command failed and should be retried, and 1 once
    MAX_ATTEMPTS commands have failed in this boot (status "failed", no more retries until the next boot or --retry)."""
    boot_id = boot_id or _boot_id()
    state_dir.mkdir(parents=True, exist_ok=True)
    old = _read_state(state_dir)
    same_boot = old.get("boot_id") == boot_id
    failures = old.get("failures", 0) if same_boot else 0
    if same_boot and old.get("status") == "failed":
        print(_giving_up(failures, old.get("last_error", "unknown error")), file=sys.stderr)
        return 1
    attempts = old.get("attempts", 0) + 1
    if p.needs_secure_boot_off and secure_boot:
        _write_state(state_dir, p.profile, "waiting-for-secure-boot-off", attempts, failures, boot_id=boot_id)
        return EX_TEMPFAIL
    for cmd in p.commands:
        try:
            rc = runner(cmd)
            error = "" if rc == 0 else f"{' '.join(cmd)} exited with status {rc}"
        except OSError as e:
            error = f"cannot run {cmd[0]}: {_one_line(e)}"
        if error:
            failures += 1
            error = _one_line(error)
            if failures >= MAX_ATTEMPTS:
                _write_state(state_dir, p.profile, "failed", attempts, failures, error, boot_id)
                print(_giving_up(failures, error), file=sys.stderr)
                return 1
            _write_state(state_dir, p.profile, "pending", attempts, failures, error, boot_id)
            return EX_TEMPFAIL
    _write_state(state_dir, p.profile, "done", attempts)
    (state_dir / "hwroute.done").touch()
    return 0


def retry(state_dir: Path) -> int:
    """Give a failed (or pending) run a fresh budget: attempts and failures back to zero."""
    old = _read_state(state_dir)
    if old:
        (state_dir / "hw-profile.json").write_text(json.dumps(
            {"profile": old.get("profile", "generic"), "status": "pending", "attempts": 0, "failures": 0}))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="nisse-hwroute", description="Install the kernel and drivers this machine needs.")
    parser.add_argument("--dry-run", action="store_true", help="print the commands, run nothing, change no state")
    parser.add_argument("--state-dir", type=Path, default=STATE_DIR)
    parser.add_argument("--profiles", type=Path, default=None)
    parser.add_argument("--dmi-root", type=Path, default=DMI_ROOT)
    parser.add_argument("--pci-root", type=Path, default=PCI_ROOT)
    parser.add_argument("--efivars-root", type=Path, default=EFIVARS)
    parser.add_argument("--retry", action="store_true", help="forget earlier failed attempts and exit")
    args = parser.parse_args(argv)
    try:
        if args.retry:
            return retry(args.state_dir)
        return _run(args)
    except Exception as e:  # one line for the journal, never a traceback
        print(f"nisse-hwroute: {_one_line(e) or type(e).__name__}", file=sys.stderr)
        return 1


def _run(args: argparse.Namespace) -> int:
    profiles = args.profiles or (INSTALLED_PROFILES if INSTALLED_PROFILES.exists() else Path(__file__).with_name("profiles.toml"))
    profile = detect(read_dmi(args.dmi_root), read_pci_ids(args.pci_root))
    p = plan(profile, profiles)
    secure_boot = secure_boot_enabled(args.efivars_root)
    if args.dry_run:
        print(f"profile: {profile.value}", file=sys.stderr)
        if p.needs_secure_boot_off and secure_boot:
            print("note: Secure Boot is on; this kernel is not installed until it is turned off", file=sys.stderr)
        for cmd in p.commands:
            print(" ".join(cmd))
        return 0
    return execute(p, lambda cmd: subprocess.run(list(cmd)).returncode, args.state_dir, secure_boot)


if __name__ == "__main__":
    sys.exit(main())
