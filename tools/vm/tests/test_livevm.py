# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the live-session environment import (ledger N-114 finding): apps the harness starts from the serial shell
must see the same XDG paths as the Plasma session, or they miss the system defaults (the terminal profile, for one)."""
import base64
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import livevm  # noqa: E402

ENVIRON = (
    b"HOME=/home/liveuser\0PATH=/usr/bin\0SECRET_TOKEN=abc\0"
    b"XDG_CONFIG_DIRS=/home/liveuser/.config/kdedefaults:/etc/xdg:/usr/share/kde-settings/kde-profile/default/xdg\0"
    b"XDG_CURRENT_DESKTOP=KDE\0DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus\0WAYLAND_DISPLAY=wayland-0\0"
    b"KDE_SESSION_VERSION=6\0QT_QPA_PLATFORM=wayland\0LANG=en_US.UTF-8\0WITH SPACE=a b\0XDG_BAD=it's quoted\0NOEQUALS\0"
)


def test_session_variables_are_exported_and_others_are_not():
    script = livevm.env_script_from_environ(ENVIRON)
    assert "export XDG_CONFIG_DIRS=/home/liveuser/.config/kdedefaults:/etc/xdg:/usr/share/kde-settings/kde-profile/default/xdg" in script
    for key in ("XDG_CURRENT_DESKTOP", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "KDE_SESSION_VERSION", "QT_QPA_PLATFORM", "LANG"):
        assert f"export {key}=" in script, key
    for key in ("HOME", "PATH", "SECRET_TOKEN", "NOEQUALS"):
        assert key not in script, key


def test_values_are_shell_quoted():
    script = livevm.env_script_from_environ(ENVIRON)
    assert "export XDG_BAD='it'\"'\"'s quoted'" in script


def test_an_empty_or_garbled_environment_gives_an_empty_script():
    assert livevm.env_script_from_environ(b"") == ""
    assert livevm.env_script_from_environ(b"\0\0") == ""


def test_the_base64_blob_is_found_among_console_echo_and_noise():
    blob = base64.b64encode(ENVIRON).decode()
    console = f"[liveuser@host ~]$ base64 -w0 /proc/12/environ\n{blob}\n__D123456__0__\n"
    assert livevm.pick_base64(console) == ENVIRON
    assert livevm.pick_base64("nothing here\n") == b""


def test_the_vm_clock_starts_at_a_fixed_night_time_so_night_light_looks_the_same_on_every_run():
    cmd = livevm.qemu_command("x.iso", "vars.fd", 20001, 20000, 6144)
    i = cmd.index("-rtc")
    assert cmd[i + 1] == f"base={livevm.RTC_BASE},clock=vm"
    assert livevm.RTC_BASE.endswith("T03:00:00")  # night in UTC, which is the live session's time zone
    assert "x.iso" in cmd and "-display" in cmd and cmd[cmd.index("-display") + 1] == "none"


def test_a_different_start_time_can_be_given():
    cmd = livevm.qemu_command("x.iso", "vars.fd", 1, 2, 4096, rtc_base="2026-06-21T13:00:00")
    assert cmd[cmd.index("-rtc") + 1] == "base=2026-06-21T13:00:00,clock=vm"


def test_the_fallback_environment_still_exists_for_a_session_that_has_no_plasmashell_yet():
    assert "XDG_RUNTIME_DIR" in livevm.SESSION_ENV and "WAYLAND_DISPLAY" in livevm.SESSION_ENV


def test_a_target_disk_is_attached_as_a_virtio_drive_after_the_firmware_and_the_iso():
    cmd = livevm.qemu_command("x.iso", "vars.fd", 1, 2, 4096, disks=["D:/t/target.qcow2"])
    drives = [cmd[i + 1] for i, a in enumerate(cmd) if a == "-drive"]
    disk = [d for d in drives if "target.qcow2" in d]
    assert len(disk) == 1 and "if=virtio" in disk[0] and "format=qcow2" in disk[0]
    assert cmd.index("-cdrom") < cmd.index("-drive", cmd.index("-cdrom"))
    assert "-cdrom" in cmd and cmd[cmd.index("-boot") + 1] == "d"


def test_with_no_iso_the_machine_boots_from_its_disk_alone():
    cmd = livevm.qemu_command(None, "vars.fd", 1, 2, 4096, disks=["D:/t/target.qcow2"])
    assert "-cdrom" not in cmd
    assert cmd[cmd.index("-boot") + 1] == "c"
    assert any("target.qcow2" in a for a in cmd)


def test_no_disks_keeps_the_old_command_line():
    old = livevm.qemu_command("x.iso", "vars.fd", 1, 2, 4096)
    assert not any("qcow2" in a for a in old)


def test_extra_qemu_arguments_go_last_and_by_default_there_are_none():
    base = livevm.qemu_command("x.iso", "vars.fd", 1, 2, 4096)
    more = livevm.qemu_command("x.iso", "vars.fd", 1, 2, 4096, extra_args=["-device", "usb-serial,id=u0"])
    assert more[: len(base)] == base
    assert more[len(base):] == ["-device", "usb-serial,id=u0"]
