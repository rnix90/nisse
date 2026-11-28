# SPDX-License-Identifier: GPL-2.0-or-later
"""N-514: the udev rules for development boards (packaging/rpm/nisse-devtools/60-nisse-boards.rules, docs/dev-toolchain.md).

Whoever is at the screen gets access to a board the moment it is plugged in (the uaccess tag), and ModemManager leaves it alone (it would
otherwise probe a serial board as if it were a modem, which breaks flashing). The IDs are checked against the families of the doc."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RULES = ROOT / "packaging/rpm/nisse-devtools/60-nisse-boards.rules"
DOC = ROOT / "docs/dev-toolchain.md"

# family -> (whole vendors, exact vendor:product pairs); every ID was found in PlatformIO's upstream udev rules and Fedora's usb.ids (N-514 notes)
FAMILIES = {
    "ESP32": ({"303a"}, set()),
    "Arduino": ({"2341", "2a03", "239a"}, set()),
    "Raspberry Pi Pico": ({"2e8a"}, set()),
    "STM32 and ST-Link": ({"0483"}, set()),
    "J-Link": ({"1366"}, set()),
    "serial bridges": (set(), {("10c4", "ea60"), ("1a86", "7523"), ("1a86", "55d3"), ("1a86", "55d4"), ("0403", "6001"), ("0403", "6010"),
                               ("0403", "6011"), ("0403", "6014"), ("0403", "6015")}),
}

LINE = re.compile(r'^SUBSYSTEMS=="usb", ATTRS\{idVendor\}=="([0-9a-f]{4})"(?:, ATTRS\{idProduct\}=="([0-9a-f]{4})")?, (.*)$')


def rules():
    out = []
    for n, line in enumerate(RULES.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        m = LINE.match(line)
        assert m, f"line {n} is not one of the shapes this file uses: {line}"
        out.append((m.group(1), m.group(2), m.group(3), n))
    return out


def test_every_rule_gives_access_to_the_person_at_the_screen_and_keeps_modemmanager_off():
    assert rules(), "no rules"
    for vendor, product, rest, n in rules():
        assert 'TAG+="uaccess"' in rest, f"line {n} does not tag the device for the person at the screen"
        assert 'ENV{ID_MM_DEVICE_IGNORE}="1"' in rest, f"line {n} does not tell ModemManager to ignore the device"
        assert 'ENV{ID_MM_PORT_IGNORE}="1"' in rest, f"line {n} does not tell ModemManager to ignore its ports"


def test_no_rule_opens_a_device_to_everybody():
    text = RULES.read_text()
    assert "MODE=" not in text and "MODE:=" not in text, "a mode would open the device to more than uaccess and the dialout group"
    assert "GROUP=" not in text, "the group of a serial port is Fedora's (dialout), the uaccess tag adds the person at the screen"


def test_each_family_is_covered_by_vendor_or_by_exact_ids():
    vendors = {v for v, p, _, _ in rules() if p is None}
    pairs = {(v, p) for v, p, _, _ in rules() if p is not None}
    for family, (want_vendors, want_pairs) in FAMILIES.items():
        for v in want_vendors:
            assert v in vendors, f"{family}: vendor {v} is not matched"
        for pair in want_pairs:
            assert pair in pairs or pair[0] in vendors, f"{family}: {pair} is not matched"


def test_nothing_else_is_matched():
    vendors = {v for v, p, _, _ in rules() if p is None}
    pairs = {(v, p) for v, p, _, _ in rules() if p is not None}
    want_vendors = set().union(*(f[0] for f in FAMILIES.values()))
    want_pairs = set().union(*(f[1] for f in FAMILIES.values()))
    assert vendors == want_vendors, f"unexpected whole vendors: {vendors ^ want_vendors}"
    assert pairs == want_pairs, f"unexpected device IDs: {pairs ^ want_pairs}"


def test_the_doc_lists_every_id_the_rules_match():
    doc = DOC.read_text().lower()
    for vendor, product, _, n in rules():
        assert vendor in doc, f"vendor {vendor} (rules line {n}) is not in docs/dev-toolchain.md"
        if product:
            assert f"{vendor}:{product}" in doc, f"{vendor}:{product} (rules line {n}) is not in docs/dev-toolchain.md"


def test_the_wizard_puts_the_first_user_in_dialout():
    rc = (ROOT / "forks/nisse-setup/files/nissesetuprc").read_text()
    groups = [l for l in rc.splitlines() if l.startswith("UserGroups=")]
    assert groups, "no UserGroups line"
    assert "dialout" in groups[0].split("=", 1)[1].split(","), groups[0]
    assert "wheel" in groups[0].split("=", 1)[1].split(","), "the sudo policy is for wheel: " + groups[0]
