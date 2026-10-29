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


def _write_state(state_dir: Path, profile: Profile, status: str, attempts: int) -> None:
    (state_dir / "hw-profile.json").write_text(json.dumps({"profile": profile.value, "status": status, "attempts": attempts}))


def execute(p: Plan, runner: Callable[[Sequence[str]], int], state_dir: Path, secure_boot: bool = False) -> int:
    """Run the plan. Returns 0 when done, 75 (EX_TEMPFAIL) when a command failed and should be retried."""
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / "hw-profile.json"
    try:
        attempts = json.loads(state_file.read_text()).get("attempts", 0) + 1
    except (OSError, ValueError):
        attempts = 1
    if p.needs_secure_boot_off and secure_boot:
        _write_state(state_dir, p.profile, "waiting-for-secure-boot-off", attempts)
        return EX_TEMPFAIL
    for cmd in p.commands:
        if runner(cmd) != 0:
            _write_state(state_dir, p.profile, "pending", attempts)
            return EX_TEMPFAIL
    _write_state(state_dir, p.profile, "done", attempts)
    (state_dir / "hwroute.done").touch()
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="nisse-hwroute", description="Install the kernel and drivers this machine needs.")
    parser.add_argument("--dry-run", action="store_true", help="print the commands, run nothing, change no state")
    parser.add_argument("--state-dir", type=Path, default=STATE_DIR)
    parser.add_argument("--profiles", type=Path, default=None)
    parser.add_argument("--dmi-root", type=Path, default=DMI_ROOT)
    parser.add_argument("--pci-root", type=Path, default=PCI_ROOT)
    parser.add_argument("--efivars-root", type=Path, default=EFIVARS)
    args = parser.parse_args(argv)

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
