# SPDX-License-Identifier: GPL-2.0-or-later
"""Keep the product name lowercase (ledger N-115): Bert wants it printed as "nisse" wherever possible.

  python tools/repo/lowercase_name.py check   list tracked text files that still print a capital name; exit 1 if any
  python tools/repo/lowercase_name.py fix     rewrite them

What stays capitalised because a system fixes it: file and QML names that continue after the name (Nisse.kiwi,
Nisse.Panel, Nisse.profile), the kiwi profile Nisse-Live, a path that ends in or
passes through a Nisse folder, a kiwi name="Nisse" attribute (the displayname next to it is fixed), and longer
identifiers such as NisseEmber. The ledger entry that describes this sweep quotes the old capital form and is exempt.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# a capital name that is a word on its own, not part of a path, a dotted or hyphenated identifier or a longer word
PATTERN = re.compile(r'(?<![\w/\\.@])(?<!\sname=")Nisse(?!\w|\.[A-Za-z]|-Live|[/\\])')
EXEMPT_LINE = re.compile(r"^- \[.\] \*\*N-115\*\*")
EXEMPT_PATHS = {"tools/repo/lowercase_name.py", "tools/repo/tests/test_lowercase_name.py"}


def find_text(text):
    """Return [(line number, line)] for each line that still prints a capital name."""
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        if EXEMPT_LINE.match(line):
            continue
        if PATTERN.search(line):
            hits.append((n, line))
    return hits


def fix_text(text):
    out = []
    for line in text.splitlines(keepends=True):
        out.append(line if EXEMPT_LINE.match(line) else PATTERN.sub("nisse", line))
    return "".join(out)


def tracked_files(root):
    raw = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
    for rel in raw.decode("utf-8").split("\0"):
        if rel and rel not in EXEMPT_PATHS:
            yield rel


def read_text(path):
    """The file's text, or None for a binary file or one that is not UTF-8."""
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def main(argv=None):
    p = argparse.ArgumentParser(prog="lowercase_name.py", description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    p.add_argument("cmd", choices=["check", "fix"])
    p.add_argument("--root", type=Path, default=REPO)
    a = p.parse_args(argv)
    found = 0
    for rel in tracked_files(a.root):
        path = a.root / rel
        text = read_text(path)
        if text is None:
            continue
        if a.cmd == "check":
            for n, line in find_text(text):
                found += 1
                print(f"{rel}:{n}: {line.strip()[:140]}")
        else:
            new = fix_text(text)
            if new != text:
                path.write_bytes(new.encode("utf-8"))
                found += 1
    if a.cmd == "check":
        print(f"{found} line(s) print a capital name" if found else "PASS: the name is lowercase everywhere")
        return 1 if found else 0
    print(f"rewrote {found} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
