# SPDX-License-Identifier: GPL-2.0-or-later
"""Structure check for docs/planning/TASK-LEDGER.md.

Run:  python tools/ledger/check.py [path]
Exit status 0 when the ledger is sound, 1 with one line per problem otherwise.
"""
import re
import sys
from pathlib import Path

TAGS = {"phone", "build", "art", "desk", "gate"}
STATUS = set(" ~x!-")
TASK = re.compile(r"^- \[(.)\] \*\*(N-(?:D?\d+[a-z]?))\*\* `\[(\w+)\]`")
ID = re.compile(r"N-D?\d+[a-z]?")


def split_sections(lines):
    """Yield (in_deferred, line_number, line) for task lines."""
    deferred = False
    for n, line in enumerate(lines, 1):
        if line.startswith("## "):
            deferred = line.startswith("## DEFERRED")
        if line.startswith("- [") and "**N-" in line:
            yield deferred, n, line


def field(line, name):
    m = re.search(r"\*" + re.escape(name) + r":\*\s*(.*?)(?=\s\*[A-Z][A-Za-z ]+:\*|$)", line)
    return m.group(1) if m else None


def check_text(text):
    problems = []
    for n, line in enumerate(text.split("\n"), 1):
        bad = [c for c in line if ord(c) > 127]
        if bad:
            problems.append(f"line {n}: non-ASCII character {bad[0]!r}")
    lines = text.split("\n")
    seen = {}
    tasks = []
    for deferred, n, line in split_sections(lines):
        m = TASK.match(line)
        if not m:
            problems.append(f"line {n}: task line does not match the entry shape")
            continue
        status, tid, tag = m.groups()
        if status not in STATUS:
            problems.append(f"line {n}: {tid} has unknown status {status!r}")
        if tag not in TAGS:
            problems.append(f"line {n}: {tid} has unknown tag [{tag}]")
        if tid in seen:
            problems.append(f"line {n}: {tid} is a duplicate of line {seen[tid]}")
        seen[tid] = n
        tasks.append((deferred, n, tid, tag, line))
    for deferred, n, tid, tag, line in tasks:
        if deferred:
            if not (field(line, "Unblocks when") or re.search(r"\*\*Unblocks when:\*\*\s*\S", line)):
                problems.append(f"line {n}: DEFERRED {tid} has no 'Unblocks when'")
            continue
        if field(line, "Done when") is None:
            problems.append(f"line {n}: {tid} has no 'Done when'")
        deps = field(line, "Depends")
        if deps is None:
            problems.append(f"line {n}: {tid} has no 'Depends'")
        if tag == "gate" and field(line, "Certifies") is None:
            problems.append(f"line {n}: gate {tid} has no 'Certifies'")
    known = set(seen)
    for deferred, n, tid, tag, line in tasks:
        refs = set()
        for name in ("Depends", "Certifies"):
            val = field(line, name)
            if val:
                refs.update(ID.findall(val))
        for r in sorted(refs):
            if r not in known:
                problems.append(f"line {n}: {tid} refers to {r}, which does not exist")
    return problems


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "docs" / "planning" / "TASK-LEDGER.md"
    problems = check_text(path.read_text(encoding="utf-8"))
    for p in problems:
        print(p)
    if not problems:
        print(f"{path.name}: ok")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
