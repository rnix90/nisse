# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the unattended install-to-disk harness (ledger N-303) that need no VM: the answer file, the steps, the checks."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import install_disk  # noqa: E402


def test_the_password_is_random_per_run_and_never_a_fixed_value():
    a, b = install_disk.new_password(), install_disk.new_password()
    assert a != b
    assert len(a) >= 16 and a.isalnum()


def test_the_answer_file_installs_from_the_isos_own_root_image_because_the_live_installer_ignores_kickstart():
    ks = install_disk.kickstart("tester", "pw12345678901234")
    # anaconda --liveinst never reads a kickstart (startup_utils: "options.ksfile and not options.liveinst"), so the answer
    # file uses the liveimg payload on the root image the ISO already carries
    assert "liveimg --url=file:///run/initramfs/live/LiveOS/squashfs.img" in ks
    assert "--liveinst" not in ks


def test_the_answer_file_partitions_automatically_so_the_installed_layout_comes_from_the_product_profile():
    ks = install_disk.kickstart("tester", "pw12345678901234")
    lines = ks.splitlines()
    assert "autopart" in lines                       # no --type: the scheme is the profile's (N-301, N-304)
    assert "zerombr" in lines and "clearpart --all --initlabel" in lines


def test_the_answer_file_gives_the_installed_system_a_serial_console_and_a_login_the_harness_can_use():
    ks = install_disk.kickstart("tester", "pw12345678901234")
    assert 'bootloader --append="console=ttyS0"' in ks
    assert "user --name=tester --groups=wheel --password=pw12345678901234 --plaintext" in ks
    assert "rootpw --lock" in ks


def test_the_install_powers_the_machine_off_when_done_so_the_harness_can_boot_the_disk_next():
    ks = install_disk.kickstart("tester", "pw12345678901234")
    assert ks.rstrip().endswith("poweroff")


def test_the_answer_file_is_ascii_and_carries_no_stored_secret():
    ks = install_disk.kickstart("tester", "pw12345678901234")
    ks.encode("ascii")
    src = Path(install_disk.__file__).read_text()
    assert "spike-throwaway" not in src


def test_a_user_name_with_odd_characters_is_refused():
    with pytest.raises(ValueError):
        install_disk.kickstart("bad name; rm", "pw12345678901234")


def test_a_failed_install_is_recognised_from_the_output():
    assert install_disk.install_failed("The installation was stopped due to an error which occurred while running")
    assert install_disk.install_failed("Traceback (most recent call last):")
    assert install_disk.install_failed("The exact error message is: gen_grub_cfgstub script failed.")
    assert install_disk.install_failed("The installer will now terminate.")
    assert not install_disk.install_failed("Installing software 40%")


def test_the_checks_for_the_installed_system_name_what_must_be_true():
    names = [c.name for c in install_disk.CHECKS]
    for want in ("os-release", "root-filesystem", "bootloader", "login-target", "user"):
        assert want in names


def test_the_installer_command_runs_cmdline_mode_under_a_session_bus_with_the_answer_file():
    cmd = install_disk.anaconda_command()
    assert "dbus-run-session -- anaconda --cmdline --kickstart=/tmp/ks.cfg" in cmd
    assert "--liveinst" not in cmd and "--profile" not in cmd


def test_a_profile_can_be_forced_because_the_nisse_profile_does_not_exist_yet():
    # nisse's os-release ID matches no Anaconda profile, so the boot loader step looks in EFI/default and fails (N-303
    # spike, found in the installer log). Until N-304 ships the nisse profile the harness forces Fedora's.
    cmd = install_disk.anaconda_command(profile="fedora")
    assert "--profile fedora" in cmd


def test_a_profile_name_is_checked_before_it_reaches_a_shell():
    with pytest.raises(ValueError):
        install_disk.anaconda_command(profile="fedora; reboot")


class FakeVm:
    def __init__(self, outputs):
        self.outputs = list(outputs)
        self.commands = []

    def run(self, cmd, timeout=60):
        self.commands.append(cmd)
        return self.outputs.pop(0)


def test_a_check_that_needs_root_runs_through_sudo_and_never_shows_the_password():
    check = next(c for c in install_disk.CHECKS if c.name == "bootloader")
    vm = FakeVm([("sudo password echo pw12345678901234 EFI\nfedora\n", 0)])
    ok, output = install_disk.run_check(vm, check, "tester", "pw12345678901234")
    assert ok
    assert "sudo -S" in vm.commands[0] and "pw12345678901234" in vm.commands[0]
    assert "pw12345678901234" not in output


def test_a_failing_check_reports_failure_with_its_output_after_its_retry_time():
    check = install_disk.Check("x", "true", r"^never$", "w", retry=0)
    ok, output = install_disk.run_check(FakeVm([("nope\n", 0)]), check, "tester", "pw12345678901234")
    assert not ok and output == "nope"


def test_a_slow_service_gets_retried_until_it_is_up(monkeypatch):
    check = install_disk.Check("x", "systemctl is-active y", r"(?m)^active$", "w", retry=60)
    vm = FakeVm([("activating\n", 3), ("active\n", 0)])
    monkeypatch.setattr(install_disk.time, "sleep", lambda s: None)
    ok, _ = install_disk.run_check(vm, check, "tester", "pw12345678901234")
    assert ok and len(vm.commands) == 2


def test_the_answer_file_asks_for_a_graphical_login_because_the_installer_left_the_text_target_without_it():
    # N-303 run: the image's default target is graphical.target, but after a kickstart liveimg install the installed system
    # came up in multi-user.target (display manager never started) until the answer file said xconfig --startxonboot.
    assert "xconfig --startxonboot" in install_disk.kickstart("tester", "pw12345678901234").splitlines()
