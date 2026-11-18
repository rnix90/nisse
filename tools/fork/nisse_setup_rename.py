#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-306d: the system-visible renames of the nisse-setup fork of Plasma Setup (forks/nisse-setup).

Decision (Bert, 2026-11-18): only names that are visible on an installed system change: the package and command, the systemd
service, the special user, the polkit rule and the privileged helper (KAuth domain and action ids), the flag file, the
display-manager autologin file and the config file. KDE's internal QML module URIs (`org.kde.plasmasetup...`), the C++ names and
the macro names stay, so that merging a newer upstream stays easy. The whole rename waits for a whole-Plasma fork.

Run from the repository root:  python tools/fork/nisse_setup_rename.py [--check]
It is idempotent: a second run changes nothing. Every replacement must match (or already be done), so a newer upstream that
moved a line makes the script fail loudly instead of silently missing a name. `--check` only reports what would change.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORK = ROOT / "forks" / "nisse-setup"

MOVES = [
    ("files/plasma-setup.service.in", "files/nisse-setup.service.in"),
    ("files/plasma-setup-polkit.rules", "files/nisse-setup-polkit.rules"),
    ("files/plasma-setup-sysuser.conf", "files/nisse-setup-sysuser.conf"),
    ("files/plasma-setup-tmpfiles.conf.in", "files/nisse-setup-tmpfiles.conf.in"),
    ("files/plasma-setup.desktop.in", "files/nisse-setup.desktop.in"),
    ("files/plasmasetuprc", "files/nissesetuprc"),
    ("src/auth/org.kde.plasmasetup.actions", "src/auth/org.nisse.setup.actions"),
]

# (path after the moves, [(old, new), ...]): every old text is replaced everywhere in the file
EDITS = {
    "files/CMakeLists.txt": [("plasma-setup", "nisse-setup"), ("plasmasetuprc", "nissesetuprc")],
    "files/nisse-setup.service.in": [
        ("Plasma Setup - Out-of-Box / First-Run setup wizard", "nisse setup - first-run wizard"),
        ("plasma-setup", "nisse-setup"),
    ],
    "files/nisse-setup-polkit.rules": [
        ("org.kde.plasmasetup.", "org.nisse.setup."),
        ("plasma-setup", "nisse-setup"),
        ("Plasma Setup", "nisse setup"),
    ],
    "files/nisse-setup-sysuser.conf": [("Plasma Setup", "nisse setup"), ("plasma-setup", "nisse-setup")],
    "files/nisse-setup-tmpfiles.conf.in": [("Plasma Setup", "nisse setup"), ("plasma-setup", "nisse-setup")],
    "files/nisse-setup.desktop.in": [
        ("Exec=${CMAKE_INSTALL_FULL_LIBEXECDIR}/plasma-setup", "Exec=${CMAKE_INSTALL_FULL_LIBEXECDIR}/nisse-setup"),
        ("\nName=Plasma Setup\n", "\nName=nisse setup\n"),
    ],
    "files/nissesetuprc": [("/etc/xdg/plasmasetuprc", "/etc/xdg/nissesetuprc"), ("Plasma Setup", "nisse setup")],
    "files/kglobalaccelrc": [("for the plasma-setup session", "for the nisse-setup session")],
    "config-plasma-setup.h.cmake": [("/plasma-setup-done", "/nisse-setup-done"), ("/plasmasetuprc", "/nissesetuprc")],
    "src/auth/CMakeLists.txt": [
        ("plasma-setup-auth-helper", "nisse-setup-auth-helper"),
        ("kauth_install_actions(org.kde.plasmasetup org.kde.plasmasetup.actions)", "kauth_install_actions(org.nisse.setup org.nisse.setup.actions)"),
        ("kauth_install_helper_files(nisse-setup-auth-helper org.kde.plasmasetup root)", "kauth_install_helper_files(nisse-setup-auth-helper org.nisse.setup root)"),
    ],
    "src/auth/org.nisse.setup.actions": [
        ("org.kde.plasmasetup", "org.nisse.setup"),
        ("/etc/plasma-setup-done", "/etc/nisse-setup-done"),
        ("\nName=Plasma Setup\n", "\nName=nisse setup\n"),
    ],
    "src/auth/authhelper.cpp": [
        ("/run/plasma-setup", "/run/nisse-setup"),
        ("99-plasma-setup.conf", "99-nisse-setup.conf"),
        ('KAUTH_HELPER_MAIN("org.kde.plasmasetup"', 'KAUTH_HELPER_MAIN("org.nisse.setup"'),
        ('QStringLiteral("/plasma-setup")', 'QStringLiteral("/nisse-setup")'),
        ("Plasma Setup completed at", "nisse setup completed at"),
    ],
    "src/auth/authhelper.h": [("/etc/plasma-setup-done", "/etc/nisse-setup-done")],
    "src/accountcontroller.cpp": [
        ('QStringLiteral("org.kde.plasmasetup.', 'QStringLiteral("org.nisse.setup.'),
        ('QStringLiteral("org.kde.plasmasetup"))', 'QStringLiteral("org.nisse.setup"))'),
    ],
    "src/displayutil.cpp": [
        ('QStringLiteral("org.kde.plasmasetup.', 'QStringLiteral("org.nisse.setup.'),
        ('QStringLiteral("org.kde.plasmasetup"))', 'QStringLiteral("org.nisse.setup"))'),
    ],
    "src/initialstartutil.cpp": [
        ('QStringLiteral("org.kde.plasmasetup.', 'QStringLiteral("org.nisse.setup.'),
        ('QStringLiteral("org.kde.plasmasetup"))', 'QStringLiteral("org.nisse.setup"))'),
        ('qgetenv("USER") == "plasma-setup"', 'qgetenv("USER") == "nisse-setup"'),
    ],
    "src/initialstartutil.h": [("/etc/plasma-setup-done", "/etc/nisse-setup-done")],
    "src/bootutil/CMakeLists.txt": [("plasma-setup-bootutil", "nisse-setup-bootutil")],
    "src/bootutil/bootutil.cpp": [("99-plasma-setup.conf", "99-nisse-setup.conf"), ("User=plasma-setup", "User=nisse-setup")],
    "src/bootutil/bootutil.h": [('"plasma-setup"', '"nisse-setup"')],
    "src/main.cpp": [('KAboutData about(QStringLiteral("plasma-setup")', 'KAboutData about(QStringLiteral("nisse-setup")')],
    "src/CMakeLists.txt": [
        ("add_executable(plasma-setup\n", "add_executable(nisse-setup\n"),
        ("ecm_add_qml_module(plasma-setup ", "ecm_add_qml_module(nisse-setup "),
        ("qt_target_qml_sources(plasma-setup\n", "qt_target_qml_sources(nisse-setup\n"),
        ("target_link_libraries(plasma-setup\n", "target_link_libraries(nisse-setup\n"),
        ("target_include_directories(plasma-setup ", "target_include_directories(nisse-setup "),
        ("install(TARGETS plasma-setup RUNTIME", "install(TARGETS nisse-setup RUNTIME"),
    ],
    "README.md": [
        ("sudo systemctl enable plasma-setup.service", "sudo systemctl enable nisse-setup.service"),
        ("/etc/plasma-setup-done", "/etc/nisse-setup-done"),
        ("/etc/xdg/plasmasetuprc", "/etc/xdg/nissesetuprc"),
    ],
}


def git(*args):
    subprocess.run(["git", *args], cwd=ROOT, check=True)


def main():
    check = "--check" in sys.argv
    problems = []
    for old, new in MOVES:
        src, dst = FORK / old, FORK / new
        if dst.exists() and not src.exists():
            continue
        if not src.exists():
            problems.append(f"missing {old}")
            continue
        print(("would move " if check else "move ") + f"{old} -> {new}")
        if not check:
            git("mv", str(src.relative_to(ROOT)), str(dst.relative_to(ROOT)))
    pending = {new: old for old, new in MOVES}   # with --check nothing moved yet: read a moved file from where it still is
    for rel, pairs in EDITS.items():
        path = FORK / rel
        if not path.exists() and check and rel in pending:
            path = FORK / pending[rel]
        if not path.exists():
            problems.append(f"missing {rel}")
            continue
        text = path.read_text(encoding="utf-8")
        crlf = "\r\n" in text
        text = text.replace("\r\n", "\n")
        changed = False
        for old, new in pairs:
            if old in text:
                text = text.replace(old, new)
                changed = True
            elif new in text:
                continue  # already done
            else:
                problems.append(f"{rel}: neither {old!r} nor {new!r} is there")
        if changed:
            print(("would edit " if check else "edit ") + rel)
            if not check:
                path.write_text(text.replace("\n", "\r\n") if crlf else text, encoding="utf-8", newline="")
    if problems:
        print("PROBLEMS:", *problems, sep="\n  ")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
