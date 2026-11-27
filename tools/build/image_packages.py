#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""N-508: which packages will the ISO hold? Answered without building it.

Reads the kiwi description the way kiwi does (the profile and the profiles it requires, every <packages> list for them, Fedora package
groups, <ignore> lines), then runs the same dnf5 install kiwi runs, as a dry run in an empty root (the sibling of
tools/rpm/check-installable.sh), and reads the transaction table. kiwi turns an <ignore> into dnf's --exclude, so a package that
something hard-requires cannot be dropped: the dry run fails and names it.

Run in the Fedora build VM, after tools/rpm/make-repo.sh and build/render-kiwi.sh:

    python3 tools/build/image_packages.py [--description out/kiwi-description] [--profile Nisse-Live] [--out out/image-packages.txt]

Writes one package name per line (sorted). Exit 0 on success, 1 when the solver fails (the problem is printed), 2 on a bad command line.
"""
import argparse
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

TYPES = ("bootstrap", "image", "iso")
ROOT = Path(__file__).resolve().parents[2]


class SolverError(Exception):
    """dnf could not solve the install (or printed something that is not a transaction)."""


@dataclass
class Selection:
    packages: list = field(default_factory=list)
    groups: list = field(default_factory=list)
    ignores: list = field(default_factory=list)


def _documents(description):
    """The top-level file and every file it <include>s, parsed."""
    description = Path(description)
    top = ET.parse(description / "Nisse.kiwi").getroot()
    docs = [top]
    for inc in top.findall("include"):
        rel = inc.get("from", "")
        rel = rel[len("this://"):] if rel.startswith("this://") else rel
        docs.append(ET.parse(description / rel).getroot())
    return docs


def _arch_ok(element, arch):
    wanted = element.get("arch")
    return wanted is None or arch in [a.strip() for a in wanted.split(",")]


def _profile_closure(docs, profile):
    requires = {}
    for doc in docs:
        for p in doc.iter("profile"):
            requires[p.get("name")] = [r.get("profile") for r in p.findall("requires")]
    if profile not in requires:
        raise SystemExit(f"no profile {profile} in the description")
    seen, todo = [], [profile]
    while todo:
        name = todo.pop()
        if name not in seen:
            seen.append(name)
            todo.extend(requires.get(name, []))
    return seen


def load(description, profile, arch="x86_64"):
    docs = _documents(description)
    selected = set(_profile_closure(docs, profile))
    sel = Selection()

    def add(target, name):
        if name not in target:
            target.append(name)

    for doc in docs:
        for lst in doc.iter("packages"):
            if lst.get("type") not in TYPES or not _arch_ok(lst, arch):
                continue
            profiles = lst.get("profiles")
            if profiles is not None and not selected & {p.strip() for p in profiles.split(",")}:
                continue
            for child in lst:
                if not _arch_ok(child, arch):
                    continue
                if child.tag == "package":
                    add(sel.packages, child.get("name"))
                elif child.tag == "namedCollection":
                    add(sel.groups, child.get("name"))
                elif child.tag == "ignore":
                    add(sel.ignores, child.get("name"))
    return sel


def dnf_command(sel, root, release, repo):
    cmd = ["sudo", "dnf", "install", "--assumeno", "--use-host-config", f"--installroot={root}", f"--releasever={release}",
           "--disablerepo=*", "--enablerepo=fedora", f"--repofrompath=nisse,file://{repo}", "--setopt=nisse.gpgcheck=0",
           "--setopt=nisse.priority=90",
           # patternType="plusRecommended", as kiwi's dnf5 backend sets it
           "--setopt=install_weak_deps=True", "--setopt=group_package_types=default,mandatory,conditional"]
    cmd += [f"--exclude={name}" for name in sel.ignores]
    return cmd + sel.packages + [f"@{g}" for g in sel.groups]


FAILURE = re.compile(r"Failed to resolve|Problem|nothing provides|conflicting requests|cannot install|No match for argument")
ROW = re.compile(r"^ (\S+)\s+(\w+)\s+\d+:\S+\s+\S+\s+[\d.]+ \S*B\s*$")


def parse_transaction(text):
    """The sorted package names of the transaction table; SolverError when dnf failed."""
    # one "matches only excluded packages" notice per <ignore> is dnf talking about our drops, not a failure, and would bury the problem
    lines = [line for line in text.splitlines() if not line.startswith("Argument '")]
    if any(FAILURE.search(line) for line in lines):
        start = next(i for i, line in enumerate(lines) if FAILURE.search(line))
        raise SolverError("\n".join(lines[start:start + 60]))
    if not any(line.startswith("Transaction Summary") for line in lines):
        raise SolverError("dnf printed no transaction:\n" + "\n".join(lines[-8:]))
    return sorted({m.group(1) for m in map(ROW.match, lines) if m})


SIZE = re.compile(r"^ \S+\s+\w+\s+\d+:\S+\s+\S+\s+([\d.]+) (B|KiB|MiB|GiB)\s*$")
UNITS = {"B": 1 / 1024 / 1024, "KiB": 1 / 1024, "MiB": 1.0, "GiB": 1024.0}


def download_mib(text):
    """The sum of the package sizes in the transaction table, in MiB (what the ISO's packages weigh before they are compressed)."""
    return sum(float(m.group(1)) * UNITS[m.group(2)] for m in map(SIZE.match, text.splitlines()) if m)


def blocked_names(error_text, dropped):
    """Of the packages we tried to drop, the ones the solver's complaint mentions (what still needs them)."""
    text = "\n".join(line for line in error_text.splitlines() if not line.startswith(("Argument '", "No match for argument")))
    return [name for name in dropped
            if re.search(r"(?<![\w.+-])" + re.escape(name) + r"(?![\w.+]|-[A-Za-z])", text)]


def resolve(description, profile, repo, release, arch="x86_64"):
    sel = load(description, profile, arch)
    with tempfile.TemporaryDirectory() as root:
        cmd = dnf_command(sel, root, release, repo)
        done = subprocess.run(cmd, capture_output=True, text=True)       # --assumeno always exits 1; the text is the answer
        try:
            text = done.stdout + done.stderr
            return sel, parse_transaction(text), download_mib(text)
        except SolverError as e:
            blocked = blocked_names(str(e), sel.ignores)
            hint = f"\nthe dropped packages named above: {', '.join(blocked)}" if blocked else ""
            raise SolverError(str(e) + hint) from None
        finally:
            subprocess.run(["sudo", "rm", "-rf", root], capture_output=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--description", default=str(ROOT / "out" / "kiwi-description"))
    ap.add_argument("--profile", default="Nisse-Live")
    ap.add_argument("--repo", default=str(ROOT / "out" / "repo"))
    ap.add_argument("--out", default=str(ROOT / "out" / "image-packages.txt"))
    args = ap.parse_args(argv)
    release = (ROOT / "build" / "FEDORA_RELEASE").read_text().strip()
    try:
        _, names, mib = resolve(args.description, args.profile, args.repo, release)
    except SolverError as e:
        print("FAIL: the image's packages do not resolve:\n" + str(e), file=sys.stderr)
        return 1
    Path(args.out).write_text("\n".join(names) + "\n", encoding="ascii")
    print(f"{len(names)} packages, {mib:.0f} MiB of packages -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
