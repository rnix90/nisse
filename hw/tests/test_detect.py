# SPDX-License-Identifier: GPL-2.0-or-later
import json
from pathlib import Path

import pytest

from nisse_hw.detect import DmiInfo, Profile, detect, main, read_dmi, read_pci_ids


def dmi(vendor="", name="", family="", version=""):
    return DmiInfo(vendor, name, family, version)


def write_tree(root: Path, **files: str) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (root / name).write_text(text + "\n")
    return root


def test_surface_go_is_surface():
    assert detect(dmi("Microsoft Corporation", "Surface Go")) == Profile.SURFACE


def test_surface_laptop_family_is_surface():
    assert detect(dmi("Microsoft Corporation", "Laptop 4", family="Surface")) == Profile.SURFACE


@pytest.mark.parametrize("model", ["MacBookPro15,2", "MacBookAir8,1", "MacBookPro16,1", "MacBookAir9,1"])
def test_t2_macbooks(model):
    assert detect(dmi("Apple Inc.", model)) == Profile.APPLE_T2


@pytest.mark.parametrize("model", ["MacBookPro13,1", "MacBookAir7,2", "MacBookPro11,4"])
def test_pre_t2_macbooks_never_get_the_t2_profile(model):
    assert detect(dmi("Apple Inc.", model)) == Profile.APPLE_PRE_T2


def test_unlisted_apple_model_with_t2_pci_id_is_t2():
    assert detect(dmi("Apple Inc.", "MacBookPro99,9"), frozenset({"106b:1801"})) == Profile.APPLE_T2


def test_unlisted_apple_model_without_pci_id_is_pre_t2():
    assert detect(dmi("Apple Inc.", "MacBookPro99,9")) == Profile.APPLE_PRE_T2


def test_apple_desktop_is_generic():
    assert detect(dmi("Apple Inc.", "iMac12,1")) == Profile.GENERIC


@pytest.mark.parametrize(
    "info",
    [
        dmi(),
        dmi("To Be Filled By O.E.M.", "To Be Filled By O.E.M."),
        dmi("QEMU", "Standard PC (Q35 + ICH9, 2009)"),
        dmi("Apple Inc.", ""),
        dmi("Microsoft Corporation", "Virtual Machine"),
        dmi("\x00\x00", "\x01 junk"),
    ],
)
def test_blank_or_junk_dmi_is_generic(info):
    assert detect(info) == Profile.GENERIC


def test_read_dmi_with_missing_files_gives_empty_strings(tmp_path):
    root = write_tree(tmp_path / "dmi", sys_vendor="Microsoft Corporation")
    assert read_dmi(root) == DmiInfo("Microsoft Corporation", "", "", "")


def test_read_dmi_on_nonexistent_directory_is_all_empty(tmp_path):
    assert read_dmi(tmp_path / "nope") == DmiInfo("", "", "", "")


def test_read_pci_ids_lowercases_and_strips_0x(tmp_path):
    # Real device directories are PCI addresses with colons, which Windows cannot create; any name works here.
    for name, (ven, dev) in {"dev-a": ("0x106B", "0x1801"), "dev-b": ("0x10de", "0x2204")}.items():
        write_tree(tmp_path / "pci" / name, vendor=ven, device=dev)
    assert read_pci_ids(tmp_path / "pci") == frozenset({"106b:1801", "10de:2204"})


def test_read_pci_ids_on_nonexistent_directory_is_empty(tmp_path):
    assert read_pci_ids(tmp_path / "nope") == frozenset()


def test_cli_prints_the_profile_name(tmp_path, capsys):
    dmi_root = write_tree(tmp_path / "dmi", sys_vendor="Microsoft Corporation", product_name="Surface Go")
    assert main(["--dmi-root", str(dmi_root), "--pci-root", str(tmp_path / "none")]) == 0
    assert capsys.readouterr().out == "surface\n"


def test_cli_json_includes_profile_and_dmi(tmp_path, capsys):
    dmi_root = write_tree(tmp_path / "dmi", sys_vendor="Apple Inc.", product_name="MacBookPro15,2")
    main(["--dmi-root", str(dmi_root), "--pci-root", str(tmp_path / "none"), "--json"])
    out = json.loads(capsys.readouterr().out)
    assert out["profile"] == "apple-t2"
    assert out["dmi"]["product_name"] == "MacBookPro15,2"
