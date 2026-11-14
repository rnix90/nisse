# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the lowercase-name checker and fixer (ledger N-115): the product name is printed as lowercase 'nisse'."""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import lowercase_name as ln  # noqa: E402

CAP = "Nis" + "se"  # spelled in pieces so this file never trips the checker itself


def test_a_standalone_capital_name_is_fixed():
    assert ln.fix_text(f"Ask {CAP}...") == "Ask nisse..."
    assert ln.fix_text(f"{CAP} is a distro") == "nisse is a distro"
    assert ln.fix_text(f'title: "{CAP}"') == 'title: "nisse"'
    assert ln.fix_text(f"{CAP}'s panel and {CAP}.") == "nisse's panel and nisse."


def test_identifiers_and_paths_a_system_fixes_are_kept():
    keep = [
        f"{CAP}.kiwi", f"{CAP}.Panel", f"{CAP}.profile", f"{CAP}-Live",
        f"T:\\Claude Code Creations\\{CAP}", f"/t/Claude Code Creations/{CAP}", f"{CAP}/docs",
        f'<image name="{CAP}" arch="x86_64">', f"URI {CAP}.Panel",
    ]
    for s in keep:
        assert ln.fix_text(s) == s, s


def test_the_iso_volume_label_is_lowercase_because_the_launcher_shows_it():
    # the live ISO shows up under Places in the launcher with its volume label (seen in the N-115 live check)
    assert ln.fix_text(f'volid="{CAP}-@PRODUCT@"') == 'volid="nisse-@PRODUCT@"'
    assert ln.fix_text(f"root=live:CDLABEL={CAP}-$release ") == "root=live:CDLABEL=nisse-$release "
    assert ln.fix_text(f"Volume Id : {CAP}-0.2") == "Volume Id : nisse-0.2"


def test_a_displayname_next_to_a_kept_name_is_still_fixed():
    assert ln.fix_text(f'<image name="{CAP}" displayname="{CAP}">') == f'<image name="{CAP}" displayname="nisse">'


def test_longer_identifiers_and_other_cases_are_left_alone():
    for s in (f"{CAP}Ember", f"{CAP}EmberLight", "NISSE", "nisse", "nisse_hw", "org.nisse.desktop"):
        assert ln.fix_text(s) == s, s


def test_fixing_twice_changes_nothing_more():
    once = ln.fix_text(f"{CAP} and {CAP}.kiwi and {CAP} Light")
    assert ln.fix_text(once) == once


def test_find_reports_line_numbers_and_the_line():
    hits = ln.find_text(f"fine\nAsk {CAP}\nkeep {CAP}.kiwi\n{CAP}\n")
    assert [(n, line) for n, line in hits] == [(2, f"Ask {CAP}"), (4, CAP)]


def test_the_ledger_entry_that_describes_the_sweep_is_exempt_but_other_lines_are_not():
    entry = f"- [ ] **N-115** `[build]` **Print the name as lowercase.** the looks (\"{CAP}\", \"{CAP} Light\")"
    other = f"- [ ] **N-114** `[gate]` the {CAP} and {CAP} Light looks listed"
    assert ln.find_text(entry) == []
    assert len(ln.find_text(other)) == 1
    done = entry.replace("[ ]", "[x]")
    assert ln.find_text(done) == []


def _repo(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    return tmp_path


def test_check_lists_tracked_files_with_a_capital_name_and_fix_clears_them(tmp_path, capsys):
    root = _repo(tmp_path)
    (root / "a.md").write_text(f"hello {CAP}\n", encoding="utf-8")
    (root / "b.md").write_text("fine\n", encoding="utf-8")
    (root / "c.bin").write_bytes(b"\x00\x01" + CAP.encode())
    (root / "untracked.md").write_text(f"{CAP}\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(root), "add", "a.md", "b.md", "c.bin"], check=True)
    assert ln.main(["check", "--root", str(root)]) == 1
    out = capsys.readouterr().out
    assert "a.md:1" in out and "b.md" not in out and "c.bin" not in out and "untracked" not in out
    assert ln.main(["fix", "--root", str(root)]) == 0
    assert (root / "a.md").read_text(encoding="utf-8") == "hello nisse\n"
    assert (root / "untracked.md").read_text(encoding="utf-8") == f"{CAP}\n"
    assert ln.main(["check", "--root", str(root)]) == 0


def test_fix_keeps_line_endings_and_skips_files_that_are_not_utf8(tmp_path):
    root = _repo(tmp_path)
    (root / "crlf.txt").write_bytes(f"{CAP}\r\nline\r\n".encode())
    (root / "latin.txt").write_bytes(b"caf\xe9 " + CAP.encode())
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    assert ln.main(["fix", "--root", str(root)]) == 0
    assert (root / "crlf.txt").read_bytes() == b"nisse\r\nline\r\n"
    assert (root / "latin.txt").read_bytes() == b"caf\xe9 " + CAP.encode()


def test_the_checker_and_its_own_tests_are_exempt_by_path(tmp_path):
    root = _repo(tmp_path)
    for rel in ("tools/repo/lowercase_name.py", "tools/repo/tests/test_lowercase_name.py"):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f"{CAP}\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    assert ln.main(["check", "--root", str(root)]) == 0
