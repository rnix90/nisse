# SPDX-License-Identifier: GPL-2.0-or-later
"""Map a machine's DMI and PCI data to a Nisse hardware profile."""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Sequence

DMI_ROOT = Path("/sys/class/dmi/id")
PCI_ROOT = Path("/sys/bus/pci/devices")


@dataclass(frozen=True)
class DmiInfo:
    sys_vendor: str
    product_name: str
    product_family: str
    product_version: str


class Profile(str, Enum):
    GENERIC = "generic"
    SURFACE = "surface"
    APPLE_T2 = "apple-t2"
    APPLE_PRE_T2 = "apple-pre-t2"


# Intel MacBooks with the Apple T2 chip (2018-2020), the ones t2linux supports. Model identifiers follow
# Apple's list of T2 Macs (support.apple.com/103265) and t2linux.org; check both when a new model appears.
T2_MODELS = frozenset(
    {f"MacBookPro15,{n}" for n in (1, 2, 3, 4)}
    | {f"MacBookPro16,{n}" for n in (1, 2, 3, 4)}
    | {"MacBookAir8,1", "MacBookAir8,2", "MacBookAir9,1"}
)
# PCI IDs of the T2 bridge and secure enclave, as seen by lspci on a T2 Mac. Used when the model is not listed.
T2_PCI_IDS = frozenset({"106b:1801", "106b:1802"})

_MACBOOK = re.compile(r"^MacBook(Pro|Air)\d+,\d+$")


def _read(path: Path) -> str:
    try:
        return path.read_text(errors="replace").strip()
    except OSError:
        return ""


def read_dmi(root: Path = DMI_ROOT) -> DmiInfo:
    """Read the DMI fields we use. Missing files and directories give empty strings."""
    return DmiInfo(*(_read(root / name) for name in ("sys_vendor", "product_name", "product_family", "product_version")))


def read_pci_ids(root: Path = PCI_ROOT) -> frozenset[str]:
    """Return the "vvvv:dddd" IDs (lowercase hex) of every PCI device under `root`."""
    ids = set()
    try:
        devices = list(root.iterdir())
    except OSError:
        return frozenset()
    for dev in devices:
        vendor = _read(dev / "vendor").lower().removeprefix("0x")
        device = _read(dev / "device").lower().removeprefix("0x")
        if vendor and device:
            ids.add(f"{vendor}:{device}")
    return frozenset(ids)


def detect(dmi: DmiInfo, pci_ids: frozenset[str] = frozenset()) -> Profile:
    """Pick the profile for this machine. Anything unrecognised is GENERIC."""
    if dmi.sys_vendor == "Microsoft Corporation" and (
        dmi.product_family.startswith("Surface") or dmi.product_name.startswith("Surface")
    ):
        return Profile.SURFACE
    if dmi.sys_vendor == "Apple Inc." and _MACBOOK.match(dmi.product_name):
        if dmi.product_name in T2_MODELS or pci_ids & T2_PCI_IDS:
            return Profile.APPLE_T2
        return Profile.APPLE_PRE_T2
    return Profile.GENERIC


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m nisse_hw.detect", description="Print this machine's Nisse hardware profile.")
    parser.add_argument("--dmi-root", type=Path, default=DMI_ROOT)
    parser.add_argument("--pci-root", type=Path, default=PCI_ROOT)
    parser.add_argument("--json", action="store_true", help='print {"profile": ..., "dmi": {...}}')
    args = parser.parse_args(argv)

    info = read_dmi(args.dmi_root)
    profile = detect(info, read_pci_ids(args.pci_root))
    if args.json:
        print(json.dumps({"profile": profile.value, "dmi": asdict(info)}))
    else:
        print(profile.value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
