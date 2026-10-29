# SPDX-License-Identifier: GPL-2.0-or-later
import json
from pathlib import Path

import pytest

from nisse_hw.detect import Profile
from nisse_hw.route import Plan, execute, main, plan

PROFILES = Path(__file__).resolve().parents[1] / "nisse_hw" / "profiles.toml"
UNIT = Path(__file__).resolve().parents[2] / "packaging" / "rpm" / "nisse-hw" / "nisse-hwroute.service"
T2_REPO = "copr:copr.fedorainfracloud.org:sharpenedblade:t2linux"


def argv_strings(p: Plan) -> list[str]:
    return [" ".join(c) for c in p.commands]


def test_surface_adds_the_linux_surface_repo_and_installs_its_kernel():
    cmds = plan(Profile.SURFACE, PROFILES, release="44").commands
    assert ("dnf", "config-manager", "addrepo", "--overwrite",
            "--from-repofile=https://pkg.surfacelinux.com/fedora/linux-surface.repo") in cmds
    install = next(c for c in cmds if c[:2] == ("dnf", "install"))
    assert "kernel-surface" in install and "-y" in install


def test_t2_enables_the_t2linux_copr_and_swaps_in_its_kernel():
    p = plan(Profile.APPLE_T2, PROFILES, release="44")
    assert ("dnf", "copr", "enable", "-y", "sharpenedblade/t2linux") in p.commands
    swap = next(c for c in p.commands if c[:2] == ("dnf", "swap"))
    assert f"--from-repo={T2_REPO}" in swap and swap[-2:] == ("kernel", "kernel")
    assert any("Secure Boot" in n for n in p.notes)


def test_pre_t2_installs_the_broadcom_wifi_driver_and_never_a_kernel():
    p = plan(Profile.APPLE_PRE_T2, PROFILES, release="44")
    text = argv_strings(p)
    assert any("rpmfusion-nonfree-release-44.noarch.rpm" in c for c in text)
    assert "dnf install -y broadcom-wl" in text
    assert not any("kernel" in c for c in text)


def test_generic_has_no_commands():
    assert plan(Profile.GENERIC, PROFILES, release="44").commands == ()


def test_release_defaults_to_os_release_or_44(monkeypatch):
    p = plan(Profile.APPLE_PRE_T2, PROFILES)
    assert any("rpmfusion-nonfree-release-" in c for c in argv_strings(p))


def test_execute_success_marks_done(tmp_path):
    p = plan(Profile.SURFACE, PROFILES, release="44")
    calls = []
    assert execute(p, lambda argv: calls.append(tuple(argv)) or 0, tmp_path) == 0
    state = json.loads((tmp_path / "hw-profile.json").read_text())
    assert state == {"profile": "surface", "status": "done", "attempts": 1}
    assert (tmp_path / "hwroute.done").exists()
    assert tuple(calls) == p.commands


def test_execute_offline_is_pending_and_retries_later(tmp_path):
    p = plan(Profile.SURFACE, PROFILES, release="44")
    assert execute(p, lambda argv: 1, tmp_path) == 75
    state = json.loads((tmp_path / "hw-profile.json").read_text())
    assert state["status"] == "pending" and state["attempts"] == 1
    assert not (tmp_path / "hwroute.done").exists()
    assert execute(p, lambda argv: 1, tmp_path) == 75
    assert json.loads((tmp_path / "hw-profile.json").read_text())["attempts"] == 2
    assert execute(p, lambda argv: 0, tmp_path) == 0
    assert json.loads((tmp_path / "hw-profile.json").read_text())["status"] == "done"


def test_execute_stops_at_the_first_failing_command(tmp_path):
    p = plan(Profile.SURFACE, PROFILES, release="44")
    calls = []
    execute(p, lambda argv: calls.append(argv) or 1, tmp_path)
    assert len(calls) == 1


def test_execute_generic_is_done_without_running_anything(tmp_path):
    p = plan(Profile.GENERIC, PROFILES, release="44")
    assert execute(p, lambda argv: pytest.fail("runner must not be called"), tmp_path) == 0
    assert json.loads((tmp_path / "hw-profile.json").read_text())["status"] == "done"
    assert (tmp_path / "hwroute.done").exists()


def test_execute_creates_the_state_directory(tmp_path):
    state = tmp_path / "var" / "lib" / "nisse"
    execute(plan(Profile.GENERIC, PROFILES, release="44"), lambda argv: 0, state)
    assert (state / "hw-profile.json").exists()


def test_cli_dry_run_prints_one_command_per_line(tmp_path, capsys):
    dmi = tmp_path / "dmi"
    dmi.mkdir()
    (dmi / "sys_vendor").write_text("Microsoft Corporation\n")
    (dmi / "product_name").write_text("Surface Go\n")
    rc = main(["--dry-run", "--dmi-root", str(dmi), "--pci-root", str(tmp_path / "none"),
               "--profiles", str(PROFILES), "--state-dir", str(tmp_path / "state")])
    out = capsys.readouterr().out.splitlines()
    assert rc == 0
    assert out[0].startswith("dnf config-manager addrepo") and any("kernel-surface" in line for line in out)
    assert not (tmp_path / "state").exists()


def unit_sections(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current = ""
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections[current] = []
        elif line and current:
            sections[current].append(line)
    return sections


def test_service_unit_skips_live_sessions_and_retries_until_done():
    sections = unit_sections(UNIT.read_text())
    for line in ("ConditionPathExists=!/var/lib/nisse/hwroute.done", "ConditionKernelCommandLine=!rd.live.image",
                 "After=network-online.target", "StartLimitIntervalSec=0"):
        assert line in sections["Unit"], line
    for line in ("Type=oneshot", "Restart=on-failure", "RestartSec=300", "RestartForceExitStatus=75"):
        assert line in sections["Service"], line
    assert "StartLimitIntervalSec=0" not in sections["Service"], "systemd ignores it in [Service]"
