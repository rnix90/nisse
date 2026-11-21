# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the pieces of tools/vm/vmserver.py that need no VM (ledger N-310 found the problem the first one guards against).

An installed disk run on an overlay that lives on a network drive (the T: share the repo is on) is so slow that systemd gave up
starting ("Failed to start up manager") and the next boot reached only a kernel clock of 99 s in 420 s of waiting. The overlay
and the firmware variables belong on a local disk.
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import vmserver  # noqa: E402

DRIVE_REMOTE = 4
DRIVE_FIXED = 3


def test_a_unc_path_is_a_network_path():
    assert vmserver.is_network_path(r"\\nas\share\out\vm", drive_type=lambda root: DRIVE_FIXED)


def test_a_mapped_network_drive_is_a_network_path():
    assert vmserver.is_network_path(r"T:\Claude Code Creations\Nisse\out\vm", drive_type=lambda root: DRIVE_REMOTE)


def test_a_local_drive_is_not():
    assert not vmserver.is_network_path(r"C:\Users\x\AppData\Local\Temp\vm", drive_type=lambda root: DRIVE_FIXED)


def test_the_drive_type_is_asked_for_the_drive_root_of_the_path():
    asked = []
    vmserver.is_network_path(r"D:\nisse-build-vm\work", drive_type=lambda root: asked.append(root) or DRIVE_FIXED)
    assert asked == ["D:\\"]


def test_a_path_with_no_drive_letter_is_not_a_network_path_unless_it_is_unc():
    # posix style paths (the tests of other tools run on Linux too) have no drive to ask about
    assert not vmserver.is_network_path("/tmp/vm", drive_type=lambda root: DRIVE_REMOTE)


def test_serve_refuses_a_network_work_folder_with_a_message_that_says_why(tmp_path, monkeypatch):
    monkeypatch.setattr(vmserver, "is_network_path", lambda p, **kw: True)

    class Args:
        work = str(tmp_path / "vm")
        disk = "x"
        vars = "y"
        port = 1
        mem = 1
        resume = False

    with pytest.raises(SystemExit) as e:
        vmserver.serve(Args())
    assert "network" in str(e.value) and "local" in str(e.value)
    assert not (tmp_path / "vm").exists()   # nothing was created
